import SwiftUI
#if canImport(UIKit)
import UIKit

/// Memastikan `TelemetryStore` (beserta `CBCentralManager` dengan restore
/// identifier) langsung dibuat saat peluncuran aplikasi — termasuk ketika iOS
/// membangunkan app di background lewat CoreBluetooth State Restoration saat
/// kontak motor dinyalakan.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let store = TelemetryStore()

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        store.startAutoConnectIfNeeded()
        return true
    }
}
#endif

@main struct MyApp: App {
    #if canImport(UIKit)
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    #else
    @StateObject private var store = TelemetryStore()
    #endif

    var body: some Scene {
        WindowGroup {
            #if canImport(UIKit)
            ContentView(store: appDelegate.store)
            #else
            ContentView(store: store)
            #endif
        }
    }
}
