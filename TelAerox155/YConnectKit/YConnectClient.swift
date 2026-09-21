import Foundation

/// UUID Nordic UART Service (NUS) yang dipakai CCU SCCU1.
public enum NUS {
    public static let serviceString = "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"
    public static let rxString      = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E" // notify dari CCU
    public static let txString      = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E" // write ke CCU
}

/// Nama iklan CCU: "YSCCU_<ccuid>" atau "YCCU_<ccuid>". CCUID = 14 char terakhir.
public enum DeviceName {
    public static let prefixes = ["YSCCU_", "YCCU_"]
    public static func matches(_ name: String) -> Bool {
        prefixes.contains { name.hasPrefix($0) }
    }
    public static func ccuid(from name: String) -> String? {
        guard matches(name), name.count >= 14 else { return nil }
        return String(name.suffix(14))
    }
}

#if canImport(CoreBluetooth)
import CoreBluetooth

public enum ClientState: Equatable {
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
    func client(_ client: YConnectClient, didFailWith error: Error)
}

public extension YConnectClientDelegate {
    func client(_ client: YConnectClient, didReceiveVIN vin: String) {}
}

/// Client BLE read-only untuk Y-Connect / SCCU1.
///
/// KONTRAK KEAMANAN: satu-satunya byte yang pernah ditulis ke motor adalah frame
/// auth 0xAA. Tidak ada write lain. Frame time-sync 0xA6 TIDAK dikirim — capture
/// membuktikan CCU tetap streaming tanpanya (0x56 datang ~9 ms sebelum 0xA6 pertama).
public final class YConnectClient: NSObject {

    public weak var delegate: YConnectClientDelegate?

    /// Dipanggil utk SETIAP peripheral yang terlihat iOS (sebelum filter nama).
    /// (name, rssi, isMatch) — buat debugging "gagal ketemu CCU": kita bisa
    /// lihat apakah iOS nangkep iklan sama sekali, namanya beneran kaya apa,
    /// dan RSSI-nya. Kalau name == nil tapi isMatch nil, berarti iOS liat
    /// peripheral tanpa nama (biasanya filter-by-service itu yg nyasar).
    public var onDiscovery: ((String?, Int, Bool) -> Void)?

    private let credentials: Credentials
    private let decoder: TelemetryDecoder
    /// Bila auth pertama ditolak, coba sekali lagi dengan bondingFlag=1.
    public var allowBondingFallback: Bool = true

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?

    private var snapshot = TelemetrySnapshot()
    private var didTryBondingFallback = false
    private var authCounter: UInt8 = 0

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
        state = .scanning
        // Scan SEMUA peripheral, bukan filter service UUID. CCU Aerox ngiklanin
        // NAMA ("YSCCU_<ccuid>" / "YCCU_<ccuid>") — UUID service NUS tidak selalu
        // ikut di paket advertisement, jadi iOS filter-by-service bisa nyasar CCU.
        // Pemfilteran dilakukan lewat nama di didDiscover (DeviceName + CCUID).
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    public func stop() {
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil; txChar = nil; rxChar = nil
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
            state = .authenticating
            // withoutResponse: TX char SCCU1 pakai property Write No Response.
            p.writeValue(Data(frame), for: tx, type: .withoutResponse)
        } catch {
            delegate?.client(self, didFailWith: error)
            state = .failed("gagal bangun auth frame: \(error)")
        }
    }

    // MARK: - RX handling

    private func handleNotification(_ data: Data) {
        let raw = [UInt8](data)
        // Gerbang kebenaran: checksum wajib. Frame gagal checksum diabaikan.
        guard Checksum.verify(raw) else { return }

        // Balasan auth?
        if raw.first == 0x5A, let sp = StartProcessing(raw) {
            if sp.accepted {
                state = .streaming
            } else if allowBondingFallback && !didTryBondingFallback {
                didTryBondingFallback = true
                sendAuth(bonded: false)   // coba flag=1 sekali
            } else {
                state = .failed("auth ditolak CCU (flag=\(sp.flag))")
            }
            return
        }

        guard let frame = try? Frame(verifying: raw), let type = frame.type else { return }

        // VIN dari frame 0x5B record {f1,90}
        if type == .common, let vin = extractVIN(frame) {
            delegate?.client(self, didReceiveVIN: vin)
        }

        if let decoded = try? decoder.decode(frame), !decoded.isEmpty {
            snapshot.merge(decoded)
            delegate?.client(self, didUpdate: snapshot)
        }
    }

    private func extractVIN(_ frame: Frame) -> String? {
        guard let recs = try? frame.records() else { return nil }
        for r in recs where r.localID == (0xF1, 0x90) {
            let slice = Array(frame.bytes[r.dataStart..<(r.dataStart + r.length)])
            return String(bytes: slice, encoding: .ascii)
        }
        return nil
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
        central.connect(peripheral, options: nil)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: NUS.serviceString)])
    }

    public func centralManager(_ central: CBCentralManager,
                               didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state = .failed("gagal connect: \(error?.localizedDescription ?? "?")")
    }

    public func centralManager(_ central: CBCentralManager,
                               didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        txChar = nil; rxChar = nil
        state = .failed("terputus: \(error?.localizedDescription ?? "normal")")
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
        if txChar != nil && rxChar != nil {
            // iOS tidak punya API request MTU; nilai dinegosiasi otomatis.
            didTryBondingFallback = false
            sendAuth(bonded: credentials.bonded)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral,
                           didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == CBUUID(string: NUS.rxString),
              let data = characteristic.value else { return }
        handleNotification(data)
    }
}
#endif
