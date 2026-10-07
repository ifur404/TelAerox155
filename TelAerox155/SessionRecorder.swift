import Foundation
import Combine
import CoreLocation

/// Rekaman sesi ke file — dua format:
///
/// - `.bleRaw`: baris teks TX/RX/INFO/SCAN mentah, ditulis langsung ke disk
///   per baris lewat `FileHandle` supaya aman dipakai lama (termasuk saat app
///   di background) tanpa RAM membengkak.
/// - `.csv`: satu baris per detik, nilai telemetri TERDECODE (bukan hex
///   mentah), dengan baris header di awal file.
///
/// Dibatasi ukuran (default 20 MB) DAN durasi (default 6 jam) — mana yang
/// tercapai duluan menghentikan rekaman otomatis. Ini supaya rekaman yang lupa
/// dimatikan (mis. jalan semalaman di background) tidak membengkak tanpa batas
/// dan menghabiskan storage device.
///
/// Class ini TIDAK di-`nonisolated` karena semua
/// pemanggilnya (closure `onRawFrame`/timer 1 Hz di `TelemetryStore`) sudah
/// berjalan MainActor-isolated (proyek ini pakai
/// SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, lihat catatan di AGENTS.md/
/// YConnectClient.swift), jadi tidak butuh lock terpisah.
final class SessionRecorder: ObservableObject {
    /// rawValue disimpan di indeks riwayat (`RecordingLibrary`) — jangan
    /// diubah; teks buat UI ada di `title`/`subtitle`.
    /// nonisolated: ikut di-encode/decode bareng `RecordingSession`.
    nonisolated enum Format: String, CaseIterable, Identifiable, Codable, Sendable {
        case csv
        case bleRaw
        var id: String { rawValue }

        var title: String {
            switch self {
            case .csv: return "Data Sensor"
            case .bleRaw: return "Frame BLE Mentah"
            }
        }

        var subtitle: String {
            switch self {
            case .csv: return "Telemetri motor dan GPS per detik; gerakan dan barometer opsional."
            case .bleRaw: return "Semua frame TX/RX mentah (TXT) buat analisa protokol. Kredensial & VIN disensor."
            }
        }

        var icon: String {
            switch self {
            case .csv: return "chart.xyaxis.line"
            case .bleRaw: return "antenna.radiowaves.left.and.right"
            }
        }

        var fileExtension: String { self == .csv ? "csv" : "txt" }

        init?(fileExtension ext: String) {
            switch ext.lowercased() {
            case "csv": self = .csv
            case "txt": self = .bleRaw
            default: return nil
            }
        }
    }

    /// Riwayat permanen semua sesi — lihat `RecordingLibrary`.
    let library: RecordingLibrary

    init(library: RecordingLibrary = RecordingLibrary()) {
        self.library = library
    }

    @Published private(set) var isRecording = false
    @Published private(set) var format: Format = .csv
    @Published private(set) var fileURL: URL?
    @Published private(set) var bytesWritten: Int = 0
    /// Baris data yang sudah ditulis (baris CSV tanpa header / frame BLE Raw).
    @Published private(set) var lineCount: Int = 0
    @Published private(set) var startedAt: Date?
    /// Dipanggil sinkron setelah seluruh state sesi siap, bukan di willSet
    /// @Published. GPS harus mulai saat tombol ditekan di foreground.
    var onRecordingChanged: ((Bool) -> Void)?
    /// Terisi kalau rekaman terakhir berhenti KARENA limit (bukan ditekan
    /// user) — ditampilkan sebagai pesan info di UI.
    @Published private(set) var stopReason: String?
    /// Dibekukan saat start agar perubahan posisi HP tidak mencampur satu sesi.
    private(set) var includesMotionAndBarometer = true
    private(set) var phonePlacement: PhonePlacement = .unknown

    private var fileHandle: FileHandle?
    // Hitungan file selalu tepat; angka UI boleh diperbarui maksimal 1 Hz.
    private var totalBytesWritten = 0
    private var totalLineCount = 0
    private var progressThrottle = MonotonicThrottle(interval: 1)
    /// Kapan metadata sesi aktif terakhir disimpan ke indeks — di-throttle
    /// (bukan tiap baris) supaya tidak nulis JSON ~20x/detik saat BLE Raw.
    private var lastIndexSync = Date.distantPast

    // Limit keamanan (lihat dokblok di atas) — bukan angka resmi dari mana
    // pun, dipilih supaya cukup longgar buat satu sesi ujicoba/riding panjang
    // tapi tetap ada batas keras.
    private let maxBytes = 20 * 1024 * 1024      // 20 MB
    private let maxDuration: TimeInterval = 6 * 3600   // 6 jam

    static let ecuFields: [(column: String, key: String)] = [
        ("rpm", "rpm"), ("speed_kmh", "speed"), ("battery_v", "battery"),
        ("coolant_c", "coolant"), ("intake_c", "intake"), ("throttle_deg", "throttle"),
        ("baro_kpa", "baro"), ("fiError", "fiError"), ("dtc", "dtc"),
        ("fiWarningLamp", "fiWarningLamp"), ("injection_cc", "injection"),
        ("odometer_km", "odometer"), ("ecuPowerOnTime_s", "ecuPowerOnTime"), ("ignOnCount", "ignOnCount")
    ]
    static let csvColumns = ["timestamp_iso", "elapsed_s"] + ecuFields.map(\.column) + [
        "vin", "modelCode", "gps_lat", "gps_lon", "gps_speed_kmh", "gps_alt_m", "gps_accuracy_m",
        "schema_version", "ble_state", "app_state"
    ] + ecuFields.map { "ecu_\($0.key)_age_s" } + [
        "gps_timestamp_iso", "gps_age_s", "gps_vertical_accuracy_m", "gps_speed_accuracy_mps",
        "gps_course_deg", "gps_course_accuracy_deg", "gps_status", "gps_authorization", "gps_precise",
        "motion_timestamp_iso", "motion_uptime_s", "motion_age_s", "motion_status", "motion_samples", "motion_span_s",
        "motion_ax_mps2", "motion_ay_mps2", "motion_az_mps2",
        "motion_mean_ax_mps2", "motion_mean_ay_mps2", "motion_mean_az_mps2",
        "motion_peak_mps2", "motion_rms_mps2", "motion_vertical_peak_mps2", "motion_vertical_rms_mps2",
        "gravity_x_g", "gravity_y_g", "gravity_z_g",
        "gyro_x_radps", "gyro_y_radps", "gyro_z_radps", "roll_deg", "pitch_deg", "yaw_deg",
        "attitude_qw", "attitude_qx", "attitude_qy", "attitude_qz",
        "phone_pressure_kpa", "phone_relative_alt_m", "barometer_timestamp_iso", "barometer_uptime_s", "barometer_age_s", "barometer_status",
        "phone_battery_pct", "phone_battery_state", "phone_low_power", "phone_thermal_state", "phone_placement"
    ]

    /// GPS dan status perangkat selalu disimpan. Toggle hanya mengatur
    /// sensor gerakan/orientasi, barometer, dan posisi pemasangan iPhone.
    static func columns(includingMotionAndBarometer: Bool) -> [String] {
        includingMotionAndBarometer ? csvColumns : csvColumns.filter {
            !$0.hasPrefix("motion_")
                && !$0.hasPrefix("barometer_") && !$0.hasPrefix("gravity_")
                && !$0.hasPrefix("gyro_") && !$0.hasPrefix("attitude_")
                && !["roll_deg", "pitch_deg", "yaw_deg", "phone_pressure_kpa",
                     "phone_relative_alt_m", "phone_placement"].contains($0)
        }
    }
    private var activeCSVColumns: [String] { Self.columns(includingMotionAndBarometer: includesMotionAndBarometer) }

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
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "\(RecordingLibrary.filePrefix)\(f.string(from: Date())).\(format.fileExtension)"
    }

    /// Simpan metadata sesi aktif ke indeks riwayat. `endedAt` nil selama
    /// masih merekam — kalau app di-kill sistem di tengah jalan, entri ini
    /// yang membuat sesinya tetap muncul (dan ditandai) di riwayat.
    private func syncIndex(endedAt: Date? = nil) {
        guard let url = fileURL, let started = startedAt else { return }
        lastIndexSync = Date()
        library.upsert(RecordingSession(fileName: url.lastPathComponent, format: format,
                                        startedAt: started, endedAt: endedAt,
                                        bytes: totalBytesWritten, lineCount: totalLineCount,
                                        stopReason: endedAt == nil ? nil : stopReason, title: nil))
    }

    /// Ditulis ke Documents (bukan tmp/) supaya bertahan kalau app disuspend
    /// lama di background atau di-kill sistem sebelum sempat di-stop manual —
    /// tmp/ bisa dibersihkan iOS kapan saja.
    @discardableResult
    func start(format: Format, includesMotionAndBarometer: Bool = true, placement: PhonePlacement = .unknown) -> URL? {
        stop()   // jaga-jaga kalau ada rekaman lama yang belum ditutup
        guard let dir = library.documentsDirectory else {
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
        self.totalBytesWritten = 0
        self.totalLineCount = 0
        self.progressThrottle = MonotonicThrottle(interval: 1)
        self.bytesWritten = 0
        self.lineCount = 0
        self.startedAt = Date()
        self.stopReason = nil
        self.includesMotionAndBarometer = includesMotionAndBarometer
        self.phonePlacement = placement
        self.isRecording = true
        if format == .csv {
            write(CSVCodec.row(activeCSVColumns) + "\n", countsAsLine: false)
        }
        guard isRecording else { return nil }
        syncIndex()
        onRecordingChanged?(true)
        return url
    }

    /// `reason == nil` berarti dihentikan manual oleh user (tombol "Stop"),
    /// bukan karena limit — dipakai UI buat membedakan pesan yang ditampilkan.
    func stop(reason: String? = nil) {
        guard isRecording else { return }
        try? fileHandle?.synchronize()
        try? fileHandle?.close()
        fileHandle = nil
        publishProgress()
        isRecording = false
        stopReason = reason
        syncIndex(endedAt: Date())
        onRecordingChanged?(false)
    }

    /// Simpan buffer dan indeks saat masuk background, tanpa menutup sesi.
    func checkpoint() {
        guard isRecording else { return }
        do {
            try fileHandle?.synchronize()
            publishProgress()
            syncIndex()
        } catch {
            stop(reason: "Berhenti — gagal menyimpan rekaman: \(error.localizedDescription)")
        }
    }

    private func write(_ text: String, countsAsLine: Bool = true) {
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
        totalBytesWritten += data.count
        if countsAsLine { totalLineCount += 1 }
        if !countsAsLine || progressThrottle.consume(at: ProcessInfo.processInfo.systemUptime) {
            publishProgress()
        }
        if Date().timeIntervalSince(lastIndexSync) >= 10 { syncIndex() }
        enforceLimitsIfNeeded()
    }

    private func enforceLimitsIfNeeded() {
        guard isRecording else { return }
        if totalBytesWritten >= maxBytes {
            stop(reason: "Berhenti otomatis — rekaman mencapai batas ukuran \(maxBytes / 1_048_576) MB.")
            return
        }
        enforceDurationLimitIfNeeded()
    }

    private func publishProgress() {
        if bytesWritten != totalBytesWritten { bytesWritten = totalBytesWritten }
        if lineCount != totalLineCount { lineCount = totalLineCount }
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

    /// Dipanggil dari callback BLE dan tahap koneksi — no-op kalau tidak sedang merekam format
    /// ini, jadi aman dipanggil terus-menerus tanpa cek tambahan di pemanggil.
    func appendRaw(_ direction: LogDirection, _ message: String) {
        guard isRecording, format == .bleRaw, let started = startedAt else { return }
        let t = Date().timeIntervalSince(started)
        write(String(format: "[%9.3fs] [%@] %@\n", t, direction.rawValue, message))
    }

    // MARK: - CSV

    /// Satu waktu baris untuk semua sumber; timestamp asli dan usia sensor
    /// disimpan terpisah. Nilai tidak tersedia/basi ditulis kosong, bukan nol.
    func appendCSVRow(snapshot: TelemetrySnapshot, vin: String?, modelCode: String?,
                      location: CLLocation?, bleState: String, phone: PhoneSensorSample,
                      gpsAuthorization: String, gpsPrecise: Bool, appState: String, at now: Date) {
        guard isRecording, format == .csv, let started = startedAt else { return }
        write(Self.csvRow(snapshot: snapshot, vin: vin, modelCode: modelCode, location: location,
                          bleState: bleState, phone: phone, gpsAuthorization: gpsAuthorization,
                          gpsPrecise: gpsPrecise, appState: appState, at: now, startedAt: started, columns: activeCSVColumns) + "\n")
    }

    /// Formatter terpisah dari file handle agar kontrak ekspor bisa diuji
    /// tanpa menulis rekaman ke folder Documents pengguna.
    static func csvRow(snapshot: TelemetrySnapshot, vin: String?, modelCode: String?,
                       location: CLLocation?, bleState: String, phone: PhoneSensorSample,
                       gpsAuthorization: String, gpsPrecise: Bool, appState: String,
                       at now: Date, startedAt started: Date, columns: [String] = csvColumns) -> String {
        var fields: [String: String] = [
            "timestamp_iso": Self.timestampFormatter.string(from: now),
            "elapsed_s": CSVCodec.number(now.timeIntervalSince(started)),
            "schema_version": "2", "vin": vin ?? "", "modelCode": modelCode ?? "",
            "ble_state": bleState, "app_state": appState,
            "gps_authorization": gpsAuthorization, "gps_precise": gpsPrecise ? "1" : "0",
            "gps_status": "waiting", "motion_status": phone.motionStatus,
            "barometer_status": phone.barometerStatus, "phone_battery_state": phone.batteryState,
            "phone_thermal_state": phone.thermalState, "phone_placement": phone.placement.rawValue
        ]
        func put(_ key: String, _ value: Double?) { fields[key] = CSVCodec.number(value) }
        func valid(_ value: Double) -> Double? { value >= 0 && value.isFinite ? value : nil }
        for item in Self.ecuFields {
            let age = snapshot.receivedAt[item.key].map { max(0, now.timeIntervalSince($0)) }
            put("ecu_\(item.key)_age_s", age)
            // Counter info kendaraan tidak streaming; usia tetap disimpan.
            let info = item.key == "ecuPowerOnTime" || item.key == "ignOnCount"
            if bleState == "streaming", let age, (info || age <= 5) {
                put(item.column, snapshot.value(item.key))
            }
        }
        if gpsAuthorization == "denied" || gpsAuthorization == "restricted" { fields["gps_status"] = "denied" }
        if let location {
            let age = now.timeIntervalSince(location.timestamp)
            fields["gps_timestamp_iso"] = Self.timestampFormatter.string(from: location.timestamp)
            put("gps_age_s", max(0, age))
            let allowed = gpsAuthorization == "always" || gpsAuthorization == "whenInUse"
            let fresh = allowed && age >= -1 && age <= 5 && location.horizontalAccuracy >= 0
            fields["gps_status"] = fresh ? "active" : "stale"
            if !allowed { fields["gps_status"] = "denied" }
            if fresh {
                fields["gps_lat"] = CSVCodec.number(location.coordinate.latitude, decimals: 7)
                fields["gps_lon"] = CSVCodec.number(location.coordinate.longitude, decimals: 7)
                put("gps_speed_kmh", valid(location.speed).map { $0 * 3.6 })
                put("gps_accuracy_m", valid(location.horizontalAccuracy))
                put("gps_vertical_accuracy_m", valid(location.verticalAccuracy))
                if location.verticalAccuracy >= 0 { put("gps_alt_m", location.altitude) }
                put("gps_speed_accuracy_mps", valid(location.speedAccuracy))
                put("gps_course_deg", valid(location.course))
                put("gps_course_accuracy_deg", valid(location.courseAccuracy))
            }
        }
        if let m = phone.motion {
            fields["motion_timestamp_iso"] = Self.timestampFormatter.string(from: now.addingTimeInterval(-m.age))
            fields["motion_samples"] = String(m.count)
            put("motion_uptime_s", m.last.uptime)
            put("motion_age_s", m.age); put("motion_span_s", m.span)
            put("motion_ax_mps2", m.last.ax); put("motion_ay_mps2", m.last.ay); put("motion_az_mps2", m.last.az)
            put("motion_mean_ax_mps2", m.meanX); put("motion_mean_ay_mps2", m.meanY); put("motion_mean_az_mps2", m.meanZ)
            put("motion_peak_mps2", m.peak); put("motion_rms_mps2", m.rms)
            put("motion_vertical_peak_mps2", m.verticalPeak); put("motion_vertical_rms_mps2", m.verticalRMS)
            put("gravity_x_g", m.last.gx); put("gravity_y_g", m.last.gy); put("gravity_z_g", m.last.gz)
            put("gyro_x_radps", m.last.rx); put("gyro_y_radps", m.last.ry); put("gyro_z_radps", m.last.rz)
            put("roll_deg", m.last.roll); put("pitch_deg", m.last.pitch); put("yaw_deg", m.last.yaw)
            put("attitude_qw", m.last.qw); put("attitude_qx", m.last.qx); put("attitude_qy", m.last.qy); put("attitude_qz", m.last.qz)
        }
        put("phone_pressure_kpa", phone.pressureKPa); put("phone_relative_alt_m", phone.relativeAltitude)
        put("barometer_age_s", phone.barometerAge)
        put("barometer_uptime_s", phone.barometerUptime)
        if let date = phone.barometerTimestamp { fields["barometer_timestamp_iso"] = Self.timestampFormatter.string(from: date) }
        put("phone_battery_pct", phone.batteryPercent)
        fields["phone_low_power"] = phone.lowPower.map { $0 ? "1" : "0" } ?? ""
        return CSVCodec.row(columns.map { fields[$0] ?? "" })
    }
}
