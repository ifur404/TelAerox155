import Foundation

/// UUID Nordic UART Service (NUS) yang dipakai CCU SCCU1.
nonisolated public enum NUS {
    public static let serviceString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let rxString      = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // notify dari CCU
    public static let txString      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // write ke CCU
}

/// Nama iklan CCU: "YSCCU_<ccuid>" atau "YCCU_<ccuid>". CCUID = 14 char terakhir.
nonisolated public enum DeviceName {
    public static let prefixes = ["YSCCU_", "YCCU_"]
    public static func matches(_ name: String) -> Bool {
        prefixes.contains { name.hasPrefix($0) }
    }
    public static func ccuid(from name: String) -> String? {
        guard matches(name), name.count >= 14 else { return nil }
        return String(name.suffix(14))
    }
}

/// Kebijakan keep-alive `0xA6` yang dikirim tiap 1 Hz selama streaming.
///
/// LATAR BELAKANG: app resmi Yamaha Motor On mengirim frame 0xA6 (058A + 058B)
/// setiap 1 detik seumur sesi, mulai tepat saat state == CONNECTED sampai
/// disconnect. Client ini dulu HANYA menulis satu frame (auth 0xAA) lalu diam
/// total — itu penyebab paling mungkin dari "connect sukses tapi timeout
/// beberapa detik kemudian": CCU (peripheral) menganggap central idle.
// nonisolated: tipe data murni yang dibandingkan/dipakai dari closure Timer
// yang @Sendable (nonisolated) — lihat armStreamWatchdog dkk di bawah. Tanpa
// ini, di bawah SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor proyek ini, conformance
// Equatable-nya ikut ter-infer MainActor-isolated (fitur InferIsolatedConformances)
// dan gagal dipakai di closure nonisolated tsb — warning sekarang, error di Swift 6.
nonisolated public enum KeepAlivePolicy: String, CaseIterable {
    /// Tidak kirim apa-apa setelah auth (perilaku lama — buat membuktikan ulang gejala).
    case off
    /// Hanya 058B (flag notifikasi = 00 00). Nol efek samping ke motor, tetap read-only.
    case notifyOnly
    /// 058A (tanggal/jam + baterai HP, ikut men-set jam dashboard) + 058B. Identik app resmi.
    case full
}

#if canImport(CoreBluetooth)
import CoreBluetooth

// nonisolated: sama alasannya dengan KeepAlivePolicy di atas — state ini
// dibandingkan (`self.state == .streaming`) di dalam closure Timer @Sendable
// (armAuthWatchdog/armConnectWatchdog/armStreamWatchdog/keepAliveTimer).
nonisolated public enum ClientState: Equatable {
    case poweredOff
    case scanning
    case connecting
    case authenticating
    case streaming
    case failed(String)
}

public protocol YConnectClientDelegate: AnyObject {
    func client(_ client: YConnectClient, didChangeState state: ClientState)
    func client(_ client: YConnectClient, didUpdate snapshot: TelemetrySnapshot)
    func client(_ client: YConnectClient, didReceiveVIN vin: String)
    func client(_ client: YConnectClient, didReceiveModelCode modelCode: String)
    func client(_ client: YConnectClient, didFailWith error: Error)
}

public extension YConnectClientDelegate {
    func client(_ client: YConnectClient, didReceiveVIN vin: String) {}
    func client(_ client: YConnectClient, didReceiveModelCode modelCode: String) {}
}

/// Client BLE read-only untuk Y-Connect / SCCU1.
///
/// KONTRAK KEAMANAN: byte yang ditulis ke motor hanya auth 0xAA dan, tergantung
/// `keepAlivePolicy`, frame periodik 0xA6 (058A/058B) — keduanya persis sama
/// dengan yang dikirim app resmi. Tidak ada write lain (tidak ada request FFD,
/// tidak ada kontrol kendaraan).
public final class YConnectClient: NSObject {

    public weak var delegate: YConnectClientDelegate?

    /// Dipanggil utk SETIAP peripheral yang terlihat iOS (sebelum filter nama).
    /// (name, rssi, isMatch) — buat debugging "gagal ketemu CCU": kita bisa
    /// lihat apakah iOS nangkep iklan sama sekali, namanya beneran kaya apa,
    /// dan RSSI-nya. Kalau name == nil tapi isMatch nil, berarti iOS liat
    /// peripheral tanpa nama (biasanya filter-by-service itu yg nyasar).
    public var onDiscovery: ((String?, Int, Bool) -> Void)?

    /// Trace fase koneksi — connecting → discovery → auth (0xAA → 0x5A →
    /// streaming / bonding fallback / gagal) → keep-alive → disconnect/reconnect.
    /// Buat nembus "connect sukses tapi timeout beberapa detik kemudian": pas
    /// di motor, trace ini nunjukin nyangkut di langkah mana.
    public var onAuthStage: ((String) -> Void)?

    /// Dump byte MENTAH tiap frame TX/RX (hex), buat diagnosa mendalam kalau
    /// `onAuthStage` saja belum cukup. Kredensial (ccuid/passKey/phoneUUID) dan
    /// VIN otomatis DISENSOR — aman ditampung ke log yang nanti dibagikan.
    public var onRawFrame: ((LogDirection, String) -> Void)?

    /// Kebijakan keep-alive 0xA6. Ganti SEBELUM `start()`; berlaku untuk sesi
    /// (termasuk reconnect otomatis) sampai diganti lagi.
    public var keepAlivePolicy: KeepAlivePolicy = .notifyOnly

    /// Sumber persen baterai HP untuk frame 058A (dipakai bila policy == .full).
    /// Default 100 — set dari lapisan app (mis. UIDevice.current.batteryLevel)
    /// supaya YConnectKit sendiri tidak bergantung UIKit.
    public var batteryLevelProvider: () -> Int = { 100 }

    /// Watchdog auth: kalau CCU udah digituin 0xAA tapi nggak balas 0x5A
    /// StartProcessing dalam N detik, kita nyerah dengan pesan yang jelas
    /// (bukan diem-diem nyangkut di .authenticating terus "putus tanpa sebab").
    public var authWatchdogSeconds: TimeInterval = 8
    private var authWatchdog: Timer?

    /// Watchdog fase connecting→discovery→subscribe (sebelum auth terkirim).
    /// Android punya timeout eksplisit 4 dt per langkah; iOS di sini dilonggarkan
    /// jadi satu watchdog ~10 dt yang menutupi seluruh fase itu.
    public var connectWatchdogSeconds: TimeInterval = 10
    private var connectWatchdog: Timer?

    /// Watchdog streaming: kalau sudah .streaming tapi tidak ada satupun frame
    /// RX valid dalam N detik (normalnya 0x55/0x56 datang tiap ~92 ms), sesuatu
    /// nyangkut — tandai gagal dengan pesan jelas, bukan diam sampai iOS sendiri
    /// yang akhirnya melaporkan disconnect.
    public var streamWatchdogSeconds: TimeInterval = 5
    private var streamWatchdog: Timer?

    private let credentials: Credentials
    private let decoder: TelemetryDecoder
    /// Bila auth pertama ditolak, coba sekali lagi dengan bondingFlag dibalik.
    public var allowBondingFallback: Bool = true

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?

    private var snapshot = TelemetrySnapshot()
    private var didTryBondingFallback = false
    private var lastBondedSent = false
    private var authCounter: UInt8 = 0
    private var didReportDecodeError = false

    /// true selama `stop()` dipanggil user — menekan auto-reconnect saat itu
    /// dan mencegah disconnect callback nyoba nyambung ulang sendiri.
    private var userRequestedStop = false

    // MARK: - Keep-alive 0xA6

    private var keepAliveTimer: Timer?
    private var periodicCounter: UInt8 = 0

    public private(set) var state: ClientState = .poweredOff {
        didSet { delegate?.client(self, didChangeState: state) }
    }

    public init(credentials: Credentials,
                decoder: TelemetryDecoder = TelemetryDecoder(),
                queue: DispatchQueue? = nil) {
        self.credentials = credentials
        self.decoder = decoder
        super.init()
        self.central = CBCentralManager(delegate: self, queue: queue)
    }

    public func start() {
        guard central.state == .poweredOn else { return }
        userRequestedStop = false
        state = .scanning
        // Scan SEMUA peripheral, bukan filter service UUID. CCU Aerox ngiklanin
        // NAMA ("YSCCU_<ccuid>" / "YCCU_<ccuid>") — UUID service NUS tidak selalu
        // ikut di paket advertisement, jadi iOS filter-by-service bisa nyasar CCU.
        // Pemfilteran dilakukan lewat nama di didDiscover (DeviceName + CCUID).
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    public func stop() {
        userRequestedStop = true
        disarmAuthWatchdog()
        disarmConnectWatchdog()
        disarmStreamWatchdog()
        stopKeepAlive()
        central.stopScan()
        if let p = peripheral {
            p.delegate = nil   // B8: jangan tinggalkan delegate ke peripheral lama
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil; txChar = nil; rxChar = nil
        didTryBondingFallback = false
    }

    // MARK: - Auth

    private func sendAuth(bonded: Bool) {
        guard let p = peripheral, let tx = txChar else { return }
        do {
            let frame = try AuthFrame.build(
                Credentials(ccuid: credentials.ccuid, passKey: credentials.passKey,
                            phoneUUID: credentials.phoneUUID, bonded: bonded),
                counter: authCounter)
            authCounter = authCounter &+ 1
            lastBondedSent = bonded
            state = .authenticating
            disarmConnectWatchdog()   // fase connecting→subscribe selesai, auth watchdog ambil alih
            // Watchdog auth: CCU harus balas 0x5A dalam N detik. Kalau diem,
            // kita yang putus duluan + kasih pesan yang jelas (bukan nyangkut di
            // .authenticating terus "terputus tanpa sebab").
            armAuthWatchdog(bonded: bonded)
            onAuthStage?("kirim 0xAA bonded=\(bonded ? 1 : 0) frame#\(authCounter - 1) (\(tx.uuid.uuidString.prefix(13))…)")
            onRawFrame?(.tx, "AUTH 0xAA bonded=\(bonded ? 1 : 0) #\(authCounter - 1) len=\(frame.count)B hex=\(Self.redactedAuthHex(frame))")
            // withoutResponse: TX char SCCU1 pakai property Write No Response.
            p.writeValue(Data(frame), for: tx, type: .withoutResponse)
        } catch {
            delegate?.client(self, didFailWith: error)
            state = .failed("gagal bangun auth frame: \(error)")
        }
    }

    private func armAuthWatchdog(bonded: Bool) {
        disarmAuthWatchdog()
        let label = "auth nyangkut kediem: CCU nggak balas 0x5A dalam \(Int(authWatchdogSeconds)) dt (bonded=\(bonded ? 1 : 0)). Matiin CCU, nyalain lagi, trus hubungkan ulang — kalau tetep, cek ccuid/passKey di secrets.local.json."
        let t = Timer(timeInterval: authWatchdogSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.disarmAuthWatchdog()
            if self.state == .authenticating {
                self.onAuthStage?(label)
                self.state = .failed(label)
                self.delegate?.client(self, didFailWith: AuthTimeout())
            } else {
                self.onAuthStage?("watchdog auth kepicu telat (state=\(self.state)) → diabaikan")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        authWatchdog = t
    }

    private func disarmAuthWatchdog() {
        authWatchdog?.invalidate()
        authWatchdog = nil
    }

    private func armConnectWatchdog() {
        disarmConnectWatchdog()
        let label = "nyangkut sebelum auth: connect/discovery/subscribe nggak selesai dalam \(Int(connectWatchdogSeconds)) dt. Coba matiin-nyalain Bluetooth HP, atau mendekat ke motor."
        let t = Timer(timeInterval: connectWatchdogSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.disarmConnectWatchdog()
            switch self.state {
            case .connecting:
                self.onAuthStage?(label)
                self.state = .failed(label)
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            default:
                break
            }
        }
        RunLoop.main.add(t, forMode: .common)
        connectWatchdog = t
    }

    private func disarmConnectWatchdog() {
        connectWatchdog?.invalidate()
        connectWatchdog = nil
    }

    private func armStreamWatchdog() {
        disarmStreamWatchdog()
        let t = Timer(timeInterval: streamWatchdogSeconds, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.disarmStreamWatchdog()
            if self.state == .streaming {
                let label = "stream berhenti — nggak ada frame valid \(Int(self.streamWatchdogSeconds)) dt"
                self.onAuthStage?(label)
                self.state = .failed(label)
                if let p = self.peripheral { self.central.cancelPeripheralConnection(p) }
            }
        }
        RunLoop.main.add(t, forMode: .common)
        streamWatchdog = t
    }

    private func disarmStreamWatchdog() {
        streamWatchdog?.invalidate()
        streamWatchdog = nil
    }

    struct AuthTimeout: LocalizedError {
        var errorDescription: String? { "auth watchdog timeout" }
    }

    // MARK: - Keep-alive 0xA6

    /// Mulai uplink 1 Hz persis app resmi: 058A di t=0 lalu tiap 1000 ms,
    /// 058B di t=+100 ms lalu tiap 1000 ms. Dipanggil begitu auth diterima.
    private func startKeepAlive() {
        stopKeepAlive()
        guard keepAlivePolicy != .off else {
            onAuthStage?("keep-alive 0xA6 mati (policy=off)")
            return
        }
        onAuthStage?("keep-alive 0xA6 1 Hz dimulai (policy=\(keepAlivePolicy.rawValue))")
        sendPeriodicTick()   // t=0
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sendPeriodicTick()
        }
        RunLoop.main.add(t, forMode: .common)
        keepAliveTimer = t
    }

    private func stopKeepAlive() {
        keepAliveTimer?.invalidate()
        keepAliveTimer = nil
    }

    private func sendPeriodicTick() {
        guard let p = peripheral, let tx = txChar, state == .streaming else { return }
        guard p.canSendWriteWithoutResponse else { return }   // lewati tick ini kalau buffer penuh

        if keepAlivePolicy == .full {
            let frame058A = PeriodicFrame.build058A(batteryPercent: batteryLevelProvider(),
                                                     counter: periodicCounter)
            onRawFrame?(.tx, "058A #\(periodicCounter) len=\(frame058A.count)B hex=\(DiagnosticLog.hex(frame058A))")
            periodicCounter = periodicCounter < 254 ? periodicCounter + 1 : 0
            p.writeValue(Data(frame058A), for: tx, type: .withoutResponse)
        }

        // 058B ~100 ms setelah 058A (atau di t=0 langsung kalau policy == .notifyOnly).
        let delay: TimeInterval = keepAlivePolicy == .full ? 0.1 : 0
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let p = self.peripheral, let tx = self.txChar, self.state == .streaming,
                  p.canSendWriteWithoutResponse else { return }
            let frame058B = PeriodicFrame.build058B(counter: self.periodicCounter)
            self.onRawFrame?(.tx, "058B #\(self.periodicCounter) len=\(frame058B.count)B hex=\(DiagnosticLog.hex(frame058B))")
            self.periodicCounter = self.periodicCounter < 254 ? self.periodicCounter + 1 : 0
            p.writeValue(Data(frame058B), for: tx, type: .withoutResponse)
        }
    }

    // MARK: - RX handling

    private func handleNotification(_ data: Data) {
        let raw = [UInt8](data)
        // Gerbang kebenaran: checksum wajib. Frame gagal checksum diabaikan.
        guard Checksum.verify(raw) else { return }

        onRawFrame?(.rx, "type=\(String(format: "0x%02X", raw.first ?? 0)) len=\(raw.count)B hex=\(Self.redactedRXHex(raw))")

        if state == .streaming { armStreamWatchdog() }   // frame valid apa pun = tanda hidup

        // Balasan auth?
        if raw.first == 0x5A, let sp = StartProcessing(raw) {
            disarmAuthWatchdog()
            if sp.accepted {
                onAuthStage?("terima 0x5A ACCEPTED (flag=\(sp.flag)) → streaming")
                state = .streaming
                armStreamWatchdog()
                startKeepAlive()
            } else if allowBondingFallback && !didTryBondingFallback {
                let nextBonded = !lastBondedSent
                onAuthStage?("terima 0x5A ditolak (flag=\(sp.flag)) → coba bonded=\(nextBonded ? 1 : 0) sekali")
                didTryBondingFallback = true
                sendAuth(bonded: nextBonded)
            } else {
                onAuthStage?("terima 0x5A DITOLAK (flag=\(sp.flag)), fallback udah kepake → nyerah")
                state = .failed("auth ditolak CCU (flag=\(sp.flag))")
            }
            return
        }

        guard let frame = try? Frame(verifying: raw), let type = frame.type else { return }
        // C3: gerbang tambahan yang dipakai app resmi — TLV walk harus berakhir
        // tepat 2 byte sebelum akhir frame. Checksum saja tidak menjamin ini.
        guard (try? frame.validateStructure()) != nil else { return }

        // VIN dari frame 0x5B record {f1,90}; kode model dari {f1,97} (mis. "BBP2").
        // Keduanya ASCII, jadi diekstrak terpisah dari pipeline numerik Mapping/TelemetryDecoder.
        if type == .common {
            if let vin = extractASCII(frame, localID: (0xF1, 0x90)) {
                delegate?.client(self, didReceiveVIN: vin)
            }
            if let model = extractASCII(frame, localID: (0xF1, 0x97)) {
                delegate?.client(self, didReceiveModelCode: model)
            }
        }

        do {
            let decoded = try decoder.decode(frame)
            if !decoded.isEmpty {
                snapshot.merge(decoded)
                delegate?.client(self, didUpdate: snapshot)
            }
        } catch {
            // C4: sebelumnya try? membuang error ini diam-diam — "layout frame
            // berubah" jadi kelihatan cuma "telemetri nggak update". Laporkan
            // sekali saja (trace di-cap 20 baris, jangan banjiri per-frame).
            if !didReportDecodeError {
                didReportDecodeError = true
                onAuthStage?("decode gagal (\(error)) — layout frame \(String(format: "0x%02X", type.rawValue)) tak terduga")
            }
        }
    }

    private func extractASCII(_ frame: Frame, localID: (UInt8, UInt8)) -> String? {
        guard let recs = try? frame.records() else { return nil }
        for r in recs where r.localID == localID {
            let slice = Array(frame.bytes[r.dataStart..<(r.dataStart + r.length)])
            return String(bytes: slice, encoding: .ascii)?
                .trimmingCharacters(in: .controlCharacters)
        }
        return nil
    }

    // MARK: - Log redaction

    /// Hex dump frame auth 0xAA dengan bytes[5..<57) (ccuid+passKey+phoneUUID,
    /// 52 byte) diganti placeholder — sisanya (header, bonding flag, counter,
    /// checksum) aman ditampilkan buat diagnosa layout/panjang frame.
    private static func redactedAuthHex(_ frame: [UInt8]) -> String {
        guard frame.count == AuthFrame.length else { return DiagnosticLog.hex(frame) }
        let header = DiagnosticLog.hex(Array(frame[0..<5]))
        let trailer = DiagnosticLog.hex(Array(frame[57..<60]))
        return "\(header) [52B kredensial disensor] \(trailer)"
    }

    /// Hex dump frame RX; kalau tipenya 0x5B (common/VIN), redact record
    /// {0xF1,0x90} (VIN) — sisa frame aman ditampilkan.
    private static func redactedRXHex(_ raw: [UInt8]) -> String {
        guard raw.first == FrameType.common.rawValue,
              let frame = try? Frame(verifying: raw),
              let recs = try? frame.records(),
              let vinRec = recs.first(where: { $0.localID == (0xF1, 0x90) }) else {
            return DiagnosticLog.hex(raw)
        }
        var out = raw
        for i in vinRec.dataStart..<(vinRec.dataStart + vinRec.length) where i < out.count {
            out[i] = 0x3F   // '?'
        }
        return DiagnosticLog.hex(out) + " (VIN disensor)"
    }
}

extension YConnectClient: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: start()
        default: state = .poweredOff
        }
    }

    public func centralManager(_ central: CBCentralManager,
                               didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Surface SEMUA yang kebaca buat debugging "gagal nemu CCU" di motor:
        // nama adv asli + RSSI + status match sama CCUID kita. UI pake ini buat
        // nampilin "perangkat terlihat" — kuncinya biar ketauan apakah iOS
        // nangkep iklan CCU sama sekali, dan namanya beneran kaya apa.
        let advName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
        var isMatch = false
        if let name = advName {
            isMatch = DeviceName.matches(name)
                && DeviceName.ccuid(from: name) == credentials.ccuid
        }
        onDiscovery?(advName, RSSI.intValue, isMatch)

        // Safety: JANGAN blind-connect. Sebelumnya kalau nama nil, kita connect
        // ke peripheral pertama yang ketemu — itu bisa nyasar ke device lain
        // (headset, HP) dan bikin "gagal nyari CCU". CCU Aerox selalu ngiklanin
        // nama "YSCCU_/YCCU_<ccuid>", jadi kalau nama nggak pernah muncul,
        // peripheral itu bukan CCU kita — lanjut scan aja.
        guard isMatch else { return }

        self.peripheral = peripheral
        central.stopScan()
        state = .connecting
        armConnectWatchdog()
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        onAuthStage?("BLE connect OK — discover services…")
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: NUS.serviceString)])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        disarmConnectWatchdog()
        state = .failed("gagal connect: \(describeCBError(error))")
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        disarmAuthWatchdog()
        disarmConnectWatchdog()
        disarmStreamWatchdog()
        stopKeepAlive()
        let reason = describeCBError(error)
        txChar = nil; rxChar = nil

        // B6: auto-reconnect kalau bukan user yang menekan "Putuskan". CCU
        // tidak mengingat sesi lama — sambungan baru wajib mengulang discover
        // → subscribe → kirim 0xAA lagi (ditangani otomatis lewat alur normal).
        if !userRequestedStop {
            onAuthStage?("terputus: \(reason) → coba nyambung ulang…")
            state = .connecting
            didTryBondingFallback = false
            armConnectWatchdog()
            central.connect(peripheral, options: nil)
        } else {
            onAuthStage?("terputus: \(reason)")
            state = .failed("terputus: \(reason)")
        }
    }

    private func describeCBError(_ error: Error?) -> String {
        guard let error else { return "normal" }
        let nsError = error as NSError
        guard nsError.domain == CBErrorDomain, let code = CBError.Code(rawValue: nsError.code) else {
            return error.localizedDescription
        }
        // Data paling berharga buat bedain "link supervision habis" (timeout,
        // biasanya berarti keep-alive kurang) dari "CCU sengaja putus".
        let codeLabel: String
        switch code {
        case .connectionTimeout: codeLabel = "connectionTimeout(6) — link supervision habis, kemungkinan idle terlalu lama"
        case .peripheralDisconnected: codeLabel = "peripheralDisconnected(7) — CCU yang mutus duluan"
        case .connectionFailed: codeLabel = "connectionFailed"
        default: codeLabel = "\(code)"
        }
        return "\(error.localizedDescription) [CBError.\(codeLabel)]"
    }
}

extension YConnectClient: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: NUS.serviceString)
        }) else { return }
        peripheral.discoverCharacteristics(
            [CBUUID(string: NUS.rxString), CBUUID(string: NUS.txString)], for: svc)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == CBUUID(string: NUS.rxString) {
                rxChar = c
                peripheral.setNotifyValue(true, for: c)   // enable notify (CCCD 01 00)
            } else if c.uuid == CBUUID(string: NUS.txString) {
                txChar = c
            }
        }
        // B2: auth dikirim dari didUpdateNotificationStateFor, BUKAN di sini —
        // supaya kita yakin subscription (CCCD) sudah benar-benar hidup dulu.
        // Kalau langsung kirim di sini dan 0x5A datang sebelum subscribe siap,
        // ACK-nya hilang dan client nyangkut di .authenticating.
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        guard characteristic.uuid == CBUUID(string: NUS.rxString) else { return }
        if let error {
            state = .failed("gagal aktifkan notify: \(error.localizedDescription)")
            return
        }
        guard characteristic.isNotifying, txChar != nil, rxChar != nil else { return }
        // iOS tidak punya API request MTU; nilai dinegosiasi otomatis.
        onAuthStage?("notify RX aktif (CCCD terpasang) → kirim auth")
        didTryBondingFallback = false
        sendAuth(bonded: credentials.bonded)
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: NUS.rxString),
              let data = characteristic.value else { return }
        handleNotification(data)
    }
}
#endif
