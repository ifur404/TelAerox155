import Foundation
import Combine
import CoreLocation

/// Rekaman sesi ke FILE (bukan buffer memori seperti `DiagnosticLog`) — dua format:
///
/// - `.bleRaw`: baris teks TX/RX/INFO/SCAN mentah, format sama seperti
///   `DiagnosticLog`, tapi ditulis LANGSUNG ke disk per baris lewat `FileHandle`
///   supaya aman dipakai lama (termasuk saat app di background) tanpa RAM
///   membengkak — beda dari `DiagnosticLog` yang memang sengaja disimpan di
///   memori (ring buffer) buat ditampilkan live di UI.
/// - `.csv`: satu baris per detik, nilai telemetri TERDECODE (bukan hex
///   mentah), dengan baris header di awal file.
///
/// Dibatasi ukuran (default 20 MB) DAN durasi (default 6 jam) — mana yang
/// tercapai duluan menghentikan rekaman otomatis. Ini supaya rekaman yang lupa
/// dimatikan (mis. jalan semalaman di background) tidak membengkak tanpa batas
/// dan menghabiskan storage device.
///
/// Class ini TIDAK di-`nonisolated` — beda dari `DiagnosticLog` — karena semua
/// pemanggilnya (closure `onRawFrame`/timer 1 Hz di `TelemetryStore`) sudah
/// berjalan MainActor-isolated (proyek ini pakai
/// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, lihat catatan di AGENTS.md/
/// YConnectClient.swift), jadi tidak butuh lock terpisah.
final class SessionRecorder: ObservableObject {
    enum Format: String, CaseIterable, Identifiable {
        case bleRaw = "BLE Raw"
        case csv = "CSV per detik"
        var id: String { rawValue }
    }

    @Published private(set) var isRecording = false
    @Published private(set) var format: Format = .bleRaw
    @Published private(set) var fileURL: URL?
    @Published private(set) var bytesWritten: Int = 0
    @Published private(set) var startedAt: Date?
    /// Terisi kalau rekaman terakhir berhenti KARENA limit (bukan ditekan
    /// user) — ditampilkan sebagai pesan info di UI.
    @Published private(set) var stopReason: String?

    private var fileHandle: FileHandle?

    // Limit keamanan (lihat dokblok di atas) — bukan angka resmi dari mana
    // pun, dipilih supaya cukup longgar buat satu sesi ujicoba/riding panjang
    // tapi tetap ada batas keras.
    private let maxBytes = 20 * 1024 * 1024      // 20 MB
    private let maxDuration: TimeInterval = 6 * 3600   // 6 jam

    private static let csvHeader = "timestamp_iso,elapsed_s,rpm,speed_kmh,battery_v,coolant_c,intake_c,throttle_deg,baro_kpa,fiError,dtc,fiWarningLamp,injection_cc,odometer_km,ecuPowerOnTime_s,ignOnCount,vin,modelCode,gps_lat,gps_lon,gps_speed_kmh,gps_alt_m,gps_accuracy_m"

    /// Dengan pecahan detik (bukan default `ISO8601DateFormatter()` yang
    /// membulatkan ke detik) — tanpa ini, dua baris yang jaraknya < 1 detik
    /// (mis. 12:00:00.98 lalu 12:00:01.02) bisa tampak punya timestamp SAMA
    /// atau malah kebalik urutannya kalau dibaca sebagai teks biasa. Dibuat
    /// statis sekali (bukan tiap baris) — formatter ini agak mahal dibuat.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// "telaerox-rec_2026-09-22_20-14-05.csv" / ".txt" — cukup unik + gampang
    /// dibaca kalau beberapa kali rekam dalam satu sesi ujicoba di motor.
    static func makeFileName(format: Format) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let ext = format == .csv ? "csv" : "txt"
        return "telaerox-rec_\(f.string(from: Date())).\(ext)"
    }

    /// Ditulis ke Documents (bukan tmp/) supaya bertahan kalau app disuspend
    /// lama di background atau di-kill sistem sebelum sempat di-stop manual —
    /// tmp/ bisa dibersihkan iOS kapan saja.
    @discardableResult
    func start(format: Format) -> URL? {
        stop()   // jaga-jaga kalau ada rekaman lama yang belum ditutup
        guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        let url = dir.appendingPathComponent(Self.makeFileName(format: format))
        // completeUntilFirstUserAuthentication (bukan default .complete) supaya
        // file tetap bisa ditulis kalau layar dikunci di tengah sesi — cukup
        // sekali unlock sejak boot, tidak perlu unlock tiap saat mau nulis.
        let attrs: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attrs),
              let handle = try? FileHandle(forWritingTo: url) else {
            return nil
        }
        self.format = format
        self.fileHandle = handle
        self.fileURL = url
        self.bytesWritten = 0
        self.startedAt = Date()
        self.stopReason = nil
        self.isRecording = true
        if format == .csv {
            write(Self.csvHeader + "\n")
        }
        return url
    }

    /// `reason == nil` berarti dihentikan manual oleh user (tombol "Stop"),
    /// bukan karena limit — dipakai UI buat membedakan pesan yang ditampilkan.
    func stop(reason: String? = nil) {
        guard isRecording else { return }
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        isRecording = false
        stopReason = reason
    }

    private func write(_ text: String) {
        guard let data = text.data(using: .utf8), let handle = fileHandle else { return }
        // write(contentsOf:) (bukan write(_:) lama) supaya kegagalan nulis
        // (mis. storage penuh/file terkunci) jadi Error yang bisa ditangani,
        // bukan exception ObjC yang crash app — penting karena sekarang
        // rekaman diharapkan tetap jalan tanpa pengawasan saat layar dikunci.
        do {
            try handle.write(contentsOf: data)
        } catch {
            stop(reason: "Berhenti — gagal menulis file: \(error.localizedDescription)")
            return
        }
        bytesWritten += data.count
        enforceLimitsIfNeeded()
    }

    private func enforceLimitsIfNeeded() {
        guard isRecording else { return }
        if bytesWritten >= maxBytes {
            stop(reason: "Berhenti otomatis — rekaman mencapai batas ukuran \(maxBytes / 1_048_576) MB.")
            return
        }
        enforceDurationLimitIfNeeded()
    }

    /// Cek limit durasi TANPA butuh row baru ditulis — dipanggil juga dari luar
    /// (timer 1 Hz TelemetryStore, tiap detik selama rekaman aktif) supaya
    /// rekaman yang idle lama (mis. BLE terputus panjang tapi user lupa tekan
    /// Stop) tetap kena batas otomatis, bukan cuma dicek pas kebetulan ada
    /// baris baru masuk.
    func enforceDurationLimitIfNeeded() {
        guard isRecording, let started = startedAt else { return }
        if Date().timeIntervalSince(started) >= maxDuration {
            stop(reason: "Berhenti otomatis — rekaman mencapai batas durasi \(Int(maxDuration / 3600)) jam.")
        }
    }

    // MARK: - BLE Raw

    /// Dipanggil dari `onRawFrame` — no-op kalau tidak sedang merekam format
    /// ini, jadi aman dipanggil terus-menerus tanpa cek tambahan di pemanggil.
    func appendRaw(_ direction: LogDirection, _ message: String) {
        guard isRecording, format == .bleRaw, let started = startedAt else { return }
        let t = Date().timeIntervalSince(started)
        write(String(format: "[%9.3fs] [%@] %@\n", t, direction.rawValue, message))
    }

    // MARK: - CSV

    /// Dipanggil dari timer 1 Hz yang sama dengan yang me-refresh `logLineCount`
    /// — satu baris per detik, nilai TERDECODE (bukan raw byte). `location`
    /// nil kalau GPS belum ada fix (mis. baru start, indoor, atau izin belum
    /// diberikan) — kolom gps_* dikosongkan di baris itu, bukan menghentikan
    /// rekaman.
    func appendCSVRow(snapshot: TelemetrySnapshot, vin: String?, modelCode: String?,
                       location: CLLocation?) {
        guard isRecording, format == .csv, let started = startedAt else { return }
        let elapsed = Date().timeIntervalSince(started)
        func v(_ key: String) -> String {
            guard let d = snapshot.decoded(key) else { return "" }
            return String(format: "%.3f", d.value)
        }
        // GPS: speed/course CoreLocation bernilai negatif kalau tidak valid —
        // dikosongkan (bukan ditulis -1) supaya tidak salah dibaca sebagai
        // kecepatan mundur di CSV.
        let lat = location.map { String(format: "%.6f", $0.coordinate.latitude) } ?? ""
        let lon = location.map { String(format: "%.6f", $0.coordinate.longitude) } ?? ""
        let gpsSpeed = location.flatMap { $0.speed >= 0 ? String(format: "%.1f", $0.speed * 3.6) : nil } ?? ""
        let gpsAlt = location.map { String(format: "%.1f", $0.altitude) } ?? ""
        let gpsAcc = location.flatMap { $0.horizontalAccuracy >= 0 ? String(format: "%.1f", $0.horizontalAccuracy) : nil } ?? ""
        let row = [
            Self.timestampFormatter.string(from: Date()),
            String(format: "%.1f", elapsed),
            v("rpm"), v("speed"), v("battery"), v("coolant"), v("intake"),
            v("throttle"), v("baro"), v("fiError"), v("dtc"), v("fiWarningLamp"),
            v("injection"), v("odometer"), v("ecuPowerOnTime"), v("ignOnCount"),
            vin ?? "", modelCode ?? "",
            lat, lon, gpsSpeed, gpsAlt, gpsAcc
        ].joined(separator: ",")
        write(row + "\n")
    }
}
