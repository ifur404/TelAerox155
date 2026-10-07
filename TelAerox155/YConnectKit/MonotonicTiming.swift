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
