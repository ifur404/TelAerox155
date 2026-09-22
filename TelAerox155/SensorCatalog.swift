import SwiftUI

/// Penjelasan satu sensor/field — ditampilkan saat kartu metrik di-tap.
/// Kontennya dirujuk dari `Mapping.swift` (nilai factor/offset yang beneran
/// dipakai decoder) + `docs/research/*.md` (bukti empiris & kredibilitas).
struct SensorInfo {
    let title: String
    /// Apa yang sebenarnya diukur, dalam bahasa awam.
    let whatItMeasures: String
    /// Sumber teknis: frame/ID, ByteNo, format — buat yang mau cross-check ke Mapping.swift.
    let source: String
    let credibility: String
    /// Catatan tambahan (opsional) — biasanya soal keterbatasan/perbedaan
    /// dengan sumber lain (mis. dashboard fisik motor).
    let note: String?
}

enum SensorCatalog {
    static func info(for key: String) -> SensorInfo? { table[key] }

    private static let table: [String: SensorInfo] = [
        "rpm": SensorInfo(
            title: "Putaran Mesin (RPM)",
            whatItMeasures: "Kecepatan putar poros engkol mesin, dibaca ECU dari sensor crank position/CKP.",
            source: "Frame 0x55, ByteNo 5, UI16 (big-endian), unit rpm langsung tanpa skala.",
            credibility: "TINGGI — dicek silang ke ≥2 sumber independen (capture + fisika idle/blip).",
            note: nil
        ),
        "speed": SensorInfo(
            title: "Kecepatan",
            whatItMeasures: "Kecepatan roda (biasanya roda depan), dari sensor speed pulser.",
            source: "Frame 0x55, ByteNo 7, UI8, unit km/h langsung.",
            credibility: "TINGGI — dicek silang ke ≥2 sumber independen.",
            note: nil
        ),
        "battery": SensorInfo(
            title: "Tegangan Aki",
            whatItMeasures: "Tegangan sistem kelistrikan (aki + output pengisian alternator/regulator) yang dibaca ECU.",
            source: "Frame 0x55, ByteNo 11, UI8, faktor 1/13 V (raw 0-255 → 0-19,6 V).",
            credibility: "SEDANG — faktor 1/13 hasil derivasi EMPIRIS dari rentang nilai yang masuk akal fisik (cranking 11,3-11,9 V → idle 13,5-14,2 V → blip 14,7 V), BUKAN konstanta resmi dari dokumentasi pabrikan. Sample mapping APK resmi malah pakai faktor 1/2 yang terbukti mustahil (hasil ~88 V) — lihat mapping-overrides.json.",
            note: "Kenapa bisa sedikit beda dari dashboard fisik Aerox: (1) faktor 1/13 adalah taksiran terbaik dari rentang nilai wajar, bukan konstanta resmi — ada toleransi kalibrasi; (2) titik pengukuran mungkin beda: ECU membaca di jalur suplainya sendiri, dashboard punya sensor/jalur sendiri, ada drop tegangan kecil di kabel/konektor di antara keduanya; (3) resolusi 8-bit di faktor ini ≈0,077 V per langkah (1/13 V per raw unit), jadi nilai dibulatkan ke step terdekat; (4) tegangan aki berfluktuasi cepat saat mesin hidup (alternator nge-charge, RPM naik-turun) — dua alat yang sampling di milidetik berbeda bisa menangkap nilai sesaat yang sedikit berbeda meski keduanya benar."
        ),
        "coolant": SensorInfo(
            title: "Suhu Mesin (Coolant)",
            whatItMeasures: "Suhu cairan pendingin mesin (ECT — Engine Coolant Temperature).",
            source: "Frame 0x55, ByteNo 19, UI8, offset -30°C (raw 0-255 → -30 s/d 225°C).",
            credibility: "TINGGI — dicross-check ke sample APK (confirmed_no_override).",
            note: "Format dibaca UNSIGNED (bukan signed): Aerox rutin menyentuh 100-105°C saat kipas radiator menyala, dan pembacaan signed akan membuat suhu ≥98°C terbaca negatif."
        ),
        "intake": SensorInfo(
            title: "Suhu Udara Masuk (IAT)",
            whatItMeasures: "Suhu udara yang masuk ke intake/throttle body (IAT — Intake Air Temperature), bukan suhu ambient/cuaca.",
            source: "Frame 0x55, ByteNo 20, UI8, offset -30°C.",
            credibility: "TINGGI — dicross-check ke sample APK.",
            note: nil
        ),
        "throttle": SensorInfo(
            title: "Bukaan Gas (TPS)",
            whatItMeasures: "Sudut bukaan throttle body, dari sensor TPS (Throttle Position Sensor).",
            source: "Frame 0x55, ByteNo 13, UI8, faktor 125/256 (raw 0-255 → 0-124,5).",
            credibility: "TINGGI — dicross-check ke sample APK.",
            note: "Unit-nya DERAJAT bukaan throttle body (°), bukan persen (%) — skala 125/256 atas raw 0-255 tidak menghasilkan 0-100 yang rapi kalau dianggap persen, tapi cocok sebagai rentang derajat mekanis throttle body."
        ),
        "baro": SensorInfo(
            title: "Tekanan Udara (BARO)",
            whatItMeasures: "Tekanan udara atmosfer/intake manifold, dari sensor BARO/MAP — dipakai ECU buat kompensasi ketinggian, BUKAN indikator BBM.",
            source: "Frame 0x55, ByteNo 23, UI8, faktor 127/256 (raw 0-255 → 0-126,5 kPa).",
            credibility: "TINGGI — dicross-check ke sample APK.",
            note: nil
        ),
        "fiError": SensorInfo(
            title: "Jumlah Error FI",
            whatItMeasures: "Hitungan kode error sistem Fuel Injection yang sedang aktif di ECU.",
            source: "Frame 0x55, ByteNo 28, UI8, hitungan langsung (tanpa skala).",
            credibility: "TINGGI — dicross-check ke sample APK.",
            note: "0 = tidak ada error FI aktif."
        ),
        "dtc": SensorInfo(
            title: "Kode DTC",
            whatItMeasures: "Diagnostic Trouble Code — kode diagnosa kerusakan standar OBD yang sedang aktif di ECU.",
            source: "Frame 0x55, ByteNo 29, UI16, nilai kode langsung (bukan nilai fisik terskala).",
            credibility: "TINGGI — dicross-check ke sample APK.",
            note: "0 = tidak ada DTC aktif. App ini cuma menampilkan kode mentahnya, belum menerjemahkan ke deskripsi kerusakan spesifik."
        ),
        "fiWarningLamp": SensorInfo(
            title: "Lampu FI",
            whatItMeasures: "Status lampu peringatan FI (fuel injection) yang menyala di panel instrumen motor.",
            source: "Frame 0x56 (status CAN), local ID {02 3A}, ByteNo 18, UI8.",
            credibility: "TINGGI — struktur record tervalidasi ke raw TLV capture nyata.",
            note: nil
        ),
        "injection": SensorInfo(
            title: "Jumlah Injeksi",
            whatItMeasures: "Volume bahan bakar yang disemprotkan injector per siklus/sesaat — throughput injeksi, BUKAN sisa bahan bakar di tangki.",
            source: "Frame 0x56 (status CAN), local ID {02 3E}, ByteNo 22, UI16, faktor 1/100 cc.",
            credibility: "TINGGI — struktur record tervalidasi ke raw TLV capture nyata.",
            note: "Sering menunjukkan angka kecil/0 saat idle — itu wajar, bukan berarti bermasalah."
        ),
        "odometer": SensorInfo(
            title: "Jarak Tempuh (Odometer)",
            whatItMeasures: "Total jarak tempuh motor sejak baru, dari ECU (bukan dari sensor GPS/app).",
            source: "Frame 0x55, ByteNo 41, UI32, faktor 1/10 km.",
            credibility: "TINGGI — dicek silang ke ≥2 sumber independen.",
            note: nil
        ),
        "ecuPowerOnTime": SensorInfo(
            title: "ECU Total Nyala",
            whatItMeasures: "Total akumulasi waktu ECU pernah dalam keadaan menyala (power-on) seumur motor — mirip \"jam operasional\" mesin, bukan jam pemakaian riding aktif saja.",
            source: "Frame 0x5B (info kendaraan), ID {F1 A1}, ByteNo 39, UI32, unit detik.",
            credibility: "TINGGI — faktor/offset tervalidasi silang ke 2 log lapangan (delta nilai antar sesi cocok dengan delta wall-clock dalam ~1,5%). Lihat docs/research/02-mapping-reanalysis.md §3.",
            note: nil
        ),
        "ignOnCount": SensorInfo(
            title: "Total IGN ON",
            whatItMeasures: "Hitungan berapa kali kunci kontak motor pernah diputar ke posisi ON seumur motor.",
            source: "Frame 0x5B (info kendaraan), ID {F1 A2}, ByteNo 46, UI16, hitungan langsung.",
            credibility: "TINGGI — tervalidasi silang ke 2 log lapangan (naik tepat +1 antar sesi, sesuai satu siklus kontak).",
            note: nil
        ),
        "fuel": SensorInfo(
            title: "Sisa BBM",
            whatItMeasures: "Belum diketahui — field ini BELUM ada dalam mapping yang berhasil direverse-engineer dari CCU Aerox 155.",
            source: "Tidak ada. Sample_SCCU1_MappingFile.json (bundle APK) tidak punya entri fuel/tangki sama sekali. Kandidat yang belum terpecahkan: 3 local ID \"misteri\" di frame 0x56 — {02 0A}, {02 16}, {02 45} — yang semuanya masih bernilai 0 di capture yang ada (motor idle diam saat direkam).",
            credibility: "TIDAK ADA — murni gap riset, bukan bug.",
            note: "Kemungkinan penyebab: (1) fuel level di Aerox mungkin tidak lewat jalur CCU/BLE ini sama sekali — bisa jadi sensor float terhubung langsung ke unit meter, terpisah dari data yang di-broadcast CCU; atau (2) datanya ADA tapi tersembunyi di salah satu dari 3 ID misteri di atas, dan baru bisa dipastikan dengan capture BARU saat motor jalan sambil BBM berkurang, lalu bandingkan perubahan nilainya dengan indikator BBM fisik di dashboard. Belum ada capture seperti itu sampai saat ini."
        ),
    ]
}

/// Wrapper `Identifiable` supaya `String?` (kunci sensor) bisa dipakai dengan
/// `.sheet(item:)` — pola yang sama dengan `ShareItem` di ContentView.swift.
struct SensorSheetItem: Identifiable {
    let key: String
    var id: String { key }
}

/// Sheet penjelasan sensor — dipanggil dari tap kartu metrik mana pun yang
/// key-nya terdaftar di `SensorCatalog`.
struct SensorInfoSheet: View {
    let key: String
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let info = SensorCatalog.info(for: key) {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Apa yang diukur")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent)
                            Text(info.whatItMeasures)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Sumber teknis")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent)
                            Text(info.source)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Kredibilitas")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(accent)
                            Text(info.credibility)
                                .font(.subheadline)
                                .foregroundStyle(.white)
                        }

                        if let note = info.note {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Catatan")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(accent)
                                Text(note)
                                    .font(.subheadline)
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .padding(20)
                    .navigationTitle(info.title)
                } else {
                    Text("Belum ada penjelasan untuk sensor ini.")
                        .foregroundStyle(.secondary)
                        .padding(20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
    }
}
