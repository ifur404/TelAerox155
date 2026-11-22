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
}

/// State machine murni untuk rekam perjalanan otomatis (auto-record).
/// Memakai `Date` untuk jeda tunggu (grace period) karena `systemUptime` berhenti
/// saat iPhone deep sleep di background — sehingga app yang dibangunkan beberapa
/// jam kemudian oleh motor baru tetap menutup perjalanan lama lebih dulu sebelum
/// memulai file perjalanan baru.
nonisolated struct AutoRecordCoordinator: Equatable, Sendable {
    private(set) var isEnabled: Bool
    private(set) var gracePeriod: AutoStopGracePeriod
    private(set) var ownership: RecordingOwnership = .none
    private(set) var isStreaming: Bool = false
    private(set) var disconnectedAt: Date?
    /// Mencegah auto-start berulang di sesi koneksi motor yang sama setelah user
    /// menekan Stop manual atau rekaman mencapai batas ukuran/durasi.
    private(set) var suppressAutoStartUntilDisconnect: Bool = false

    init(isEnabled: Bool = false, gracePeriod: AutoStopGracePeriod = .twoMinutes) {
        self.isEnabled = isEnabled
        self.gracePeriod = gracePeriod
    }

    /// Tenggat waktu berhenti otomatis jika sedang hitung mundur.
    var autoStopDeadline: Date? {
        guard ownership == .automatic, !isStreaming, let disconnectedAt else { return nil }
        return disconnectedAt.addingTimeInterval(gracePeriod.seconds)
    }

    func remainingGraceSeconds(at now: Date) -> TimeInterval? {
        guard let deadline = autoStopDeadline else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// Tangani perubahan state BLE streaming/non-streaming.
    /// Mengembalikan urutan perintah (biasanya 0 atau 1; bisa 2 jika app sempat
    /// tertidur melewati grace period lalu motor menyala lagi di perjalanan baru:
    /// `[.stopAutomaticRecording, .startAutomaticRecording]`).
    mutating func bleStateChanged(isStreaming streaming: Bool, isRecording: Bool, at now: Date) -> [AutoRecordCommand] {
        var commands: [AutoRecordCommand] = []

        if !isRecording {
            ownership = .none
            disconnectedAt = nil
        }

        if streaming {
            // Cek dulu apakah rekaman otomatis sebelumnya sudah melewati grace period
            // saat app tertidur di background (mis. GPS mati/ditolak sehingga timer
            // tidak jalan selama motor parkir berjam-jam).
            var recordingActive = isRecording
            if recordingActive, ownership == .automatic, let deadline = autoStopDeadline, now >= deadline {
                let reason = Self.autoStopReason(for: gracePeriod)
                ownership = .none
                disconnectedAt = nil
                recordingActive = false
                commands.append(.stopAutomaticRecording(reason: reason))
            }

            isStreaming = true
            disconnectedAt = nil

            if isEnabled && !recordingActive && !suppressAutoStartUntilDisconnect {
                ownership = .automatic
                commands.append(.startAutomaticRecording)
            }
        } else {
            isStreaming = false
            suppressAutoStartUntilDisconnect = false
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

    /// Dicek berkala oleh timer 1 Hz, callback lokasi, dan saat app kembali ke foreground.
    mutating func tick(isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        guard isRecording else {
            ownership = .none
            disconnectedAt = nil
            return nil
        }
        guard ownership == .automatic, !isStreaming, let deadline = autoStopDeadline else {
            return nil
        }
        if now >= deadline {
            ownership = .none
            disconnectedAt = nil
            return .stopAutomaticRecording(reason: Self.autoStopReason(for: gracePeriod))
        }
        return nil
    }

    mutating func setEnabled(_ enabled: Bool, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        isEnabled = enabled
        if enabled {
            suppressAutoStartUntilDisconnect = false
            if isStreaming && !isRecording {
                ownership = .automatic
                disconnectedAt = nil
                return .startAutomaticRecording
            }
            return nil
        } else {
            // Jika sedang merekam otomatis lalu toggle dimatikan, alihkan ke
            // kendali manual agar perjalanan yang sedang berjalan tidak hilang
            // dan tidak lagi dihentikan otomatis.
            if isRecording && ownership == .automatic {
                ownership = .manual
            } else if !isRecording {
                ownership = .none
            }
            disconnectedAt = nil
            return nil
        }
    }

    mutating func setGracePeriod(_ period: AutoStopGracePeriod, isRecording: Bool, at now: Date) -> AutoRecordCommand? {
        gracePeriod = period
        return tick(isRecording: isRecording, at: now)
    }

    mutating func userStartedManualRecording() {
        ownership = .manual
        disconnectedAt = nil
        suppressAutoStartUntilDisconnect = false
    }

    mutating func userStoppedRecording() {
        ownership = .none
        disconnectedAt = nil
        if isStreaming {
            suppressAutoStartUntilDisconnect = true
        }
    }

    mutating func recorderStoppedExternally() {
        ownership = .none
        disconnectedAt = nil
        if isStreaming {
            suppressAutoStartUntilDisconnect = true
        }
    }

    static func autoStopReason(for gracePeriod: AutoStopGracePeriod) -> String {
        "Berhenti otomatis — motor terputus selama \(gracePeriod.detailLabel)."
    }
}
