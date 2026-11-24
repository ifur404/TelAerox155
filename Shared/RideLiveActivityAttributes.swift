import Foundation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Status bersama untuk Live Activity (Dynamic Island & Lock Screen).
///
/// File ini dikompilasi di dua target sekaligus: aplikasi utama `TelAerox155`
/// dan widget extension `TelAerox155LiveActivity`. Sengaja dibuat `nonisolated`
/// agar conformance `Codable`, `Hashable`, `Sendable`, dan `ActivityAttributes`
/// tidak bentrok dengan `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.
///
/// Tidak berisi kredensial, VIN, atau koordinat mentah — hanya ringkasan UI
/// untuk pengendara.
nonisolated struct RideLiveActivityState: Codable, Hashable, Sendable {
    nonisolated enum Mode: String, Codable, Hashable, Sendable {
        case recording
        case navigating
        case navigatingAndRecording
    }

    var mode: Mode

    // MARK: - Rekaman sesi
    var isRecording: Bool
    var recordingStartedAt: Date?
    var recordingFormatLabel: String
    var isAutomaticRecording: Bool
    var autoStopDeadline: Date?
    var autoStopIsInactivity: Bool = false
    var lineCount: Int

    // MARK: - Navigasi rute
    var isNavigating: Bool
    var hasArrived: Bool
    var isRerouting: Bool
    var maneuverSymbol: String
    var distanceToManeuverText: String
    var nextInstruction: String
    var destinationName: String
    var remainingDistanceText: String
    /// Dibulatkan ke menit terdekat supaya update numerik tidak memicu push
    /// Live Activity tiap detik.
    var etaDate: Date?
    var rainWarning: String?

    // MARK: - Telemetri langsung
    var speedKmh: Int?
    var speedFromMotor: Bool
    var motorConnected: Bool
    /// Dibulatkan ke kelipatan 100 RPM agar hemat budget update ActivityKit.
    var rpm: Int?
    var coolantC: Int?
    /// Tegangan aki × 10 (mis. 139 = 13,9 V).
    var batteryV10: Int?

    var deepLinkURL: URL {
        switch mode {
        case .navigating, .navigatingAndRecording:
            return URL(string: "telaerox://navigation")!
        case .recording:
            return URL(string: "telaerox://recording")!
        }
    }

    var speedText: String {
        speedKmh.map { "\($0)" } ?? "--"
    }

    var speedSourceLabel: String {
        speedFromMotor ? "ECU" : "GPS"
    }

    var rpmText: String? {
        rpm.map { "\($0)" }
    }

    var coolantText: String? {
        coolantC.map { "\($0)°C" }
    }

    var batteryText: String? {
        batteryV10.map { String(format: "%.1fV", Double($0) / 10.0) }
    }

    var isCoolantWarning: Bool {
        (coolantC ?? 0) >= 110
    }

    var isBatteryWarning: Bool {
        guard let v10 = batteryV10 else { return false }
        return v10 < 120
    }

    var compactManeuverText: String {
        if hasArrived { return "Tiba" }
        if isRerouting { return "Rute…" }
        return distanceToManeuverText.isEmpty ? "Rute" : distanceToManeuverText
    }

    var activeManeuverSymbol: String {
        if hasArrived { return "flag.checkered" }
        if isRerouting { return "arrow.triangle.2.circlepath" }
        return maneuverSymbol.isEmpty ? "arrow.up" : maneuverSymbol
    }

    var etaClockText: String? {
        etaDate.map { $0.formatted(date: .omitted, time: .shortened) }
    }

    /// Perubahan struktural yang harus langsung dikirim ke Dynamic Island
    /// tanpa menunggu jeda throttle 2 detik.
    func isUrgentTransition(from previous: RideLiveActivityState) -> Bool {
        mode != previous.mode
            || isRecording != previous.isRecording
            || recordingStartedAt != previous.recordingStartedAt
            || recordingFormatLabel != previous.recordingFormatLabel
            || isAutomaticRecording != previous.isAutomaticRecording
            || autoStopDeadline != previous.autoStopDeadline
            || autoStopIsInactivity != previous.autoStopIsInactivity
            || isNavigating != previous.isNavigating
            || hasArrived != previous.hasArrived
            || isRerouting != previous.isRerouting
            || maneuverSymbol != previous.maneuverSymbol
            || nextInstruction != previous.nextInstruction
            || destinationName != previous.destinationName
            || motorConnected != previous.motorConnected
            || rainWarning != previous.rainWarning
    }
}

#if canImport(ActivityKit) && os(iOS)
nonisolated struct RideLiveActivityAttributes: ActivityAttributes {
    typealias ContentState = RideLiveActivityState

    /// Pengenal sesi aktivitas untuk membedakan instance lama/baru.
    var sessionID: String
}
#endif
