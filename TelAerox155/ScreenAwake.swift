import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Satu-satunya pengatur `isIdleTimerDisabled`. Beberapa fitur bisa minta
/// layar tetap nyala (streaming telemetri, navigasi); layar baru boleh
/// auto-lock lagi kalau SEMUA alasan sudah dilepas. Tanpa ini, BLE yang
/// putus-sambung di tengah navigasi bisa mematikan layar, atau menutup
/// navigasi mematikan layar padahal motor masih streaming.
enum ScreenAwake {
    enum Reason: Hashable { case telemetry, navigation }

    private static var reasons = Set<Reason>()

    static func set(_ reason: Reason, _ awake: Bool) {
        if awake { reasons.insert(reason) } else { reasons.remove(reason) }
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = !reasons.isEmpty
        #endif
    }
}
