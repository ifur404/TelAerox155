import Foundation
import Combine
import SwiftUI
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
@MainActor
final class TelemetryStore: NSObject, ObservableObject, YConnectClientDelegate {

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

    /// Log diagnostik mentah (semua frame TX/RX hex + narasi tahap), bertahan
    /// lintas sesi/reconnect — supaya "connect sukses tapi timeout" yang
    /// keburu putus sebelum sempat dibaca tetap kepegang buat dianalisa nanti
    /// (salin/simpan lewat idleView). Kredensial otomatis disensor di dalam.
    let diagLog = DiagnosticLog()

    /// Rekaman sesi ke file (BLE Raw / CSV per detik) — beda dari `diagLog`:
    /// ditulis langsung ke disk, punya limit ukuran/durasi, dan harus
    /// dinyalakan eksplisit oleh user (start/stop), bukan buffer pasif.
    let recorder = SessionRecorder()

    /// GPS — dipakai kolom gps_* di rekaman CSV. Nyala/mati otomatis mengikuti
    /// status rekaman CSV (lihat startLogCountTimer), bukan dikontrol
    /// terpisah oleh user, supaya baterai tidak boros GPS terus-menerus kalau
    /// tidak sedang merekam.
    let location = LocationProvider()

    /// Jumlah baris log terkumpul, buat ditampilin di UI. Di-refresh 1 Hz
    /// (bukan tiap frame — frame RX bisa ~20 Hz, jangan bikin SwiftUI diff
    /// tiap 50ms) lewat `logCountTimer`.
    @Published private(set) var logLineCount: Int = 0
    private var logCountTimer: Timer?

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

    /// Toggle log diagnostik: default MATI. Menyalakan log berarti setiap frame
    /// TX/RX mentah + tahap koneksi disimpan ke buffer `diagLog` (kredensial/VIN
    /// tetap disensor otomatis di dalamnya) — berguna buat debug tapi bukan
    /// sesuatu yang harus jalan terus-menerus tiap sesi normal.
    @AppStorage("diagLogEnabled") var diagLogEnabled: Bool = false

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

    func connect() {
        // B1: sebelumnya kalau client != nil (mis. sesi lama gagal/terputus dan
        // belum di-disconnect() manual), tombol "Hubungkan" diam total — guard
        // ini menolak membuat client baru. Sekarang bersihkan dulu sesi lama.
        if client != nil {
            client?.stop()
            client = nil
        }
        errorMessage = nil
        discovered.removeAll()
        authTrace.removeAll()
        if diagLogEnabled {
            diagLog.log(.info, "=== connect() dipanggil, keepAlivePolicy=\(keepAlivePolicy.rawValue) ===")
        }
        startLogCountTimer()
        do {
            guard let url = Bundle.main.url(forResource: "secrets.local", withExtension: "json") else {
                errorMessage = "secrets.local.json tidak ditemukan di bundle"
                return
            }
            let cred = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: url))
            let c = YConnectClient(credentials: cred)
            c.keepAlivePolicy = keepAlivePolicy
            #if canImport(UIKit)
            UIDevice.current.isBatteryMonitoringEnabled = true
            c.batteryLevelProvider = {
                let level = UIDevice.current.batteryLevel   // -1 kalau tak diketahui (simulator dll)
                return level < 0 ? 100 : Int((level * 100).rounded())
            }
            #endif
            c.onDiscovery = { [weak self] name, rssi, isMatch in
                if self?.diagLogEnabled == true {
                    self?.diagLog.log(.scan, "name=\(name ?? "-") rssi=\(rssi) match=\(isMatch)")
                }
                Task { @MainActor in
                    self?.addDiscovery(name: name, rssi: rssi, isMatch: isMatch)
                }
            }
            c.onAuthStage = { [weak self] stage in
                if self?.diagLogEnabled == true {
                    self?.diagLog.log(.info, stage)
                }
                Task { @MainActor in
                    self?.addAuthTrace(stage)
                }
            }
            c.onRawFrame = { [weak self] direction, message in
                if self?.diagLogEnabled == true {
                    self?.diagLog.log(direction, message)
                }
                self?.recorder.appendRaw(direction, message)
            }
            c.delegate = self
            client = c
            c.start()
        } catch {
            errorMessage = "Gagal memuat kredensial: \(error.localizedDescription)"
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
        client?.stop()
        client = nil
        state = .poweredOff
        snapshot = TelemetrySnapshot()
        vin = nil
        modelCode = nil
        setIdleTimerDisabled(false)
        if diagLogEnabled {
            diagLog.log(.info, "=== disconnect() dipanggil user ===")
        }
        refreshLogCount()
        stopLogCountTimer()
        if location.isActive { location.stop() }
    }

    // MARK: - Log diagnostik

    private func startLogCountTimer() {
        stopLogCountTimer()
        refreshLogCount()
        // Timer 1 Hz yang sama juga men-sampling satu baris CSV kalau rekaman
        // format CSV sedang aktif (appendCSVRow no-op kalau tidak) — cukup satu
        // timer buat dua keperluan, tidak perlu Timer terpisah 1 Hz lagi.
        // GPS dinyala/dimatikan mengikuti status rekaman CSV di tick yang sama.
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.refreshLogCount()
                let recordingCSV = self.recorder.isRecording && self.recorder.format == .csv
                if recordingCSV {
                    if !self.location.isActive { self.location.start() }
                    self.recorder.appendCSVRow(snapshot: self.snapshot, vin: self.vin,
                                               modelCode: self.modelCode, location: self.location.lastLocation)
                } else if self.location.isActive {
                    self.location.stop()
                }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        logCountTimer = t
    }

    private func stopLogCountTimer() {
        logCountTimer?.invalidate()
        logCountTimer = nil
    }

    private func refreshLogCount() {
        logLineCount = diagLog.count
    }

    /// Seluruh log siap salin/simpan.
    func logText() -> String { diagLog.text() }

    func clearLog() {
        diagLog.clear()
        refreshLogCount()
    }

    /// Jaga layar tetap nyala pas streaming (dipasang di motor, jangan sampai
    /// mati sendiri di tengah jalan) — dimatikan lagi begitu keluar streaming.
    private func setIdleTimerDisabled(_ disabled: Bool) {
        #if canImport(UIKit)
        UIApplication.shared.isIdleTimerDisabled = disabled
        #endif
    }

    // MARK: - YConnectClientDelegate

    func client(_ client: YConnectClient, didChangeState state: ClientState) {
        self.state = state
        setIdleTimerDisabled(state == .streaming)
    }

    func client(_ client: YConnectClient, didUpdate snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
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