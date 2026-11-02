import Foundation
import Combine
import CoreLocation
import MapKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

/// Navigasi turn-by-turn di dalam app (MapKit), supaya iPhone di holder bisa
/// dipakai dari lokasi ke lokasi tanpa pindah ke Google Maps/Apple Maps.
///
/// Murni fitur sisi iPhone: TIDAK ada komunikasi apa pun ke motor, jadi tidak
/// menyentuh batas read-only BLE di AGENTS.md. Telemetri motor hanya dibaca
/// oleh view untuk overlay.
///
/// Sengaja memakai `CLLocationManager` sendiri, bukan `LocationProvider` milik
/// `TelemetryStore`: provider itu dinyalakan/dimatikan otomatis oleh status
/// rekaman CSV, sehingga navigasi bisa ikut mati saat rekaman dihentikan.
final class NavigationSession: NSObject, ObservableObject, CLLocationManagerDelegate, MKLocalSearchCompleterDelegate {

    enum Phase: Equatable {
        case planning
        case calculating
        case preview          // rute sudah ada, belum mulai jalan
        case navigating
        case arrived
        case failed(String)
    }

    // MARK: Status publik untuk UI

    @Published private(set) var phase: Phase = .planning
    @Published private(set) var authorizationStatus: CLAuthorizationStatus
    @Published private(set) var location: CLLocation?

    @Published var query = "" {
        didSet { completer.queryFragment = query }
    }
    @Published private(set) var suggestions: [MKLocalSearchCompletion] = []

    @Published private(set) var destination: MKMapItem?
    @Published private(set) var route: MKRoute?

    /// Instruksi manuver berikutnya dan jaraknya dari posisi sekarang.
    @Published private(set) var nextInstruction: String = ""
    @Published private(set) var nextManeuver: ManeuverKind = .straight
    @Published private(set) var distanceToManeuver: Double = 0
    /// Instruksi sesudahnya (ditampilkan kecil sebagai "lalu ...").
    @Published private(set) var thenInstruction: String?
    @Published private(set) var remainingDistance: Double = 0
    @Published private(set) var remainingTime: TimeInterval = 0
    @Published private(set) var isRerouting = false

    @Published var voiceEnabled: Bool {
        didSet {
            UserDefaults.standard.set(voiceEnabled, forKey: "navVoiceEnabled")
            guard voiceEnabled != oldValue else { return }
            if !voiceEnabled {
                speech.stopSpeaking(at: .immediate)
            } else if phase == .navigating, !nextInstruction.isEmpty {
                // Baru dinyalakan di tengah jalan: langsung ucapkan instruksi
                // berikutnya supaya pengendara tidak menunggu ambang jarak.
                say(phrases.upcoming(distanceToManeuver, nextInstruction))
            }
        }
    }

    /// Prakiraan hujan di sepanjang rute (Open-Meteo). nil = belum ada data.
    @Published private(set) var rainOutlook: RainOutlook?

    // MARK: Internal

    private let manager = CLLocationManager()
    private let completer = MKLocalSearchCompleter()
    private let speech = AVSpeechSynthesizer()
    private var phrases: VoicePhrases { VoicePhrases.current }
    private var weatherTask: Task<Void, Never>?
    private var lastWeatherAt: Date?
    /// Interval cek ulang cuaca selama navigasi.
    private let weatherRefreshInterval: TimeInterval = 600

    private var geometry: RouteGeometry?
    private var progress: Double = 0
    private var offRouteCount = 0
    private var lastRerouteAt: Date?
    private var routeTask: Task<Void, Never>?
    /// Pengumuman suara yang sudah diucapkan: "<indeks step>-<ambang>".
    private var spoken = Set<String>()
    private var hasSearchRegion = false

    /// Ambang ≥ ini dianggap keluar rute (meter, ditambah akurasi GPS).
    private let offRouteThreshold: Double = 40
    private let arrivalThreshold: Double = 25

    override init() {
        authorizationStatus = manager.authorizationStatus
        voiceEnabled = UserDefaults.standard.object(forKey: "navVoiceEnabled") as? Bool ?? true
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.distanceFilter = 3
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    // MARK: - Siklus hidup

    /// Dipanggil saat layar navigasi muncul.
    func activate() {
        switch authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
        setScreenAwake(true)
    }

    /// Dipanggil saat layar navigasi ditutup: GPS dan suara dihentikan supaya
    /// baterai tidak terkuras di belakang layar.
    func deactivate() {
        routeTask?.cancel()
        weatherTask?.cancel()
        manager.stopUpdatingLocation()
        setBackgroundUpdates(false)
        speech.stopSpeaking(at: .immediate)
        deactivateAudioSession()
        setScreenAwake(false)
    }

    // MARK: - Pencarian tujuan

    func select(_ completion: MKLocalSearchCompletion) {
        query = ""
        suggestions = []
        phase = .calculating
        routeTask?.cancel()
        routeTask = Task { [weak self] in
            do {
                let response = try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
                guard let self, !Task.isCancelled else { return }
                guard let item = response.mapItems.first else {
                    self.phase = .failed("Lokasi tujuan tidak ditemukan.")
                    return
                }
                self.destination = item
                await self.calculateRoute(isReroute: false)
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.phase = .failed("Gagal mencari lokasi. Periksa koneksi internet.")
            }
        }
    }

    func clearDestination() {
        routeTask?.cancel()
        destination = nil
        route = nil
        geometry = nil
        weatherTask?.cancel()
        rainOutlook = nil
        lastWeatherAt = nil
        phase = .planning
        setBackgroundUpdates(false)
        speech.stopSpeaking(at: .immediate)
    }

    func retry() {
        if destination != nil {
            phase = .calculating
            routeTask?.cancel()
            routeTask = Task { [weak self] in await self?.calculateRoute(isReroute: false) }
        } else {
            phase = .planning
        }
    }

    // MARK: - Navigasi

    func start() {
        guard route != nil else { return }
        phase = .navigating
        offRouteCount = 0
        spoken.removeAll()
        setBackgroundUpdates(true)
        if let loc = location { updateProgress(with: loc) }
        if voiceEnabled {
            say(phrases.start(distanceToManeuver, nextInstruction))
            if let rain = rainOutlook, rain.isRain { say(rain.text(indonesian: phrases.indonesian)) }
        }
    }

    func stop() {
        clearDestination()
    }

    private func calculateRoute(isReroute: Bool) async {
        guard let destination else { return }
        guard let origin = location else {
            if !isReroute { phase = .failed("Menunggu sinyal GPS. Coba lagi sebentar.") }
            return
        }
        let request = MKDirections.Request()
        request.source = MKMapItem(location: origin, address: nil)
        request.destination = destination
        // MapKit tidak punya mode motor; pakai mobil tapi hindari tol dan jalan
        // bebas hambatan karena sepeda motor tidak boleh masuk tol di Indonesia.
        request.transportType = .automobile
        request.tollPreference = .avoid
        request.highwayPreference = .avoid
        request.requestsAlternateRoutes = false

        isRerouting = isReroute
        defer { isRerouting = false }
        do {
            let response = try await MKDirections(request: request).calculate()
            guard !Task.isCancelled else { return }
            guard let route = response.routes.first else {
                if !isReroute { phase = .failed("Rute tidak ditemukan.") }
                return
            }
            apply(route)
            if isReroute {
                if voiceEnabled { say(phrases.rerouted) }
                phase = .navigating
            } else {
                phase = .preview
            }
        } catch {
            guard !Task.isCancelled else { return }
            if !isReroute { phase = .failed("Gagal menghitung rute. Periksa koneksi internet.") }
        }
    }

    private func apply(_ route: MKRoute) {
        self.route = route
        geometry = RouteGeometry(steps: route.steps.map { $0.polyline.coordinates })
        progress = 0
        offRouteCount = 0
        spoken.removeAll()
        if let loc = location { updateProgress(with: loc) } else { refreshInstruction() }
        refreshWeather()
    }

    // MARK: - Cuaca

    /// Ambil prakiraan hujan untuk titik-titik di sisa rute. Gagal = diam
    /// (banner cuaca disembunyikan), navigasi tetap jalan normal.
    private func refreshWeather() {
        guard let geometry, let route else { return }
        lastWeatherAt = Date()
        let remaining = geometry.totalDistance > 0 ? max(geometry.totalDistance - progress, 0) / geometry.totalDistance : 0
        let points = RainForecast.checkpoints(geometry: geometry, progress: progress,
                                              remainingTime: route.expectedTravelTime * remaining, now: Date())
        weatherTask?.cancel()
        weatherTask = Task { [weak self] in
            let result = try? await RainForecast.fetch(points: points)
            guard let self, !Task.isCancelled else { return }
            let previous = self.rainOutlook
            self.rainOutlook = result
            // Umumkan hanya saat status berubah jadi hujan, bukan tiap refresh.
            if let result, result.isRain, self.phase == .navigating, self.voiceEnabled,
               previous?.kind != result.kind {
                self.say(result.text(indonesian: self.phrases.indonesian))
            }
        }
    }

    private func updateProgress(with loc: CLLocation) {
        guard let geometry, let route else { return }
        // Cari di sekitar progres sebelumnya supaya tidak loncat ke ruas lain.
        guard let match = geometry.match(loc.coordinate, minProgress: max(progress - 30, 0)) else { return }

        let tolerance = offRouteThreshold + max(loc.horizontalAccuracy, 0)
        if match.offset > tolerance {
            offRouteCount += 1
            if phase == .navigating, offRouteCount >= 3, !isRerouting,
               lastRerouteAt.map({ Date().timeIntervalSince($0) > 10 }) ?? true {
                lastRerouteAt = Date()
                routeTask?.cancel()
                routeTask = Task { [weak self] in await self?.calculateRoute(isReroute: true) }
            }
            return
        }
        offRouteCount = 0
        progress = match.progress
        refreshInstruction()

        remainingDistance = max(geometry.totalDistance - progress, 0)
        let fraction = geometry.totalDistance > 0 ? remainingDistance / geometry.totalDistance : 0
        remainingTime = route.expectedTravelTime * fraction

        if phase == .navigating,
           lastWeatherAt.map({ Date().timeIntervalSince($0) > weatherRefreshInterval }) ?? true {
            refreshWeather()
        }

        if phase == .navigating, remainingDistance <= arrivalThreshold {
            phase = .arrived
            setBackgroundUpdates(false)
            if voiceEnabled { say(phrases.arrived) }
        }
    }

    private func refreshInstruction() {
        guard let geometry, let route else { return }
        let steps = route.steps
        let current = geometry.stepIndex(at: progress)
        let nextIndex = current + 1
        if nextIndex < steps.count {
            let step = steps[nextIndex]
            nextInstruction = step.instructions.isEmpty ? phrases.continueText : step.instructions
            nextManeuver = ManeuverKind(instruction: step.instructions)
            distanceToManeuver = max(geometry.stepEnds[current] - progress, 0)
            let after = nextIndex + 1
            thenInstruction = after < steps.count && !steps[after].instructions.isEmpty ? steps[after].instructions : nil
        } else {
            nextInstruction = phrases.arriveText
            nextManeuver = .arrive
            distanceToManeuver = max(geometry.totalDistance - progress, 0)
            thenInstruction = nil
        }
        remainingDistance = max(geometry.totalDistance - progress, 0)
        if phase == .navigating { announceIfNeeded(stepIndex: nextIndex) }
    }

    /// Suara di ~500 m, ~150 m, dan saat manuver sudah dekat (~40 m).
    private func announceIfNeeded(stepIndex: Int) {
        guard voiceEnabled else { return }
        let d = distanceToManeuver
        for threshold in [500.0, 150.0, 40.0] where d <= threshold {
            let key = "\(stepIndex)-\(Int(threshold))"
            guard !spoken.contains(key) else { continue }
            // Tandai semua ambang yang lebih besar juga supaya tidak diucapkan beruntun.
            for t in [500.0, 150.0, 40.0] where t >= threshold { spoken.insert("\(stepIndex)-\(Int(t))") }
            if threshold == 40 {
                say(nextInstruction)
            } else {
                say(phrases.upcoming(d, nextInstruction))
            }
            break
        }
    }

    // MARK: - Suara

    private func say(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        activateAudioSession()
        let utterance = AVSpeechUtterance(string: trimmed)
        utterance.voice = AVSpeechSynthesisVoice(language: phrases.voiceLanguage)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        speech.speak(utterance)
    }

    private func activateAudioSession() {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        // Musik/podcast user dikecilkan sebentar saat instruksi diucapkan.
        try? session.setCategory(.playback, mode: .voicePrompt, options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        #endif
    }

    private func deactivateAudioSession() {
        #if canImport(UIKit)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    // MARK: - Helper sistem

    private func setScreenAwake(_ awake: Bool) {
        #if canImport(UIKit)
        // iPhone di holder: layar jangan auto-lock selama layar navigasi terbuka.
        UIApplication.shared.isIdleTimerDisabled = awake
        #endif
    }

    /// Lanjutkan GPS saat layar terkunci, hanya selama navigasi aktif. Sama
    /// seperti LocationProvider: wajib cek UIBackgroundModes dulu, kalau tidak
    /// iOS crash.
    private func setBackgroundUpdates(_ enabled: Bool) {
        guard let modes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String],
              modes.contains("location") else { return }
        manager.allowsBackgroundLocationUpdates = enabled
    }

    // MARK: - CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        switch authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            manager.startUpdatingLocation()
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        location = loc
        // Prioritaskan hasil pencarian di sekitar posisi sekarang (±25 km).
        if !hasSearchRegion {
            hasSearchRegion = true
            completer.region = MKCoordinateRegion(center: loc.coordinate, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        }
        if phase == .navigating || phase == .preview { updateProgress(with: loc) }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Diam: GPS sementara hilang (terowongan, gedung) itu normal di jalan.
    }

    // MARK: - MKLocalSearchCompleterDelegate

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        suggestions = query.isEmpty ? [] : Array(completer.results.prefix(8))
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        suggestions = []
    }
}

extension MKPolyline {
    nonisolated var coordinates: [CLLocationCoordinate2D] {
        var coords = [CLLocationCoordinate2D](repeating: kCLLocationCoordinate2DInvalid, count: pointCount)
        getCoordinates(&coords, range: NSRange(location: 0, length: pointCount))
        return coords
    }
}
