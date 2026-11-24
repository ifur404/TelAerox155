import Foundation
import CoreLocation

@main
struct LiveActivityChecks {
    static func main() {
        testIdleReturnsNil()
        testRecordingOnlyWithMotorTelemetry()
        testRecordingOnlyFallsBackToGPS()
        testNavigatingOnly()
        testNavigatingAndRecordingCombined()
        testArrivedState()
        testUrgentTransitionDetection()
        print("LiveActivityChecks: ALL PASSED")
    }

    private static func expect(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }

    private static func makeSnapshot(now: Date, speed: Double?, rpm: Double?, coolant: Double?, battery: Double?) -> TelemetrySnapshot {
        var snap = TelemetrySnapshot()
        var decoded: [DecodedValue] = []
        if let speed {
            decoded.append(DecodedValue(key: "speed", name: "Speed", raw: speed, value: speed, unit: "km/h"))
        }
        if let rpm {
            decoded.append(DecodedValue(key: "rpm", name: "RPM", raw: rpm, value: rpm, unit: "rpm"))
        }
        if let coolant {
            decoded.append(DecodedValue(key: "coolant", name: "Coolant", raw: coolant, value: coolant, unit: "°C"))
        }
        if let battery {
            decoded.append(DecodedValue(key: "battery", name: "Battery", raw: battery, value: battery, unit: "V"))
        }
        snap.merge(decoded, at: now)
        return snap
    }

    private static func baseInput(now: Date) -> RideLiveActivitySnapshotBuilder.Input {
        RideLiveActivitySnapshotBuilder.Input(
            isRecording: false,
            recordingStartedAt: nil,
            recordingFormat: .csv,
            isAutomaticRecording: false,
            autoStopDeadline: nil,
            lineCount: 0,
            isNavigating: false,
            hasArrived: false,
            isRerouting: false,
            maneuver: .straight,
            distanceToManeuver: 0,
            nextInstruction: "",
            destinationName: nil,
            remainingDistance: 0,
            remainingTime: 0,
            rainWarning: nil,
            snapshot: TelemetrySnapshot(),
            isMotorConnected: false,
            gpsLocation: nil,
            now: now
        )
    }

    private static func testIdleReturnsNil() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let state = RideLiveActivitySnapshotBuilder.build(baseInput(now: now))
        expect(state == nil, "idle state must return nil")
    }

    private static func testRecordingOnlyWithMotorTelemetry() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var input = baseInput(now: now)
        input.isRecording = true
        input.recordingStartedAt = now.addingTimeInterval(-125)
        input.isAutomaticRecording = true
        input.lineCount = 125
        input.isMotorConnected = true
        input.snapshot = makeSnapshot(now: now, speed: 54.6, rpm: 4860, coolant: 91.2, battery: 13.86)

        guard let state = RideLiveActivitySnapshotBuilder.build(input) else {
            expect(false, "recording state should not be nil")
            return
        }
        expect(state.mode == .recording, "mode should be .recording")
        expect(state.isRecording && !state.isNavigating, "recording flag only")
        expect(state.speedKmh == 55 && state.speedFromMotor, "speed should come from motor ECU")
        expect(state.rpm == 4900, "rpm should round to nearest 100")
        expect(state.coolantC == 91, "coolant should round to integer")
        expect(state.batteryV10 == 139 && state.batteryText == "13.9V", "battery should format tenths")
        expect(state.deepLinkURL.absoluteString == "telaerox://recording", "deep link should open recording")
    }

    private static func testRecordingOnlyFallsBackToGPS() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var input = baseInput(now: now)
        input.isRecording = true
        input.recordingStartedAt = now.addingTimeInterval(-60)
        input.recordingFormat = .csv
        input.isMotorConnected = false
        input.gpsLocation = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: -6.9175, longitude: 107.6191),
            altitude: 700,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 90,
            speed: 12.5, // 45 km/h
            timestamp: now.addingTimeInterval(-1)
        )

        guard let state = RideLiveActivitySnapshotBuilder.build(input) else {
            expect(false, "recording GPS fallback should not be nil")
            return
        }
        expect(state.speedKmh == 45 && !state.speedFromMotor, "should use GPS speed when motor disconnected")
        expect(state.speedSourceLabel == "GPS", "source label should be GPS")
    }

    private static func testNavigatingOnly() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var input = baseInput(now: now)
        input.isNavigating = true
        input.maneuver = .right
        input.distanceToManeuver = 240
        input.nextInstruction = "Belok kanan ke Jl. Braga"
        input.destinationName = "Alun-Alun Bandung"
        input.remainingDistance = 4200
        input.remainingTime = 620
        input.rainWarning = "Hujan ringan diperkirakan di tujuan"

        guard let state = RideLiveActivitySnapshotBuilder.build(input) else {
            expect(false, "navigating state should not be nil")
            return
        }
        expect(state.mode == .navigating, "mode should be .navigating")
        expect(state.maneuverSymbol == "arrow.turn.up.right", "right turn symbol")
        expect(state.distanceToManeuverText == "250 m", "distance formatted")
        expect(state.remainingDistanceText == "4,2 km", "remaining distance formatted")
        expect(state.rainWarning != nil, "rain warning preserved")
        expect(state.etaDate != nil, "eta date populated")
        expect(state.deepLinkURL.absoluteString == "telaerox://navigation", "deep link should open navigation")
    }

    private static func testNavigatingAndRecordingCombined() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var input = baseInput(now: now)
        input.isRecording = true
        input.recordingStartedAt = now.addingTimeInterval(-300)
        input.isNavigating = true
        input.maneuver = .left
        input.distanceToManeuver = 120
        input.nextInstruction = "Belok kiri"
        input.destinationName = "Gedung Sate"
        input.remainingDistance = 1500
        input.remainingTime = 240

        guard let state = RideLiveActivitySnapshotBuilder.build(input) else {
            expect(false, "combined state should not be nil")
            return
        }
        expect(state.mode == .navigatingAndRecording, "mode should be .navigatingAndRecording")
        expect(state.isRecording && state.isNavigating, "both flags active")
        expect(state.deepLinkURL.absoluteString == "telaerox://navigation", "combined mode opens navigation")
    }

    private static func testArrivedState() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var input = baseInput(now: now)
        input.hasArrived = true
        input.destinationName = "Rumah"

        guard let state = RideLiveActivitySnapshotBuilder.build(input) else {
            expect(false, "arrived state should not be nil")
            return
        }
        expect(state.hasArrived && state.isNavigating, "arrived keeps live activity visible")
        expect(state.activeManeuverSymbol == "flag.checkered", "arrived uses flag.checkered")
        expect(state.compactManeuverText == "Tiba", "compact text says Tiba")
        expect(state.nextInstruction == "Sudah sampai", "instruction says Sudah sampai")
        expect(state.etaDate == nil, "eta nil once arrived")
    }

    private static func testUrgentTransitionDetection() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        var input = baseInput(now: now)
        input.isRecording = true
        input.recordingStartedAt = now
        input.isMotorConnected = true
        input.snapshot = makeSnapshot(now: now, speed: 40, rpm: 4000, coolant: 85, battery: 14.0)

        let s1 = RideLiveActivitySnapshotBuilder.build(input)!

        var minor = input
        minor.lineCount = 5
        minor.snapshot = makeSnapshot(now: now, speed: 42, rpm: 4200, coolant: 85, battery: 14.0)
        let s2 = RideLiveActivitySnapshotBuilder.build(minor)!
        expect(!s2.isUrgentTransition(from: s1), "minor telemetry tick should be throttled (non-urgent)")

        var disconnected = input
        disconnected.isMotorConnected = false
        let s3 = RideLiveActivitySnapshotBuilder.build(disconnected)!
        expect(s3.isUrgentTransition(from: s1), "motor disconnect should be urgent")

        var startedNav = input
        startedNav.isNavigating = true
        startedNav.nextInstruction = "Belok kanan"
        let s4 = RideLiveActivitySnapshotBuilder.build(startedNav)!
        expect(s4.isUrgentTransition(from: s1), "mode switch to navigatingAndRecording should be urgent")

        var inactivityCountdown = input
        inactivityCountdown.autoStopDeadline = now.addingTimeInterval(240)
        inactivityCountdown.autoStopIsInactivity = true
        let s5 = RideLiveActivitySnapshotBuilder.build(inactivityCountdown)!
        expect(s5.autoStopIsInactivity && s5.isUrgentTransition(from: s1),
               "inactivity countdown transition should be urgent and flagged")
    }
}
