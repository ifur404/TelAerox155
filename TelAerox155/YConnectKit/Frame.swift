import Foundation

/// Tipe frame RX (byte[0]), dari identifyMessage APK + validasi capture.
nonisolated public enum FrameType: UInt8, CaseIterable {
    case localRecord    = 0x55  // 'U' engine/diag/odometer (SCCU_BLE_01_48OP)
    case can            = 0x56  // 'V' status CAN
    case ffdOrMarket    = 0x59  // 'Y' freeze-frame / market / config pages
    case startProcessing = 0x5A // 'Z' hasil auth (8 byte)
    case common         = 0x5B  // '[' info kendaraan / VIN
    case relay          = 0x57  // relay notifikasi telepon
}

/// Satu record TLV di dalam frame.
nonisolated public struct TLVRecord: Equatable {
    public let localID: (UInt8, UInt8)
    public let length: Int
    public let dataStart: Int   // index awal data di dalam frame utuh

    public static func == (l: TLVRecord, r: TLVRecord) -> Bool {
        l.localID == r.localID && l.length == r.length && l.dataStart == r.dataStart
    }
}

nonisolated public enum FrameError: Error, Equatable {
    case tooShort
    case badChecksum
    case recordHeaderBeyondFrame
    case recordDataBeyondFrame
    case unexpectedRecordCount(Int)
    /// TLV walk selesai tapi tersisa != 2 byte (counter + checksum). App resmi
    /// mewajibkan ini (p014i/c.java:603-605 verifyDataFormat) sebagai gerbang
    /// tambahan; sebelumnya kita hanya cek checksum, jadi frame checksum-valid
    /// tapi struktur TLV-nya rusak bisa lolos ke decoder.
    case trailingBytesMismatch(expected: Int, actual: Int)
}

/// Frame RX utuh (sudah lengkap dari satu notifikasi CoreBluetooth).
///
/// Catatan: di CoreBluetooth, `didUpdateValueFor` memberi nilai notifikasi UTUH —
/// reassembly L2CAP (yang perlu saat baca capture PacketLogger mentah) TIDAK perlu
/// di sini. Yang wajib: verifikasi checksum tiap frame sebagai gerbang kebenaran.
nonisolated public struct Frame {
    public let bytes: [UInt8]

    public var type: FrameType? { bytes.first.flatMap(FrameType.init(rawValue:)) }
    public var recordCount: Int { bytes.count > 1 ? Int(bytes[1]) : 0 }

    /// Buat frame dan verifikasi checksum. Melempar `.badChecksum` bila gagal.
    public init(verifying raw: [UInt8]) throws {
        guard raw.count >= 2 else { throw FrameError.tooShort }
        guard Checksum.verify(raw) else { throw FrameError.badChecksum }
        self.bytes = raw
    }

    /// Buat frame tanpa verifikasi (mis. untuk test / inspeksi).
    public init(unchecked raw: [UInt8]) { self.bytes = raw }

    /// Jalankan TLV: count di byte[1], tiap record header 3 byte
    /// `[localID-hi, localID-lo, length]`, data menyusul.
    ///
    /// Tidak memvalidasi bahwa walk berakhir tepat 2 byte sebelum akhir frame —
    /// pakai `validateStructure()` untuk itu (gerbang tambahan yang dipakai app
    /// resmi sebelum mempercayai frame).
    public func records() throws -> [TLVRecord] {
        var out: [TLVRecord] = []
        var i = 2
        for _ in 0..<recordCount {
            guard i + 3 <= bytes.count else { throw FrameError.recordHeaderBeyondFrame }
            let lid = (bytes[i], bytes[i + 1])
            let len = Int(bytes[i + 2])
            let dataStart = i + 3
            guard dataStart + len <= bytes.count else { throw FrameError.recordDataBeyondFrame }
            out.append(TLVRecord(localID: lid, length: len, dataStart: dataStart))
            i = dataStart + len
        }
        return out
    }

    /// Gerbang tambahan yang dipakai app resmi (p014i/c.java:603-605,
    /// `verifyDataFormat`): setelah TLV walk selesai, harus tersisa TEPAT 2 byte
    /// (counter + checksum). Checksum sendiri tidak menjamin ini — frame bisa
    /// lolos checksum tapi punya record yang tumpang tindih/salah panjang dan
    /// menyisakan sisa byte yang tak terduga.
    @discardableResult
    public func validateStructure() throws -> [TLVRecord] {
        let recs = try records()
        let walkEnd = recs.last.map { $0.dataStart + $0.length } ?? 2
        let expected = bytes.count - 2
        guard walkEnd == expected else {
            throw FrameError.trailingBytesMismatch(expected: expected, actual: walkEnd)
        }
        return recs
    }
}
