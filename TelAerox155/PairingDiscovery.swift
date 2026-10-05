import Foundation
import Combine
import CoreBluetooth

struct NearbyPairingDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let rssi: Int
    let ccuid: String?
}

/// Scan saja: memilih perangkat tidak membuka koneksi atau menulis ke motor.
/// Delegate selalu di main queue, sama dengan TelemetryStore.
@MainActor
final class PairingDiscovery: NSObject, ObservableObject, CBCentralManagerDelegate {
    @Published private(set) var devices: [NearbyPairingDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var message = "Nyalakan kontak motor dan dekatkan iPhone."
    private var central: CBCentralManager?
    private var requested = false
    private var timeout: Task<Void, Never>?

    func start() {
        stop()
        devices = []
        requested = true
        if let central { beginIfReady(central) }
        else { central = CBCentralManager(delegate: self, queue: nil) }
    }
    func stop() {
        requested = false
        central?.stopScan()
        isScanning = false
        timeout?.cancel()
        timeout = nil
    }
    private func beginIfReady(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            guard requested else { return }
            central.scanForPeripherals(withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            isScanning = true
            message = "Mencari Bluetooth sekitar… Pilih motor Yamaha yang sesuai."
            timeout?.cancel()
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled, let self else { return }
                self.stop()
                self.message = "Pencarian selesai. Jika motor belum terlihat, nyalakan kontak lalu cari lagi."
            }
        case .unauthorized: message = "Izinkan Bluetooth untuk TelAerox di Pengaturan iPhone."
        case .poweredOff: message = "Nyalakan Bluetooth di Pengaturan iPhone."
        case .unsupported: message = "Bluetooth tidak didukung pada perangkat ini."
        default: message = "Menunggu Bluetooth siap…"
        }
    }
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state != .poweredOn { isScanning = false }
        beginIfReady(central)
    }
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard requested else { return }
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name ?? "Perangkat tanpa nama"
        let ccuid = DeviceName.ccuid(from: name)
        let device = NearbyPairingDevice(id: peripheral.identifier, name: name,
                                        rssi: RSSI.intValue, ccuid: ccuid)
        if let index = devices.firstIndex(where: { $0.id == device.id }) { devices[index] = device }
        else if devices.count < 100 { devices.append(device) }
    }
}
