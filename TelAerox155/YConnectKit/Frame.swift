import Foundation

/// Tipe frame RX (byte[0]), dari identifyMessage APK + validasi capture.
public enum FrameType: UInt8, CaseIterable {
    case localRecord    = 0x55  // 'U' engine/diag/odometer (SCCU_BLE_01_48OP)
    case can            = 0x56  // 'V' status CAN
    case ffdOrMarket    = 0x59  // 'Y' freeze-frame / market / config pages
    case startProcessing = 0x5A // 'Z' hasil auth (8 byte)
    case common         = 0x5B  // '[' info kendaraan / VIN
    case relay          = 0x57  // relay notifikasi telepon
}

/// Satu record TLV di dalam frame.
public struct TLVRecord: Equatable {
    public let localID: (UInt8, UInt8)
    public let length: Int
    public let dataStart: Int   // index awal data di dalam frame utuh

    public static func == (l: TLVRecord, r: TLVRecord) -> Bool {
        l.localID == r.localID && l.length == r.length && l.dataStart == r.dataStart
    }
}

public enum FrameError: Error, Equatable {
    case tooShort
    case badChecksum
    case recordHeaderBeyondFrame
    case recordDataBeyondFrame
    case unexpectedRecordCount(Int)
}

/// Frame RX utuh (sudah lengkap dari satu notifikasi CoreBluetooth).
///
/// Catatan: di CoreBluetooth, `didUpdateValueFor` memberi nilai notifikasi UTUH —
/// reassembly L2CAP (yang perlu saat baca capture PacketLogger mentah) TIDAK perlu
/// di sini. Yang wajib: verifikasi checksum tiap frame sebagai gerbang kebenaran.
public struct Frame {
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
}
