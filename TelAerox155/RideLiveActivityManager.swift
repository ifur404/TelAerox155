import Foundation
import CoreLocation
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// Membangun snapshot `RideLiveActivityState` dari status rekaman, navigasi,
/// dan telemetri terbaru. Dipisah dari `ActivityKit` supaya murni deterministik
/// dan bisa diuji lewat `Tests/run.sh`.
nonisolated enum RideLiveActivitySnapshotBuilder {

    struct Input {
        var isRecording: Bool
        var recordingStartedAt: Date?
        var recordingFormat: SessionRecorder.Format
        var isAutomaticRecording: Bool
        var autoStopDeadline: Date?
        var autoStopIsInactivity: Bool = false
        var lineCount: Int

        var isNavigating: Bool
        var hasArrived: Bool
        var isRerouting: Bool
        var maneuver: ManeuverKind
        var distanceToManeuver: Double
        var nextInstruction: String
        var destinationName: String?
        var remainingDistance: Double
        var remainingTime: TimeInterval
        var rainWarning: String?

        var snapshot: TelemetrySnapshot
        var isMotorConnected: Bool
        var gpsLocation: CLLocation?
        var now: Date
    }

    static func build(_ input: Input) -> RideLiveActivityState? {
        let navActive = input.isNavigating || input.hasArrived
        guard input.isRecording || navActive else { return nil }

        let mode: RideLiveActivityState.Mode
        switch (input.isRecording, navActive) {
        case (true, true): mode = .navigatingAndRecording
        case (true, false): mode = .recording
        case (false, true): mode = .navigating
        case (false, false): return nil
        }

        let telemetry = HomeTelemetry(snapshot: input.snapshot,
                                      isStreaming: input.isMotorConnected,
                                      now: input.now)

        let ecuSpeed = telemetry.value("speed")
        let gpsSpeed = freshGPSSpeedKmh(from: input.gpsLocation, at: input.now)
        let speedKmh: Int?
        let speedFromMotor: Bool
        if let v = ecuSpeed, v >= 0 {
            speedKmh = Int(v.rounded())
            speedFromMotor = true
        } else if let g = gpsSpeed {
            speedKmh = Int(g.rounded())
            speedFromMotor = false
        } else {
            speedKmh = nil
            speedFromMotor = false
        }

        let rpm = telemetry.value("rpm").map { max(0, Int(($0 / 100.0).rounded()) * 100) }
        let coolantC = telemetry.value("coolant").map { Int($0.rounded()) }
        let batteryV10 = telemetry.value("battery").map { Int(($0 * 10.0).rounded()) }

        let roundedETA: Date?
        if input.isNavigating && !input.hasArrived && input.remainingTime > 0 {
            let raw = input.now.addingTimeInterval(input.remainingTime).timeIntervalSince1970
            let minute = (raw / 60.0).rounded() * 60.0
            roundedETA = Date(timeIntervalSince1970: minute)
        } else {
            roundedETA = nil
        }

        let instruction: String
        if input.hasArrived {
            instruction = "Sudah sampai"
        } else if !input.nextInstruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            instruction = input.nextInstruction
        } else {
            instruction = "Lanjutkan mengikuti rute"
        }

        return RideLiveActivityState(
            mode: mode,
            isRecording: input.isRecording,
            recordingStartedAt: input.isRecording ? input.recordingStartedAt : nil,
            recordingFormatLabel: input.recordingFormat == .csv ? "CSV" : "RAW",
            isAutomaticRecording: input.isRecording && input.isAutomaticRecording,
            autoStopDeadline: input.isRecording ? input.autoStopDeadline : nil,
            autoStopIsInactivity: input.isRecording && input.autoStopDeadline != nil && input.autoStopIsInactivity,
            lineCount: input.isRecording ? input.lineCount : 0,
            isNavigating: navActive,
            hasArrived: input.hasArrived,
            isRerouting: navActive && input.isRerouting,
            maneuverSymbol: input.hasArrived ? "flag.checkered" : input.maneuver.symbol,
            distanceToManeuverText: navActive ? DistanceText.format(input.distanceToManeuver) : "",
            nextInstruction: navActive ? instruction : "",
            destinationName: navActive ? (input.destinationName ?? "Tujuan") : "",
            remainingDistanceText: navActive ? DistanceText.format(input.remainingDistance) : "",
            etaDate: roundedETA,
            rainWarning: navActive ? input.rainWarning : nil,
            speedKmh: speedKmh,
            speedFromMotor: speedFromMotor,
            motorConnected: input.isMotorConnected,
            rpm: rpm,
            coolantC: coolantC,
            batteryV10: batteryV10
        )
    }

    private static func freshGPSSpeedKmh(from location: CLLocation?, at now: Date) -> Double? {
        guard let location,
              location.horizontalAccuracy >= 0,
              location.speed >= 0,
              location.speed.isFinite else { return nil }
        let age = now.timeIntervalSince(location.timestamp)
        guard age >= -1, age <= 10 else { return nil }
        return location.speed * 3.6
    }
}

/// Mengelola siklus hidup Dynamic Island / Lock Screen Live Activity secara
/// terpadu untuk rekaman aktif dan navigasi rute aktif.
///
/// Catatan iOS:
/// - `Activity.request(...)` hanya diizinkan oleh iOS saat app di foreground.
///   Kalau auto-record mulai di background (layar terkunci), permintaan akan
///   dicoba lagi otomatis saat user membuka app.
/// - Pembaruan (`activity.update(...)`) tetap berjalan di background selama
///   Live Activity sudah dibuat sebelumnya.
@MainActor
final class RideLiveActivityManager {
    private var lastSentState: RideLiveActivityState?
    private var updateThrottle = MonotonicThrottle(interval: 2.0)

    #if canImport(ActivityKit) && os(iOS)
    private var activity: Activity<RideLiveActivityAttributes>?
    private var isStarting = false
    private var pendingTask: Task<Void, Never>?

    init() {
        // Ambil kembali aktivitas lama kalau app sempat di-restart oleh iOS
        // saat rekaman masih berlangsung; akan dibersihkan otomatis saat sync
        // pertama bila tidak ada sesi aktif.
        self.activity = Activity<RideLiveActivityAttributes>.activities.first
    }

    func sync(state: RideLiveActivityState?,
              isForeground: Bool,
              uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let state else {
            endAllActivities()
            return
        }

        // Sambungkan ulang ke aktivitas aktif bila referensi lokal kosong.
        if activity == nil {
            activity = Activity<RideLiveActivityAttributes>.activities
                .first { $0.activityState == .active || $0.activityState == .stale }
        }

        if let current = activity, current.activityState == .active || current.activityState == .stale {
            if let last = lastSentState {
                guard state != last else { return }
                let urgent = state.isUrgentTransition(from: last)
                if !urgent && !updateThrottle.consume(at: uptime) {
                    return
                }
                if urgent {
                    _ = updateThrottle.consume(at: uptime)
                }
            } else {
                _ = updateThrottle.consume(at: uptime)
            }

            lastSentState = state
            let content = ActivityContent(state: state, staleDate: nil)
            enqueue {
                await current.update(content)
            }
            return
        }

        // Aktivitas belum ada atau sudah selesai/dismissed — bersihkan referensi.
        activity = nil
        lastSentState = nil

        // iOS menolak Activity.request dari background; tunggu sampai foreground.
        guard isForeground,
              !isStarting,
              ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        isStarting = true
        let attributes = RideLiveActivityAttributes(sessionID: UUID().uuidString)
        let content = ActivityContent(state: state, staleDate: nil)
        do {
            let started = try Activity.request(attributes: attributes, content: content, pushType: nil)
            self.activity = started
            self.lastSentState = state
            _ = updateThrottle.consume(at: uptime)
            // Bersihkan aktivitas yatim tambahan jika ada lebih dari satu.
            let extras = Activity<RideLiveActivityAttributes>.activities.filter { $0.id != started.id }
            if !extras.isEmpty {
                enqueue {
                    for extra in extras {
                        await extra.end(nil, dismissalPolicy: .immediate)
                    }
                }
            }
        } catch {
            // Jangan tampilkan alert error — mis. user mematikan Live Activities
            // di Pengaturan atau app baru saja transisi ke background.
        }
        isStarting = false
    }

    private func endAllActivities() {
        let existing = Activity<RideLiveActivityAttributes>.activities
        let hadAny = activity != nil || !existing.isEmpty
        activity = nil
        lastSentState = nil
        updateThrottle = MonotonicThrottle(interval: 2.0)
        guard hadAny else { return }
        enqueue {
            for item in existing {
                await item.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private func enqueue(_ work: @escaping @Sendable () async -> Void) {
        let previous = pendingTask
        pendingTask = Task {
            await previous?.value
            await work()
        }
    }
    #else
    func sync(state: RideLiveActivityState?,
              isForeground: Bool,
              uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastSentState = state
    }
    #endif
}
