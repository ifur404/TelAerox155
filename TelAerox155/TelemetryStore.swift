import Foundation
import Combine
import SwiftUI
import CoreLocation
#if canImport(UIKit)
import UIKit
#endif

/// Tampilan "perangkat kebaca pas scanning" — buat debugging "gagal nemu CCU":
/// nama adv (yang beneran diliat iOS) + RSSI + apakah match CCUID kita.
public struct DiscoveredDevice: Identifiable, Equatable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let isMatch: Bool

    public init(name: String?, rssi: Int, isMatch: Bool) {
        self.id = UUID()
        self.name = name
        self.rssi = rssi
        self.isMatch = isMatch
    }

    public var displayName: String { name ?? "(tanpa nama)" }
    public var isCCU: Bool {
        guard let n = name else { return false }
        return DeviceName.matches(n)
    }
}

// NOTE: YConnectClientDelegate sendiri tidak MainActor-isolated, tapi ini aman
// SELAMA YConnectClient dibuat dengan queue: nil (lihat connect() di bawah) —
// CBCentralManager lalu memanggil delegate-nya di main queue, yang sama dengan
// MainActor default executor. Kalau nanti queue custom dipakai, method delegate
// di bawah wajib di-nonisolated + hop manual ke MainActor.
enum PairingAttemptState: Equatable {
    case idle, connecting, paired, failed(String)
}

@MainActor
final class TelemetryStore: NSObject, ObservableObject, YConnectClientDelegate {

    @Published private(set) var hasPairing = false
    @Published private(set) var pairingAttempt: PairingAttemptState = .idle
    private var pendingPairing: PairingConfirmation?
    private var pairingTimeout: Task<Void, Never>?

    @Published var state: ClientState = .poweredOff
    @Published var snapshot = TelemetrySnapshot()
    @Published var vin: String?
    @Published var modelCode: String?
    @Published var errorMessage: String?

    /// Kumpulan yang barusan kebaca, flat buat SwiftUI. Resize paling akhir aja.
    @Published private(set) var discovered: [DiscoveredDevice] = []

    /// Trace tahap auth (0xAA → 0x5A → streaming / bonding fallback / timeout).
    /// Ditampilin di idleView supaya kalau nyangkut di "connect sukses tapi
    /// timeout beberapa detik kemudian" kelihatan nyangkut di langkah yang mana.
    @Published private(set) var authTrace: [String] = []

    private var client: YConnectClient?

    /// Subscription GPS/rekaman — lihat `bindRecorderToLocation()`.
    private var cancellables = Set<AnyCancellable>()

    /// Rekaman sesi ke file (BLE Raw / CSV per detik), dinyalakan eksplisit
    /// oleh user dan dibatasi ukuran/durasi.
    let recorder = SessionRecorder()

    /// GPS — dipakai kolom gps_* di rekaman CSV. Nyala/mati otomatis mengikuti
    /// status rekaman CSV (lihat bindRecorderToLocation), bukan dikontrol
    /// terpisah oleh user, supaya baterai tidak boros GPS terus-menerus kalau
    /// tidak sedang merekam.
    let location = LocationProvider()
    let phoneSensors = PhoneSensorProvider()
    private var appState = "foreground"

    private var recordingTimer: Timer?

    private var csvThrottle = MonotonicThrottle(interval: 1)
    private var liveTelemetry = LiveTelemetryBuffer()

    override init() {
        super.init()
        do { hasPairing = try PairingFile.load() != nil }
        catch { errorMessage = "Gagal membaca file pairing. Buka kunci iPhone dan coba lagi." }
        bindRecorderToLocation()
        observeAppLifecycle()
    }

    var isActive: Bool {
        switch state {
        case .streaming: return true
        default: return false
        }
    }

    /// Sedang di tengah proses connect (scan → connect → auth), sebelum sampai
    /// streaming ATAU gagal. Dulu tidak ada tombol batal di fase ini — kalau
    /// nyangkut (mis. auth diem sebelum watchdog 8 dt kepicu), user cuma bisa
    /// nunggu atau kill app. Sekarang tombol berubah jadi "Batalkan" di fase ini.
    var isConnecting: Bool {
        switch state {
        case .scanning, .connecting, .authenticating: return true
        default: return false
        }
    }

    /// Kebijakan keep-alive 0xA6: default "Penuh" (058A+058B) — hasil uji lapangan
    /// menunjukkan ini yang paling stabil (lihat docs/research/device-log-ble).
    /// Disimpan supaya toggle di UI bertahan antar sesi; perangkat yang sudah
    /// pernah memilih kebijakan lain TIDAK ikut berubah (default hanya berlaku
    /// sebelum key ini pernah ditulis).
    @AppStorage("keepAlivePolicy") private var keepAlivePolicyRaw: String = KeepAlivePolicy.full.rawValue
    var keepAlivePolicy: KeepAlivePolicy {
        get { KeepAlivePolicy(rawValue: keepAlivePolicyRaw) ?? .full }
        set { keepAlivePolicyRaw = newValue.rawValue }
    }

    func beginPairing(_ credentials: Credentials, device: NearbyPairingDevice) throws {
        guard !isActive && !isConnecting && pairingAttempt != .connecting else { return }
        try PairingDecoder.validate(credentials)
        guard let ccuid = device.ccuid, credentials.ccuid == ccuid else {
            throw PairingError.wrongMotorcycle
        }
        pendingPairing = try PairingConfirmation(credentials: credentials, peripheralID: device.id)
        pairingAttempt = .connecting
        state = .connecting
        openConnection(credentials, peripheralID: device.id, pairing: true)
        // Membatasi scan dan connect yang bisa pending tanpa batas di CoreBluetooth.
        pairingTimeout?.cancel()
        pairingTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled, let self, self.pendingPairing != nil else { return }
            self.failPairing("Motor belum menerima autentikasi. Dekatkan iPhone, pastikan kontak menyala, lalu coba lagi.")
        }
    }

    func resetPairingAttempt() {
        guard pairingAttempt != .connecting else { return }
        pairingAttempt = .idle
    }

    func cancelPairing() {
        guard pendingPairing != nil else { return }
        disconnect()
        pairingAttempt = .idle
    }

    private func failPairing(_ message: String) {
        disconnect()
        pairingAttempt = .failed(message)
    }

    func forgetPairing() throws {
        guard !isActive && !isConnecting else { throw PairingError.storage }
        try PairingFile.remove()
        hasPairing = false
        pairingAttempt = .idle
    }

    func connect() {
        do {
            guard let motor = try PairingFile.load() else {
                hasPairing = false
                errorMessage = "Pilih motor dan selesaikan pairing terlebih dahulu."
                return
            }
            hasPairing = true
            openConnection(motor.credentials, peripheralID: motor.peripheralID, pairing: false)
        } catch {
            errorMessage = "Gagal membaca file pairing. Buka kunci iPhone dan coba lagi."
        }
    }

    private func openConnection(_ credentials: Credentials, peripheralID: UUID, pairing: Bool) {
        client?.stop()
        client = nil
        snapshot = TelemetrySnapshot()
        liveTelemetry = LiveTelemetryBuffer()
        vin = nil
        modelCode = nil
        errorMessage = nil
        discovered.removeAll()
        authTrace.removeAll()
        let c = YConnectClient(credentials: credentials, targetPeripheralID: peripheralID,
                               restoresState: !pairing)
        c.keepAlivePolicy = keepAlivePolicy
        c.setBackgrounded(appState == "background")
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        c.batteryLevelProvider = {
            let level = UIDevice.current.batteryLevel
            return level < 0 ? 100 : Int((level * 100).rounded())
        }
        #endif
        c.onDiscovery = { [weak self] name, rssi, isMatch in
            self?.recorder.appendRaw(.scan, "name=\(name ?? "-") rssi=\(rssi) match=\(isMatch)")
            Task { @MainActor in self?.addDiscovery(name: name, rssi: rssi, isMatch: isMatch) }
        }
        c.onAuthStage = { [weak self] stage in
            self?.recorder.appendRaw(.info, stage)
            Task { @MainActor in self?.addAuthTrace(stage) }
        }
        c.delegate = self
        client = c
        updateRawFrameLogging()
        c.start()
    }

    /// Callback nil membuat interpolasi hex/redaksi dilewati di YConnectClient.
    /// Pasang hanya selama rekaman BLE mentah, termasuk saat reconnect.
    private func updateRawFrameLogging() {
        guard recorder.isRecording && recorder.format == .bleRaw else {
            client?.onRawFrame = nil
            return
        }
        client?.onRawFrame = { [weak self] direction, message in
            self?.recorder.appendRaw(direction, message)
        }
    }

    @MainActor
    private func addDiscovery(name: String?, rssi: Int, isMatch: Bool) {
        let dev = DiscoveredDevice(name: name, rssi: rssi, isMatch: isMatch)
        // Dedup by nama biar satu motor cuma satu entri; yang lama di-update
        // RSSI-nya (list tetep stabil di UI).
        if let idx = discovered.firstIndex(where: { $0.name == dev.name }) {
            discovered[idx] = dev
        } else {
            discovered.append(dev)
        }
        // Safety cap biar list nggak mbludak kalau motor kebanjiran iklan.
        if discovered.count > 20 {
            discovered.removeFirst(discovered.count - 20)
        }
    }

    @MainActor
    private func addAuthTrace(_ s: String) {
        authTrace.append(s)
        // Safety cap: 1 konek paling 2-3 baris, tapi retry berulang (disconnect
        // → reconnect otomatis) bisa menumpuk banyak siklus dalam satu sesi idle
        // — 50 baris cukup buat ~10 siklus reconnect tanpa kepotong.
        if authTrace.count > 50 {
            authTrace.removeFirst(authTrace.count - 50)
        }
    }

    func disconnect() {
        pendingPairing?.cancel()
        pendingPairing = nil
        pairingTimeout?.cancel()
        pairingTimeout = nil
        if pairingAttempt == .connecting { pairingAttempt = .idle }
        client?.delegate = nil
        client?.stop()
        client = nil
        state = .poweredOff
        snapshot = TelemetrySnapshot()
        liveTelemetry = LiveTelemetryBuffer()
        vin = nil
        modelCode = nil
        setIdleTimerDisabled(false)
        recorder.appendRaw(.info, "=== disconnect() dipanggil user ===")
        // Rekaman (recorder.isRecording) SENGAJA tidak ikut dihentikan di sini
        // — "Putuskan" cuma memutus BLE, bukan "Stop Rekam". Timer 1 Hz juga
        // SENGAJA tidak ikut dimatikan kalau rekaman masih aktif: itu satu-
        // satunya yang mengecek limit durasi (recorder.enforceDurationLimitIfNeeded)
        // walau BLE lagi terputus lama — tanpa ini, rekaman yang lupa di-Stop
        // pas motor mati/keluar jangkauan bisa nyangkut nyala tanpa batas
        // (baterai boros GPS terus, limit 6 jam nggak pernah kecek). Baris CSV
        // iPhone tetap direkam; kolom motor kosong selagi terputus.
        if !recorder.isRecording {
            stopRecordingTimer()
        }
        // GPS dibiarkan tetap nyala kalau CSV masih direkam supaya begitu user
        // connect() lagi, kolom gps_* langsung lanjut terisi tanpa perlu
        // restart rekaman manual (location cuma di-stop reaktif oleh
        // bindRecorderToLocation saat recorder benar-benar berhenti).
        let recordingCSV = recorder.isRecording && recorder.format == .csv
        if location.isActive && !recordingCSV { location.stop() }
    }

    // MARK: - Sampling rekaman

    private func startRecordingTimer() {
        guard recordingTimer == nil else { return }
        // Satu timer mengikuti tenggat sampling terakhir. Kalau callback BLE
        // mendahuluinya, jadwalkan sisa interval; jangan melewatkan satu detik
        // penuh hanya karena timer periodik bangun sedikit terlalu awal.
        let delay = recorder.format == .csv
            ? (csvThrottle.remaining(at: ProcessInfo.processInfo.systemUptime) ?? 1) : 1
        let t = Timer(timeInterval: max(0.001, delay), repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.recordingTimer = nil
                // Dicek tiap detik TERLEPAS dari state BLE/apakah ada baris
                // baru ditulis — supaya rekaman yang idle lama (disconnect
                // manual atau auto-reconnect berkepanjangan) tetap kena batas
                // durasi otomatis (lihat dokblok disconnect()).
                if self.recorder.format == .csv {
                    self.sampleCSVIfDue()
                } else {
                    self.recorder.enforceDurationLimitIfNeeded()
                }
                if self.recorder.isRecording { self.startRecordingTimer() }
            }
        }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        recordingTimer = t
    }

    private func stopRecordingTimer() {
        recordingTimer?.invalidate()
        recordingTimer = nil
    }

    /// Tulis maksimal satu baris CSV per detik dari timer, BLE, atau GPS.
    /// Semua sumber memakai gerbang monotonic yang sama:
    /// - timer 1 Hz (`startRecordingTimer`), cukup saat app di foreground atau
    ///   background dengan GPS aktif;
    /// - `client(_:didUpdate:)`, karena notifikasi BLE (~20 Hz) tetap
    ///   membangunkan app di background lewat `bluetooth-central` walau GPS
    ///   tidak aktif (mis. izin lokasi ditolak) — tanpa ini timer bisa telat/
    ///   berhenti kalau app disuspend dan baris CSV jadi bolong saat layar
    ///   dikunci. Throttle di sini yang menjaga hasilnya tetap 1 baris/detik
    ///   walau dipicu dari dua tempat.
    private func sampleCSVIfDue() {
        guard recorder.isRecording, recorder.format == .csv else { return }
        guard csvThrottle.consume(at: ProcessInfo.processInfo.systemUptime) else { return }
        recorder.enforceDurationLimitIfNeeded()
        guard recorder.isRecording else { return }
        let now = Date()
        recorder.appendCSVRow(snapshot: liveTelemetry.latest, vin: vin, modelCode: modelCode,
                              location: location.lastLocation, bleState: recordingState,
                              phone: phoneSensors.sample(placement: recorder.phonePlacement),
                              gpsAuthorization: location.authorizationName,
                              gpsPrecise: location.isPrecise, appState: appState, at: now)
    }

    private var recordingState: String {
        switch state {
        case .poweredOff: return "poweredOff"
        case .scanning: return "scanning"
        case .connecting: return "connecting"
        case .authenticating: return "authenticating"
        case .streaming: return "streaming"
        case .failed: return "failed"
        }
    }

    /// GPS mengikuti status rekaman CSV, tapi dinyalakan LANGSUNG saat rekaman
    /// dimulai (masih di foreground, saat tombol "Mulai Rekam" ditekan) —
    /// bukan menunggu tick timer 1 Hz berikutnya. Kalau layar keburu dikunci
    /// sebelum tick itu, `CLLocationManager.startUpdatingLocation()` tidak
    /// bisa dipanggil pertama kali dari background dengan izin "Saat
    /// Digunakan", jadi app kehilangan salah satu "penahan" background-nya.
    private func bindRecorderToLocation() {
        recorder.onRecordingChanged = { [weak self] isRecording in
            guard let self else { return }
            self.csvThrottle = MonotonicThrottle(interval: 1)
            self.updateRawFrameLogging()
            if isRecording {
                self.startRecordingTimer()
                if self.recorder.format == .csv {
                    self.location.start()
                    if self.recorder.includesMotionAndBarometer {
                        self.phoneSensors.start()
                    }
                }
                self.sampleCSVIfDue()
            } else {
                self.location.stop()
                self.phoneSensors.stop()
                self.stopRecordingTimer()
            }
        }

        // Update lokasi juga membangunkan sampler saat background, termasuk
        // ketika BLE terputus. Throttle yang sama mencegah baris duplikat.
        location.$lastLocation
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.sampleCSVIfDue() }
            .store(in: &cancellables)

        // Kalau start() dipanggil saat izin masih .notDetermined, itu cuma
        // memunculkan prompt sistem — begitu user merespons (izin diberikan),
        // coba start() lagi kalau rekaman CSV masih berjalan.
        location.$authorizationStatus
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                let recordingCSV = self.recorder.isRecording && self.recorder.format == .csv
                if recordingCSV && !self.location.isActive {
                    self.location.start()
                }
            }
            .store(in: &cancellables)
    }

    /// Catat transisi background/foreground ke rekaman BLE mentah yang aktif
    /// — murni buat mencocokkan "bolong" di CSV rekaman dengan momen layar
    /// dikunci saat menganalisa hasil rekaman nanti, tidak mempengaruhi alur.
    private func observeAppLifecycle() {
        #if canImport(UIKit)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in
                self?.appState = "background"
                self?.client?.setBackgrounded(true)
                self?.recorder.appendRaw(.info, "=== app → background ===")
                self?.recorder.checkpoint()
            }
            .store(in: &cancellables)
        NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            .sink { [weak self] _ in
                self?.appState = "foreground"
                if let self { self.snapshot = self.liveTelemetry.latest }
                self?.client?.setBackgrounded(false)
                self?.recorder.enforceDurationLimitIfNeeded()
                self?.recorder.appendRaw(.info, "=== app → foreground ===")
            }
            .store(in: &cancellables)
        #endif
    }

    /// Jaga layar tetap nyala pas streaming (dipasang di motor, jangan sampai
    /// mati sendiri di tengah jalan) — dimatikan lagi begitu keluar streaming.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    // MARK: - YConnectClientDelegate

    func client(_ client: YConnectClient, didReceiveAuthReply raw: [UInt8], peripheralID: UUID) {
        guard self.client === client, let pendingPairing else { return }
        do {
            guard try pendingPairing.receiveAuthReply(raw, from: peripheralID) else { return }
            self.pendingPairing = nil
            pairingTimeout?.cancel()
            pairingTimeout = nil
            hasPairing = true
            pairingAttempt = .paired
        } catch {
            Task { @MainActor [weak self] in
                guard let self, self.client === client else { return }
                self.failPairing("Auth diterima motor, tetapi file pairing gagal disimpan. Coba lagi.")
            }
        }
    }

    func client(_ client: YConnectClient, didChangeState state: ClientState) {
        guard self.client === client else { return }
        if pendingPairing != nil {
            if case .failed(let message) = state {
                Task { @MainActor [weak self] in
                    guard let self, self.client === client else { return }
                    self.failPairing(message)
                }
            } else if state == .poweredOff {
                Task { @MainActor [weak self] in
                    guard let self, self.client === client else { return }
                    self.failPairing("Bluetooth tidak siap. Periksa izin dan nyalakan Bluetooth, lalu coba lagi.")
                }
            }
        }
        // Jangan membawa snapshot dari koneksi sebelumnya ke sesi auth baru.
        if self.state == .streaming && state != .streaming {
            snapshot = TelemetrySnapshot()
            liveTelemetry = LiveTelemetryBuffer()
        }
        self.state = state
        setIdleTimerDisabled(state == .streaming)
    }

    func client(_ client: YConnectClient, didUpdate snapshot: TelemetrySnapshot) {
        guard self.client === client else { return }
        if let display = liveTelemetry.receive(snapshot, at: ProcessInfo.processInfo.systemUptime,
                                               isForeground: appState == "foreground") {
            self.snapshot = display
        }
        // Lihat dokblok sampleCSVIfDue(): notifikasi BLE ini yang menjaga
        // rekaman CSV tetap jalan di background walau timer 1 Hz telat/mati.
        sampleCSVIfDue()
    }

    func client(_ client: YConnectClient, didReceiveVIN vin: String) {
        self.vin = vin
    }

    func client(_ client: YConnectClient, didReceiveModelCode modelCode: String) {
        self.modelCode = modelCode
    }

    func client(_ client: YConnectClient, didFailWith error: Error) {
        errorMessage = error.localizedDescription
    }
}
