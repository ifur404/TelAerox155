import Foundation

/// Satu gerbang untuk beberapa sumber callback; tidak mengejar tick terlewat.
nonisolated struct MonotonicThrottle {
    let interval: TimeInterval
    private var nextAllowed: TimeInterval?

    init(interval: TimeInterval) { self.interval = interval }

    mutating func consume(at uptime: TimeInterval) -> Bool {
        guard nextAllowed.map({ uptime >= $0 }) ?? true else { return false }
        nextAllowed = uptime + interval
        return true
    }

    func remaining(at uptime: TimeInterval) -> TimeInterval? {
        nextAllowed.map { max(0, $0 - uptime) }
    }
}

/// Callback RX cukup menggeser tenggat; timer tidak perlu dibuat ulang.
nonisolated struct InactivityDeadline {
    private var deadline: TimeInterval?

    mutating func recordActivity(at uptime: TimeInterval, timeout: TimeInterval) {
        deadline = uptime + timeout
    }

    func remaining(at uptime: TimeInterval) -> TimeInterval? {
        deadline.map { max(0, $0 - uptime) }
    }
}

/// Jeda bertahap untuk kegagalan transien (timeout auth/connect/stream atau
/// `didFailToConnect`) agar mode siaga otomatis tidak melakukan retry rapat yang
/// menguras baterai. Kembali ke 0 begitu koneksi berhasil mencapai streaming.
nonisolated public struct ReconnectBackoff: Equatable, Sendable {
    public static let defaultDelays: [TimeInterval] = [3, 10, 30, 60]

    public private(set) var consecutiveFailures = 0
    private let delays: [TimeInterval]

    public init(delays: [TimeInterval] = Self.defaultDelays) {
        self.delays = delays.isEmpty ? Self.defaultDelays : delays
    }

    public mutating func nextDelay() -> TimeInterval {
        let index = min(consecutiveFailures, delays.count - 1)
        consecutiveFailures += 1
        return delays[index]
    }

    public mutating func reset() {
        consecutiveFailures = 0
    }
}
