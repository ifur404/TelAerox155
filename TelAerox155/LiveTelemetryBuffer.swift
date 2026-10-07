import Foundation

/// CSV selalu membaca paket terbaru; pembatas UI tidak membuang data sensor.
nonisolated struct LiveTelemetryBuffer {
    private(set) var latest = TelemetrySnapshot()
    private var displayThrottle = MonotonicThrottle(interval: 0.25)

    mutating func receive(_ snapshot: TelemetrySnapshot, at uptime: TimeInterval,
                          isForeground: Bool) -> TelemetrySnapshot? {
        latest = snapshot
        guard isForeground, displayThrottle.consume(at: uptime) else { return nil }
        return latest
    }
}
