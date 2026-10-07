import Foundation

/// Jadwal monotonic bersama untuk timer dan callback BLE. Setelah suspend,
/// kirim frame yang jatuh tempo saja; jangan mengejar semua tick yang terlewat.
nonisolated struct KeepAliveSchedule {
    enum Frame: Equatable { case clock, notification }
    private(set) var deadline: TimeInterval?
    private var notificationPending = false

    mutating func next(at uptime: TimeInterval, policy: KeepAlivePolicy) -> Frame? {
        guard policy != .off, deadline.map({ uptime >= $0 }) ?? true else { return nil }
        if policy == .full && !notificationPending {
            notificationPending = true
            deadline = uptime + 0.1
            return .clock
        }
        notificationPending = false
        deadline = uptime + (policy == .full ? 0.9 : 1)
        return .notification
    }
}
