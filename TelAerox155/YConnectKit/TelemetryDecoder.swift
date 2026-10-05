import Foundation

/// Satu nilai hasil decode, membawa raw + nilai terskala.
nonisolated public struct DecodedValue: Equatable {
    public let key: String
    public let name: String
    public let raw: Double
    public let value: Double
    public let unit: String
}

/// Snapshot telemetri: kumpulan field terdecode dari satu (atau beberapa) frame.
nonisolated public struct TelemetrySnapshot {
    public private(set) var values: [String: DecodedValue] = [:]
    /// Waktu penerimaan per field, termasuk saat nilainya tidak berubah.
    /// Snapshot berisi gabungan frame yang frekuensi pembaruannya berbeda.
    public private(set) var receivedAt: [String: Date] = [:]

    public mutating func merge(_ decoded: [DecodedValue], at date: Date = Date()) {
        for v in decoded {
            values[v.key] = v
            receivedAt[v.key] = date
        }
    }

    public func value(_ key: String) -> Double? { values[key]?.value }
    public func decoded(_ key: String) -> DecodedValue? { values[key] }

    // Akses cepat yang umum dipakai UI:
    public var rpm: Double? { value("rpm") }
    public var speed: Double? { value("speed") }
    public var battery: Double? { value("battery") }
    public var coolant: Double? { value("coolant") }
    public var odometer: Double? { value("odometer") }
}

nonisolated public enum DecodeError: Error, Equatable {
    case tlvMismatch(String)   // struktur record tidak sesuai ekspektasi
}

/// Decoder telemetri berbasis mapping.
nonisolated public struct TelemetryDecoder {
    public let mapping: Mapping
    /// Bila true, validasi struktur TLV frame 0x55 sebelum mempercayai ByteNo absolut.
    public let validateTLV: Bool

    public init(mapping: Mapping = .sccu1Aerox155, validateTLV: Bool = true) {
        self.mapping = mapping
        self.validateTLV = validateTLV
    }

    /// Decode satu frame RX utuh (sudah lolos checksum) menjadi daftar nilai.
    public func decode(_ frame: Frame) throws -> [DecodedValue] {
        guard let type = frame.type else { return [] }

        // Gerbang keamanan: ByteNo absolut hanya sah bila layout record cocok.
        // Untuk 0x55 kita harapkan 2 record: {00,01} lalu {00,48}.
        if validateTLV && type == .localRecord {
            let recs = try frame.records()
            guard recs.count == 2,
                  recs[0].localID == (0x00, 0x01),
                  recs[1].localID == (0x00, 0x48) else {
                throw DecodeError.tlvMismatch("frame 0x55 layout tak terduga: \(recs.map { $0.localID })")
            }
        }

        let b = frame.bytes
        var out: [DecodedValue] = []
        for item in mapping.items(for: type.rawValue) {
            guard let raw = readRaw(item, from: b) else { continue }
            let denom = item.factorBottom == 0 ? 1 : item.factorBottom
            let value = raw * item.factorTop / denom + item.offset
            out.append(DecodedValue(key: item.key, name: item.name,
                                    raw: raw, value: value, unit: item.unit))
        }
        return out
    }

    private func readRaw(_ item: MappingItem, from b: [UInt8]) -> Double? {
        switch item.format {
        case .ui8:  return BinaryReader.u8(b, item.byteNo).map(Double.init)
        case .si8:  return BinaryReader.s8(b, item.byteNo).map(Double.init)
        case .ui16: return BinaryReader.u16be(b, item.byteNo).map(Double.init)
        case .si16: return BinaryReader.s16be(b, item.byteNo).map(Double.init)
        // PERINGATAN: .d selalu dibaca sebagai 4 byte (u32be). Sample mapping
        // Yamaha (mapping-overrides.json) memakai Format "D" dengan Length 8
        // bit untuk beberapa field (aki/gas/tekanan) — kalau Mapping dimuat
        // dari JSON vendor apa adanya, field 8-bit ber-Format "D" akan salah
        // baca 4 byte. Tabel .sccu1Aerox155 aman karena field itu dideklarasikan
        // .ui8 secara eksplisit, bukan .d.
        case .ui32, .d: return BinaryReader.u32be(b, item.byteNo).map { Double($0) }
        case .si32: return BinaryReader.s32be(b, item.byteNo).map(Double.init)
        case .fg:   return BinaryReader.u8(b, item.byteNo).map { $0 != 0 ? 1 : 0 }
        case .ascii: return nil   // string ditangani terpisah, bukan sebagai nilai numerik
        }
    }
}
