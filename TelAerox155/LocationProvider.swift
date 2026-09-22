import Foundation
import Combine
import CoreLocation

/// Penyedia lokasi GPS — MURNI buat kolom tambahan di rekaman CSV
/// (`SessionRecorder`), bukan bagian dari fitur telemetri BLE. Tidak
/// mempengaruhi kontrak keamanan read-only di AGENTS.md sama sekali (tidak
/// ada write ke motor); ini cuma sumber data tambahan buat log lokal user.
///
/// Diminta jalan juga di BACKGROUND (sama seperti rekaman BLE) — konsekuensi:
/// butuh izin lokasi "Selalu" (Always), bukan cuma "Saat Digunakan".
final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var lastLocation: CLLocation?
    @Published private(set) var isActive = false

    private let manager = CLLocationManager()

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = kCLDistanceFilterNone   // tiap update — CSV sampling 1 Hz butuh nilai sesegar mungkin, bukan cuma saat berpindah jauh
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true  // indikator standar iOS (pil biru) saat app pakai lokasi di background — transparansi ke user, bukan opsional
        // allowsBackgroundLocationUpdates HANYA aman di-set kalau app benar
        // punya UIBackgroundModes=location — kalau tidak, iOS crash
        // (NSInvalidArgumentException). Cek dulu daripada asumsi project
        // setting kepasang benar (lihat catatan verifikasi di project.pbxproj).
        if let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
           modes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
        }
    }

    func requestAuthorization() {
        manager.requestAlwaysAuthorization()
    }

    /// No-op kalau izin belum ada — otomatis minta izin dulu, panggilan
    /// berikutnya (tick 1 Hz berikutnya) baru benar-benar mulai begitu user
    /// merespons prompt sistem.
    func start() {
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
            isActive = true
        case .notDetermined:
            requestAuthorization()
        default:
            break   // denied/restricted — jangan spam prompt, user harus ubah di Pengaturan
        }
    }

    func stop() {
        manager.stopUpdatingLocation()
        isActive = false
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        lastLocation = locations.last
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Diam — GPS murni opsional buat CSV, jangan ganggu alur BLE utama
        // dengan errorMessage yang tidak relevan buat user.
    }
}
