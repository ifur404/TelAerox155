import Foundation

/// Jeda tunggu sebelum rekaman otomatis berhenti saat BLE terputus.
/// Mencegah perjalanan terpecah saat berhenti sebentar (lampu merah, isi bensin,
/// atau gangguan sinyal sesaat), sambil memastikan GPS & sensor langsung mati
/// saat motor benar-benar diparkir.
nonisolated enum AutoStopGracePeriod: Int, CaseIterable, Identifiable, Sendable {
    case oneMinute = 60
    case twoMinutes = 120
    case fiveMinutes = 300

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }

    var shortLabel: String {
        switch self {
        case .oneMinute: return "1 mnt"
        case .twoMinutes: return "2 mnt"
        case .fiveMinutes: return "5 mnt"
        }
    }

    var detailLabel: String {
        switch self {
        case .oneMinute: return "1 menit"
        case .twoMinutes: return "2 menit"
        case .fiveMinutes: return "5 menit"
        }
    }

    static func from(rawSeconds: Int) -> AutoStopGracePeriod {
        AutoStopGracePeriod(rawValue: rawSeconds) ?? .twoMinutes
    }
}

/// Batas waktu tanpa aktivitas berkendara sebelum rekaman CSV dipotong
/// (dihentikan) otomatis. Mencegah file membengkak saat motor parkir lama
/// dengan kontak menyala atau pengguna lupa menekan Stop; pada mode rekam
/// otomatis, segmen baru mulai otomatis saat aktivitas kembali terdeteksi.
nonisolated enum InactivityCutTimeout: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case threeMinutes = 180
    case fiveMinutes = 300
    case tenMinutes = 600

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var isEnabled: Bool { self != .off }

    var shortLabel: String {
        switch self {
        case .off: return "Mati"
        case .threeMinutes: return "3 mnt"
        case .fiveMinutes: return "5 mnt"
        case .tenMinutes: return "10 mnt"
        }
    }

    var detailLabel: String {
        switch self {
        case .off: return "nonaktif"
        case .threeMinutes: return "3 menit"
        case .fiveMinutes: return "5 menit"
        case .tenMinutes: return "10 menit"
        }
    }

    static func from(rawSeconds: Int) -> InactivityCutTimeout {
        InactivityCutTimeout(rawValue: rawSeconds) ?? .fiveMinutes
    }
}

/// Durasi efektif minimal agar rekaman CSV disimpan ke riwayat.
/// Rekaman yang berhenti di bawah batas ini (mis. kontak menyala sebentar di
/// garasi atau tertekan tidak sengaja) langsung dihapus agar riwayat bersih.
nonisolated enum MinimumRecordingDuration: Int, CaseIterable, Identifiable, Sendable {
    case off = 0
    case thirtySeconds = 30
    case oneMinute = 60
    case twoMinutes = 120

    var id: Int { rawValue }
    var seconds: TimeInterval { TimeInterval(rawValue) }
    var isEnabled: Bool { self != .off }

    var shortLabel: String {
        switch self {
        case .off: return "Mati"
        case .thirtySeconds: return "30 dtk"
        case .oneMinute: return "1 mnt"
        case .twoMinutes: return "2 mnt"
        }
    }

    var detailLabel: String {
        switch self {
        case .off: return "nonaktif"
        case .thirtySeconds: return "30 detik"
        case .oneMinute: return "1 menit"
        case .twoMinutes: return "2 menit"
        }
    }

    static func from(rawSeconds: Int) -> MinimumRecordingDuration {
        MinimumRecordingDuration(rawValue: rawSeconds) ?? .oneMinute
    }
}

/// Penyebab hitung mundur berhenti otomatis yang sedang berjalan.
nonisolated enum AutoStopReasonKind: String, Codable, Hashable, Sendable {
    case disconnected
    case inactivity
}

/// Tenggat hitung mundur berhenti otomatis beserta jenis pemicunya.
nonisolated struct AutoStopCountdown: Equatable, Sendable {
    let deadline: Date
    let kind: AutoStopReasonKind
}

/// Sampel sensor untuk mendeteksi apakah motor sedang aktif bergerak/digas,
/// berada di mode Idling Stop (SSS), atau diam.
/// Murni tipe nilai agar mudah diuji tanpa CoreBluetooth/CoreLocation.
nonisolated struct RideActivityInput: Equatable, Sendable {
    var isBLEStreaming: Bool = false
    var ecuSpeedKmh: Double?
    var ecuRPM: Double?
    var ecuThrottleDeg: Double?
    var ecuKeyOff: Bool = false
    var gpsSpeedKmh: Double?
    var gpsLatitude: Double?
    var gpsLongitude: Double?
    var gpsHorizontalAccuracy: Double?

    static let idle = RideActivityInput()
}

/// Hasil evaluasi aktivitas berkendara pada satu titik waktu.
nonisolated enum RideActivityStatus: Equatable, Sendable {
    /// Motor bergerak, digas, atau mesin baru menyala kembali (termasuk restart SSS).
    case active
    /// Idling Stop (SSS) terdeteksi: motor sudah sempat jalan dengan mesin hidup,
    /// kini berhenti dengan RPM 0 sementara kunci kontak masih ON dan BLE terhubung.
    case idlingStop
    /// Diam biasa (belum pernah jalan, kunci OFF, BLE terputus, atau idle diam).
    case inactive
}

/// Detektor aktivitas berkendara dari gabungan ECU dan GPS.
/// Idle mesin biasa (~1.500-1.800 rpm dengan kecepatan 0) TIDAK dianggap
/// aktivitas berkendara agar parkir lama dengan mesin menyala tetap terpotong,
/// tetapi Idling Stop (SSS) setelah motor berjalan dikenali secara khusus agar
/// rekaman tidak terpotong di lampu merah, macet, atau perlintasan kereta.
nonisolated struct RideActivityTracker: Equatable, Sendable {
    static let minECUSpeedKmh: Double = 2.0
    static let minGPSSpeedKmh: Double = 3.0
    static let minActiveRPM: Double = 2800.0
    static let minEngineRunningRPM: Double = 500.0
    static let minThrottleDeg: Double = 2.0
    static let minGPSDisplacementMeters: Double = 25.0
    static let maxGPSAccuracyMeters: Double = 30.0

    private var anchorLat: Double?
    private var anchorLon: Double?
    private(set) var hasDriven: Bool = false
    private(set) var hasSeenEngineRunning: Bool = false
    private var lastEngineRunning: Bool = false

    mutating func reset() {
        anchorLat = nil
        anchorLon = nil
        hasDriven = false
        hasSeenEngineRunning = false
        lastEngineRunning = false
    }

    mutating func evaluate(_ input: RideActivityInput) -> RideActivityStatus {
        var engineJustRestarted = false
        if !input.ecuKeyOff, let rpm = input.ecuRPM, rpm.isFinite {
            let running = rpm >= Self.minEngineRunningRPM
            if running && !lastEngineRunning && hasSeenEngineRunning {
                engineJustRestarted = true
            }
            if running { hasSeenEngineRunning = true }
            lastEngineRunning = running
        } else if input.ecuKeyOff || !input.isBLEStreaming {
            lastEngineRunning = false
        }

        if !input.ecuKeyOff {
            if let speed = input.ecuSpeedKmh, speed.isFinite, speed >= Self.minECUSpeedKmh {
                hasDriven = true
                updateAnchor(from: input)
                return .active
            }
            if let rpm = input.ecuRPM, rpm.isFinite, rpm >= Self.minActiveRPM {
                updateAnchor(from: input)
                return .active
            }
            if let throttle = input.ecuThrottleDeg, throttle.isFinite, throttle >= Self.minThrottleDeg {
                updateAnchor(from: input)
                return .active
            }
            if engineJustRestarted {
                updateAnchor(from: input)
                return .active
            }
        }

        if let acc = input.gpsHorizontalAccuracy, acc.isFinite, acc >= 0, acc <= Self.maxGPSAccuracyMeters {
            if let gpsSpeed = input.gpsSpeedKmh, gpsSpeed.isFinite, gpsSpeed >= Self.minGPSSpeedKmh {
                hasDriven = true
                updateAnchor(from: input)
                return .active
            }
            if let lat = input.gpsLatitude, let lon = input.gpsLongitude,
               (-90...90).contains(lat), (-180...180).contains(lon) {
                if let aLat = anchorLat, let aLon = anchorLon {
                    let moved = Self.haversineMeters(aLat, aLon, lat, lon)
                    let threshold = max(Self.minGPSDisplacementMeters, acc * 1.5)
                    if moved >= threshold {
                        hasDriven = true
                        anchorLat = lat
                        anchorLon = lon
                        return .active
                    }
                } else {
                    anchorLat = lat
                    anchorLon = lon
                }
            }
        }

        // Proteksi Idling Stop (SSS): motor sudah sempat jalan & mesin hidup,
        // sekarang berhenti dengan RPM = 0 tetapi kunci kontak masih ON (BLE streaming).
        if input.isBLEStreaming && !input.ecuKeyOff && hasDriven && hasSeenEngineRunning,
           let rpm = input.ecuRPM, rpm.isFinite, rpm == 0,
           let speed = input.ecuSpeedKmh, speed.isFinite, speed < Self.minECUSpeedKmh {
            return .idlingStop
        }

        return .inactive
    }

    mutating func isActive(_ input: RideActivityInput) -> Bool {
        evaluate(input) == .active
    }

    private mutating func updateAnchor(from input: RideActivityInput) {
        if let acc = input.gpsHorizontalAccuracy, acc.isFinite, acc >= 0, acc <= Self.maxGPSAccuracyMeters,
           let lat = input.gpsLatitude, let lon = input.gpsLongitude,
           (-90...90).contains(lat), (-180...180).contains(lon) {
            anchorLat = lat
            anchorLon = lon
        }
    }

    static func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(max(0, 1 - a)))
    }
}

/// Siapa yang memulai rekaman aktif — menentukan apakah auto-stop boleh
/// menghentikan sesi ketika BLE terputus.
nonisolated enum RecordingOwnership: Equatable, Sendable {
    case none
    case manual
    case automatic
}

/// Status mode hubungkan otomatis di lapisan aplikasi.
nonisolated enum AutoConnectMode: Equatable, Sendable {
    case off
    case armed
    case paused
}

/// Aksi BLE yang perlu dijalankan TelemetryStore setelah perubahan toggle/event
/// hubungkan otomatis.
nonisolated enum AutoConnectAction: Equatable, Sendable {
    case none
    case startStandby
    case stopStandby
}

/// Kebijakan hubungkan otomatis (auto-connect): mengatur kapan client harus
/// masuk mode siaga pasif (pending connect tanpa scan) dan kapan harus tunduk
/// pada tombol Putuskan/Jeda dari pengguna.
nonisolated struct AutoConnectPolicy: Equatable, Sendable {
    private(set) var isEnabled: Bool
    private(set) var hasPairing: Bool
    private(set) var isPausedByUser: Bool

    init(isEnabled: Bool = false, hasPairing: Bool = false, isPausedByUser: Bool = false) {
        self.isEnabled = isEnabled
        self.hasPairing = hasPairing
        self.isPausedByUser = isPausedByUser
    }

    var shouldBeStandby: Bool {
        isEnabled && hasPairing && !isPausedByUser
    }

    var mode: AutoConnectMode {
        guard isEnabled && hasPairing else { return .off }
        return isPausedByUser ? .paused : .armed
    }

    mutating func setEnabled(_ enabled: Bool, isCurrentlyConnectedOrConnecting: Bool, isCurrentlyStandby: Bool) -> AutoConnectAction {
        isEnabled = enabled
        if enabled {
            isPausedByUser = false
            if hasPairing && !isCurrentlyConnectedOrConnecting && !isCurrentlyStandby {
                return .startStandby
            }
            return .none
        } else {
            isPausedByUser = false
            if isCurrentlyStandby {
                return .stopStandby
            }
            return .none
        }
    }

    /// Pengguna menekan Putuskan / Batalkan / Jeda secara manual.
    /// Jika auto-connect aktif, jeda sementara agar app tidak langsung menyambung
    /// ulang melawan keinginan pengguna.
    mutating func userDidDisconnect() {
        if isEnabled && hasPairing {
            isPausedByUser = true
        }
    }

    /// Pengguna menekan Hubungkan secara manual — cabut jeda sementara.
    mutating func userDidConnect() {
        isPausedByUser = false
    }

    mutating func didCompletePairing() {
        hasPairing = true
        isPausedByUser = false
    }

    mutating func didForgetPairing() -> AutoConnectAction {
        let wasStandby = shouldBeStandby
        hasPairing = false
        isPausedByUser = false
        return wasStandby ? .stopStandby : .none
    }
}

/// Perintah yang dihasilkan `AutoRecordCoordinator` untuk dieksekusi `TelemetryStore`.
nonisolated enum AutoRecordCommand: Equatable, Sendable {
    case startAutomaticRecording
    case stopAutomaticRecording(reason: String)
    case discardAutomaticRecording(reason: String)
}

/// State machine murni untuk rekam perjalanan otomatis, pemotongan otomatis saat
/// tanpa aktivitas, dan pembuangan otomatis rekaman yang terlalu singkat.
/// Memakai `Date` (bukan `systemUptime`) karena `systemUptime` berhenti saat
/// iPhone deep sleep di background — sehingga app yang dibangunkan beberapa jam
/// kemudian tetap menutup/membuang sesi lama lebih dulu sebelum memulai sesi baru.
nonisolated struct AutoRecordCoordinator: Equatable, Sendable {
    private(set) var isEnabled: Bool
    private(set) var gracePeriod: AutoStopGracePeriod
    private(set) var inactivityTimeout: InactivityCutTimeout
    private(set) var minimumDuration: MinimumRecordingDuration
    private(set) var ownership: RecordingOwnership = .none
    private(set) var isStreaming: Bool = false
    private(set) var disconnectedAt: Date?
    /// Hanya rekaman CSV perjalanan yang mendukung potong otomatis saat diam
    /// dan pembuangan durasi singkat (frame BLE mentah adalah log debug manual).
    private(set) var recordingSupportsActivityCut: Bool = false
    private(set) var recordingStartedAt: Date?
    private(set) var firstActivityAt: Date?
    private(set) var lastActivityAt: Date?
    private(set) var inactiveSince: Date?
    /// True saat Idling Stop (SSS) aktif — menahan pemotongan otomatis jangka
    /// pendek hingga batas pengaman `idlingStopSafetySeconds` (15 menit) agar
    /// berhenti di lampu merah, macet, atau perlintasan kereta tidak memotong sesi.
    private(set) var isInIdlingStop: Bool = false
    /// True setelah rekaman otomatis dipotong karena tidak ada aktivitas saat
    /// motor masih terhubung — menahan restart sampai motor benar-benar bergerak lagi.
    private(set) var waitingForActivityToRestart: Bool = false
    /// Mencegah auto-start berulang di sesi koneksi motor yang sama setelah user
    /// menekan Stop manual atau rekaman mencapai batas ukuran/durasi.
    private(set) var suppressAutoStartUntilDisconnect: Bool = false

    /// Batas pengaman saat Idling Stop (SSS) aktif agar lampu merah/macet panjang
    /// tidak memotong perjalanan, sambil tetap mencegah rekaman lupa dimatikan berjam-jam.
    static let idlingStopSafetySeconds: TimeInterval = 15 * 60

    init(isEnabled: Bool = false,
         gracePeriod: AutoStopGracePeriod = .twoMinutes,
         inactivityTimeout: InactivityCutTimeout = .fiveMinutes,
         minimumDuration: MinimumRecordingDuration = .oneMinute) {
        self.isEnabled = isEnabled
        self.gracePeriod = gracePeriod
        self.inactivityTimeout = inactivityTimeout
        self.minimumDuration = minimumDuration
    }

    /// Tenggat berhenti karena motor terputus (khusus rekaman otomatis).
    var disconnectDeadline: Date? {
        guard ownership == .automatic, !isStreaming, let disconnectedAt else { return nil }
        return disconnectedAt.addingTimeInterval(gracePeriod.seconds)
    }

    /// Tenggat potong otomatis karena tidak ada aktivitas berkendara (khusus CSV).
    /// Saat Idling Stop (SSS) aktif, batas diperpanjang minimal 15 menit.
    var inactivityDeadline: Date? {
        guard recordingSupportsActivityCut, inactivityTimeout.isEnabled, let inactiveSince else { return nil }
        let limit = isInIdlingStop
            ? max(inactivityTimeout.seconds, Self.idlingStopSafetySeconds)
            : inactivityTimeout.seconds
        return inactiveSince.addingTimeInterval(limit)
    }

    /// Tenggat berhenti otomatis terdekat (putus BLE atau tanpa aktivitas).
    var nextAutoStopCountdown: AutoStopCountdown? {
        switch (disconnectDeadline, inactivityDeadline) {
        case let (d?, i?):
            return d <= i
                ? AutoStopCountdown(deadline: d, kind: .disconnected)
                : AutoStopCountdown(deadline: i, kind: .inactivity)
        case let (d?, nil):
            return AutoStopCountdown(deadline: d, kind: .disconnected)
        case let (nil, i?):
            return AutoStopCountdown(deadline: i, kind: .inactivity)
        case (nil, nil):
            return nil
        }
    }

    /// Tenggat waktu berhenti otomatis terdekat (kompatibel dengan UI & tes).
    var autoStopDeadline: Date? {
        nextAutoStopCountdown?.deadline
    }

    /// Tenggat yang pantas ditampilkan di UI: putus BLE langsung tampil;
    /// tanpa aktivitas baru muncul setelah diam minimal 60 detik atau sisa <= 60 detik;
    /// selama Idling Stop (SSS) aktif hanya tampil 60 detik terakhir sebelum batas pengaman.
    func visibleAutoStopCountdown(at now: Date) -> AutoStopCountdown? {
        guard let countdown = nextAutoStopCountdown else { return nil }
        switch countdown.kind {
        case .disconnected:
            return countdown
        case .inactivity:
            guard let inactiveSince else { return nil }
            let remaining = countdown.deadline.timeIntervalSince(now)
            if isInIdlingStop {
                return remaining <= 60 ? countdown : nil
            }
            let idleElapsed = now.timeIntervalSince(inactiveSince)
            return (idleElapsed >= 60 || remaining <= 60) ? countdown : nil
        }
    }

    func remainingGraceSeconds(at now: Date) -> TimeInterval? {
        guard let deadline = disconnectDeadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// Durasi efektif sesi tanpa menghitung waktu tunggu pasif setelah putus BLE
    /// atau setelah aktivitas terakhir sebelum dipotong otomatis.
    func effectiveDuration(for stopKind: AutoStopReasonKind?, at now: Date) -> TimeInterval {
        guard let startedAt = recordingStartedAt else { return 0 }
        switch stopKind {
        case .inactivity:
            guard let first = firstActivityAt, let last = lastActivityAt else { return 0 }
            return max(0, last.timeIntervalSince(first))
        case .disconnected:
            let cutoff = disconnectedAt ?? now
            return max(0, cutoff.timeIntervalSince(startedAt))
        case nil:
            return max(0, now.timeIntervalSince(startedAt))
        }
    }

    /// True jika sesi CSV saat ini berada di bawah durasi minimal yang layak disimpan.
    func shouldDiscard(for stopKind: AutoStopReasonKind?, at now: Date) -> Bool {
        guard recordingSupportsActivityCut, minimumDuration.isEnabled else { return false }
        return effectiveDuration(for: stopKind, at: now) < minimumDuration.seconds
    }

    /// Tangani perubahan state BLE streaming/non-streaming.
    /// Mengembalikan urutan perintah (biasanya 0 atau 1; bisa 2 jika app sempat
    /// tertidur melewati grace period lalu motor menyala lagi di perjalanan baru:
    /// `[.stopAutomaticRecording/.discardAutomaticRecording, .startAutomaticRecording]`).
    mutating func bleStateChanged(isStreaming streaming: Bool, isRecording: Bool, at now: Date) -> [AutoRecordCommand] {
        var commands: [AutoRecordCommand] = []

        if !isRecording {
            resetActiveSession()
        }

        if streaming {
            // Cek dulu apakah rekaman sebelumnya sudah melewati tenggat berhenti
            // saat app tertidur di background (mis. motor parkir berjam-jam).
            var recordingActive = isRecording
            if recordingActive, let expired = expiredAutoStop(at: now) {
                let wasStreamingBefore = isStreaming
                let wasAutomatic = ownership == .automatic
                commands.append(makeStopOrDiscardCommand(for: expired.kind, at: now))
                resetActiveSession()
                recordingActive = false
                if expired.kind == .inactivity && wasAutomatic && wasStreamingBefore {
                    waitingForActivityToRestart = true
                } else {
                    waitingForActivityToRestart = false
                }
            }

            isStreaming = true
            disconnectedAt = nil

            if isEnabled && !recordingActive && !suppressAutoStartUntilDisconnect && !waitingForActivityToRestart {
                beginSession(ownership: .automatic, supportsActivityCut: true, at: now, initialActivityAt: nil)
                commands.append(.startAutomaticRecording)
            }
        } else {
            isStreaming = false
            suppressAutoStartUntilDisconnect = false
            waitingForActivityToRestart = false
            if isInIdlingStop {
                // Keluar dari Idling Stop karena kunci dimatikan / BLE putus:
                // mulai hitung diam dari sekarang agar jeda putus BLE (mis. isi bensin)
                // tidak langsung terpotong secara retroaktif.
                isInIdlingStop = false
                if recordingSupportsActivityCut {
                    inactiveSince = now
                }
            }
            if isRecording && ownership == .automatic {
                // Jangan reset waktu putus jika sudah mulai menghitung mundur
                // (mis. transisi connecting -> poweredOff -> standby).
                if disconnectedAt == nil {
                    disconnectedAt = now
                }
            } else {
                disconnectedAt = nil
            }
        }

        return commands
    }

    /// Laporkan status aktivitas berkendara terbaru (`.active`, `.idlingStop`, atau `.inactive`).
    /// - `.active`: mereset hitung mundur tanpa aktivitas; jika sedang siaga pasca-potong
    ///   otomatis saat BLE tersambung, otomatis memulai segmen rekaman baru.
    /// - `.idlingStop`: menahan potong otomatis jangka pendek hingga batas pengaman 15 menit
    ///   agar berhenti di lampu merah/macet/kereta tidak memotong perjalanan.
    /// - `.inactive`: menghitung batas diam normal dan memotong bila melewati tenggat.
    mutating func processActivity(_ status: RideActivityStatus, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        if !isRecording {
            resetActiveSession()
            if isEnabled && isStreaming && waitingForActivityToRestart && !suppressAutoStartUntilDisconnect && status == .active {
                waitingForActivityToRestart = false
                beginSession(ownership: .automatic, supportsActivityCut: true, at: now, initialActivityAt: now)
                return .startAutomaticRecording
            }
            return nil
        }

        if recordingSupportsActivityCut {
            switch status {
            case .active:
                isInIdlingStop = false
                if firstActivityAt == nil { firstActivityAt = now }
                lastActivityAt = now
                inactiveSince = now
            case .idlingStop:
                isInIdlingStop = true
                if inactiveSince == nil {
                    inactiveSince = now
                }
            case .inactive:
                if isInIdlingStop {
                    isInIdlingStop = false
                    inactiveSince = now
                } else if inactiveSince == nil {
                    inactiveSince = now
                }
            }
        }

        return tick(isRecording: true, at: now)
    }

    mutating func processActivity(isActive: Bool, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        processActivity(isActive ? .active : .inactive, isRecording: isRecording, at: now)
    }

    /// Dicek berkala oleh timer 1 Hz, callback lokasi, dan saat app kembali ke foreground.
    mutating func tick(isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        guard isRecording else {
            resetActiveSession()
            return nil
        }
        guard let expired = expiredAutoStop(at: now) else {
            return nil
        }
        let command = makeStopOrDiscardCommand(for: expired.kind, at: now)
        let shouldWaitForActivity = expired.kind == .inactivity && ownership == .automatic && isStreaming
        resetActiveSession()
        waitingForActivityToRestart = shouldWaitForActivity
        return command
    }

    mutating func setEnabled(_ enabled: Bool, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        isEnabled = enabled
        if enabled {
            suppressAutoStartUntilDisconnect = false
            waitingForActivityToRestart = false
            if isStreaming && !isRecording {
                beginSession(ownership: .automatic, supportsActivityCut: true, at: now, initialActivityAt: nil)
                return .startAutomaticRecording
            }
            return nil
        } else {
            // Jika sedang merekam otomatis lalu toggle dimatikan, alihkan ke
            // kendali manual agar perjalanan yang sedang berjalan tidak hilang
            // dan tidak lagi dihentikan otomatis saat BLE putus.
            if isRecording && ownership == .automatic {
                ownership = .manual
            } else if !isRecording {
                resetActiveSession()
            }
            disconnectedAt = nil
            waitingForActivityToRestart = false
            return nil
        }
    }

    mutating func setGracePeriod(_ period: AutoStopGracePeriod, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        gracePeriod = period
        return tick(isRecording: isRecording, at: now)
    }

    mutating func setInactivityTimeout(_ timeout: InactivityCutTimeout, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        inactivityTimeout = timeout
        if !timeout.isEnabled {
            waitingForActivityToRestart = false
        }
        return tick(isRecording: isRecording, at: now)
    }

    mutating func setMinimumDuration(_ duration: MinimumRecordingDuration) {
        minimumDuration = duration
    }

    mutating func userStartedManualRecording(supportsActivityCut: Bool = true, at now: Date = Date()) {
        suppressAutoStartUntilDisconnect = false
        waitingForActivityToRestart = false
        beginSession(ownership: .manual, supportsActivityCut: supportsActivityCut, at: now, initialActivityAt: nil)
    }

    /// Hentikan rekaman secara manual. Jika `allowDiscardIfTooShort` true dan durasi
    /// rekaman CSV di bawah batas minimal, kembalikan alasan pembuangan agar caller
    /// menghapus file alih-alih menyimpannya.
    @discardableResult
    mutating func userStoppedRecording(allowDiscardIfTooShort: Bool = false, at now: Date = Date()) -> String? {
        let discardReason = (allowDiscardIfTooShort && shouldDiscard(for: nil, at: now))
            ? Self.shortManualDiscardReason(for: minimumDuration)
            : nil
        resetActiveSession()
        waitingForActivityToRestart = false
        if isStreaming {
            suppressAutoStartUntilDisconnect = true
        }
        return discardReason
    }

    mutating func recorderStoppedExternally() {
        resetActiveSession()
        waitingForActivityToRestart = false
        if isStreaming {
            suppressAutoStartUntilDisconnect = true
        }
    }

    private mutating func beginSession(ownership: RecordingOwnership,
                                       supportsActivityCut: Bool,
                                       at now: Date,
                                       initialActivityAt: Date?) {
        self.ownership = ownership
        self.disconnectedAt = nil
        self.recordingSupportsActivityCut = supportsActivityCut
        self.recordingStartedAt = now
        self.firstActivityAt = initialActivityAt
        self.lastActivityAt = initialActivityAt
        self.inactiveSince = supportsActivityCut ? now : nil
        self.isInIdlingStop = false
    }

    private mutating func resetActiveSession() {
        ownership = .none
        disconnectedAt = nil
        recordingSupportsActivityCut = false
        recordingStartedAt = nil
        firstActivityAt = nil
        lastActivityAt = nil
        inactiveSince = nil
        isInIdlingStop = false
    }

    private func expiredAutoStop(at now: Date) -> AutoStopCountdown? {
        guard let countdown = nextAutoStopCountdown, now >= countdown.deadline else { return nil }
        return countdown
    }

    private func makeStopOrDiscardCommand(for kind: AutoStopReasonKind, at now: Date) -> AutoRecordCommand {
        if shouldDiscard(for: kind, at: now) {
            return .discardAutomaticRecording(reason: Self.autoDiscardReason(for: kind, minimumDuration: minimumDuration))
        }
        switch kind {
        case .disconnected:
            return .stopAutomaticRecording(reason: Self.autoStopReason(for: gracePeriod))
        case .inactivity:
            return .stopAutomaticRecording(reason: Self.inactivityStopReason(for: inactivityTimeout))
        }
    }

    static func autoStopReason(for gracePeriod: AutoStopGracePeriod) -> String {
        "Berhenti otomatis — motor terputus selama \(gracePeriod.detailLabel)."
    }

    static func inactivityStopReason(for timeout: InactivityCutTimeout) -> String {
        "Dipotong otomatis — tidak ada aktivitas selama \(timeout.detailLabel)."
    }

    static func autoDiscardReason(for kind: AutoStopReasonKind, minimumDuration: MinimumRecordingDuration) -> String {
        switch kind {
        case .disconnected:
            return "Rekaman dibuang otomatis — durasi terlalu singkat (kurang dari \(minimumDuration.detailLabel))."
        case .inactivity:
            return "Rekaman dibuang otomatis — tidak ada aktivitas dan durasi aktif kurang dari \(minimumDuration.detailLabel)."
        }
    }

    static func shortManualDiscardReason(for minimumDuration: MinimumRecordingDuration) -> String {
        "Rekaman dibuang — durasi kurang dari \(minimumDuration.detailLabel)."
    }
}
