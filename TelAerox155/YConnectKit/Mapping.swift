import Foundation

/// Encoding nilai (subset Format string dari decoder APK s/a.java yang relevan
/// untuk telemetri read-only). Semua multi-byte = BIG-ENDIAN.
nonisolated public enum ValueFormat: String, Codable {
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
nonisolated public struct MappingItem: Codable, Equatable {
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

nonisolated public struct Mapping {
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

// nonisolated: `Mapping` sendiri dideklarasikan nonisolated, tapi anggota di
// extension tidak otomatis ikut — perlu ditandai lagi di sini, kalau tidak
// static let ini terinfer MainActor-isolated (proyek pakai
// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor) dan gagal dipakai dari init default
// TelemetryDecoder yang dipanggil dari konteks nonisolated (mis. YConnectClient).
nonisolated public extension Mapping {
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
        // Unit "deg" (bukan "%"): mapping-overrides.json:62 menyatakan derajat;
        // skala 125/256 atas raw 0-255 menghasilkan 0-124.5, yang cocok dengan derajat.
        MappingItem(key: "throttle", name: "Bukaan Gas",         frameType: 0x55, byteNo: 13, format: .ui8,  factorTop: 125, factorBottom: 256, unit: "°"),
        // .ui8 (bukan .si8): Aerox rutin menyentuh 100-105°C (kipas radiator nyala).
        // .si8 + offset -30 bikin raw >=128 (setara suhu >=98°C) terbaca negatif —
        // capture cuma sempat merekam 33-34°C jadi tidak membantah ini, tapi rentang
        // fisik mesin membuktikan raw harus dibaca unsigned.
        MappingItem(key: "coolant",  name: "Suhu Mesin",         frameType: 0x55, byteNo: 19, format: .ui8,  offset: -30, unit: "°C"),
        MappingItem(key: "intake",   name: "Suhu Udara Masuk",   frameType: 0x55, byteNo: 20, format: .ui8,  offset: -30, unit: "°C"),
        MappingItem(key: "baro",     name: "Tekanan Udara",      frameType: 0x55, byteNo: 23, format: .ui8,  factorTop: 127, factorBottom: 256, unit: "kPa"),
        MappingItem(key: "fiError",  name: "Jumlah Error FI",    frameType: 0x55, byteNo: 28, format: .ui8),
        MappingItem(key: "dtc",      name: "Kode DTC",           frameType: 0x55, byteNo: 29, format: .ui16),
        // Frame 0x55 — record {00,48}
        MappingItem(key: "odometer", name: "Jarak Tempuh",       frameType: 0x55, byteNo: 41, format: .ui32, factorTop: 1, factorBottom: 10, unit: "km"),

        // Frame 0x56 — status CAN. Hanya 2 dari 5 record yang punya definisi di
        // Sample_SCCU1_MappingFile.json (0x020A, 0x0216, 0x0245 tidak terdaftar
        // sama sekali — lihat docs/research/02-mapping-reanalysis.md §4).
        MappingItem(key: "fiWarningLamp", name: "Lampu FI",       frameType: 0x56, byteNo: 18, format: .ui8),
        MappingItem(key: "injection",     name: "Jumlah Injeksi", frameType: 0x56, byteNo: 22, format: .ui16, factorTop: 1, factorBottom: 100, unit: "cc"),

        // Frame 0x5B — info kendaraan (record {f1,a1}/{f1,a2}). Kredibilitas
        // SEDANG: struktur match skema ByteNo absolut (terverifikasi di §2),
        // tapi faktor/offset belum dicross-check ke sumber independen kedua
        // seperti RPM/odometer. Lihat docs/research/02-mapping-reanalysis.md §3.
        MappingItem(key: "ecuPowerOnTime", name: "ECU Total Nyala", frameType: 0x5B, byteNo: 39, format: .ui32, unit: "detik"),
        MappingItem(key: "ignOnCount",     name: "Total IGN ON",    frameType: 0x5B, byteNo: 46, format: .ui16, unit: "kali"),
    ])
}
