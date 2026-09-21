import Foundation
import Combine

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

@MainActor
final class TelemetryStore: NSObject, ObservableObject, YConnectClientDelegate {

    @Published var state: ClientState = .poweredOff
    @Published var snapshot = TelemetrySnapshot()
    @Published var vin: String?
    @Published var errorMessage: String?

    /// Kumpulan yang barusan kebaca, flat buat SwiftUI. Resize paling akhir aja.
    @Published private(set) var discovered: [DiscoveredDevice] = []

    private var client: YConnectClient?

    var isActive: Bool {
        switch state {
        case .streaming: return true
        default: return false
        }
    }

    func connect() {
        guard client == nil else { return }
        errorMessage = nil
        do {
            guard let url = Bundle.main.url(forResource: "secrets.local", withExtension: "json") else {
                errorMessage = "secrets.local.json tidak ditemukan di bundle"
                return
            }
            let cred = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: url))
            let c = YConnectClient(credentials: cred)
            c.onDiscovery = { [weak self] name, rssi, isMatch in
                Task { @MainActor in
                    self?.addDiscovery(name: name, rssi: rssi, isMatch: isMatch)
                }
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

    func disconnect() {
        client?.stop()
        client = nil
        state = .poweredOff
        snapshot = TelemetrySnapshot()
        vin = nil
    }

    // MARK: - YConnectClientDelegate

    func client(_ client: YConnectClient, didChangeState state: ClientState) {
        self.state = state
    }

    func client(_ client: YConnectClient, didUpdate snapshot: TelemetrySnapshot) {
        self.snapshot = snapshot
    }

    func client(_ client: YConnectClient, didReceiveVIN vin: String) {
        self.vin = vin
    }

    func client(_ client: YConnectClient, didFailWith error: Error) {
        errorMessage = error.localizedDescription
    }
}