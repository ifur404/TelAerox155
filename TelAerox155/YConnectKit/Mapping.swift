import Foundation

/// Encoding nilai (subset Format string dari decoder APK s/a.java yang relevan
/// untuk telemetri read-only). Semua multi-byte = BIG-ENDIAN.
public enum ValueFormat: String, Codable {
    case ui8 = "UI8", si8 = "SI8"
    case ui16 = "UI16", si16 = "SI16"
    case ui32 = "UI32", si32 = "SI32"
    case d = "D"        // unsigned 32-bit sebagai double (dipakai odometer di sample)
    case fg = "FG"      // boolean
    case ascii = "ASCII"
}

/// Satu item mapping: cara membaca satu field dari frame RX utuh.
///
/// `byteNo` = index ABSOLUT ke dalam frame utuh (index 0 = byte tipe).
/// Nilai akhir = raw * factorTop / factorBottom + offset (bottom 0 → dianggap 1).
public struct MappingItem: Codable, Equatable {
    public let key: String          // pengenal stabil untuk kode (mis. "rpm")
    public let name: String         // nama tampil
    public let frameType: UInt8     // ServiceID: 0x55, 0x56, 0x5B, ...
    public let byteNo: Int
    public let format: ValueFormat
    public let factorTop: Double
    public let factorBottom: Double
    public let offset: Double
    public let unit: String

    public init(key: String, name: String, frameType: UInt8, byteNo: Int,
                format: ValueFormat, factorTop: Double = 1, factorBottom: Double = 1,
                offset: Double = 0, unit: String = "") {
        self.key = key; self.name = name; self.frameType = frameType; self.byteNo = byteNo
        self.format = format; self.factorTop = factorTop
        self.factorBottom = factorBottom; self.offset = offset; self.unit = unit
    }
}

public struct Mapping {
    public let items: [MappingItem]
    public init(items: [MappingItem]) { self.items = items }

    public func items(for frameType: UInt8) -> [MappingItem] {
        items.filter { $0.frameType == frameType }
    }

    /// Muat mapping dari JSON array MappingItem (format Codable di atas).
    /// Untuk file mapping resmi Yamaha (S3) yang skema key-nya berbeda,
    /// petakan dulu ke MappingItem lalu pakai init ini.
    public init(jsonData: Data) throws {
        self.items = try JSONDecoder().decode([MappingItem].self, from: jsonData)
    }
}

public extension Mapping {
    /// Mapping SCCU1 default untuk Aerox 155 ABS.
    ///
    /// Nilai TERKONFIRMASI dari capture Aerox-155.pklg (v2). Satu override penting:
    /// tegangan aki `factorBottom = 13` (sample APK pakai 2 → menghasilkan ~88V,
    /// mustahil). fb=13 menghasilkan 11,3–14,8 V (sesuai fisik cranking→idle→blip).
    static let sccu1Aerox155 = Mapping(items: [
        // Frame 0x55 — engine / diagnostic (record {00,01})
        MappingItem(key: "rpm",      name: "Putaran Mesin",      frameType: 0x55, byteNo: 5,  format: .ui16, unit: "rpm"),
        MappingItem(key: "speed",    name: "Kecepatan",          frameType: 0x55, byteNo: 7,  format: .ui8,  unit: "km/h"),
        MappingItem(key: "battery",  name: "Tegangan Aki",       frameType: 0x55, byteNo: 11, format: .ui8,  factorTop: 1, factorBottom: 13, unit: "V"),
        MappingItem(key: "throttle", name: "Bukaan Gas",         frameType: 0x55, byteNo: 13, format: .ui8,  factorTop: 125, factorBottom: 256, unit: "%"),
        MappingItem(key: "coolant",  name: "Suhu Mesin",         frameType: 0x55, byteNo: 19, format: .si8,  offset: -30, unit: "°C"),
        MappingItem(key: "intake",   name: "Suhu Udara Masuk",   frameType: 0x55, byteNo: 20, format: .ui8,  offset: -30, unit: "°C"),
        MappingItem(key: "baro",     name: "Tekanan Udara",      frameType: 0x55, byteNo: 23, format: .ui8,  factorTop: 127, factorBottom: 256, unit: "kPa"),
        MappingItem(key: "fiError",  name: "Jumlah Error FI",    frameType: 0x55, byteNo: 28, format: .ui8),
        MappingItem(key: "dtc",      name: "Kode DTC",           frameType: 0x55, byteNo: 29, format: .ui16),
        // Frame 0x55 — record {00,48}
        MappingItem(key: "odometer", name: "Jarak Tempuh",       frameType: 0x55, byteNo: 41, format: .ui32, factorTop: 1, factorBottom: 10, unit: "km"),
    ])
}
