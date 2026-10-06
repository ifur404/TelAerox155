import SwiftUI
import VisionKit
import Vision
import AVFoundation

struct PairingView: View {
    @ObservedObject var store: TelemetryStore
    @StateObject private var discovery = PairingDiscovery()
    @Environment(\.dismiss) private var dismiss
    @State private var selected: NearbyPairingDevice?
    @State private var qr = ""
    @State private var error: String?
    @State private var scanning = false
    @State private var torchOn = false
    @State private var manualQR = false
    @State private var confirmForget = false

    private var isTrying: Bool { store.pairingAttempt == .connecting }
    private var isPaired: Bool { store.pairingAttempt == .paired }

    var body: some View {
        NavigationStack {
            Form {
                if isPaired {
                    Section {
                        Label("Motor berhasil dipairing", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Autentikasi diterima motor dan data pairing sudah tersimpan. Berikutnya tinggal Hubungkan.")
                        Button("Lihat telemetri") { dismiss() }
                    }
                } else if let selected {
                    Section("1 · Motor dipilih") {
                        Label(selected.name, systemImage: "motorcycle")
                        Button("Pilih motor lain") {
                            self.selected = nil
                            qr = ""
                            error = nil
                            store.resetPairingAttempt()
                            discovery.start()
                        }.disabled(isTrying)
                    }
                    Section("2 · Verifikasi motor") {
                            Text("Scan QR Y-Connect milik motor yang dipilih.")
                            Button("Scan QR", systemImage: "qrcode.viewfinder") {
                                Task { await openCamera() }
                            }
                            SecureField("Atau tempel isi QR", text: $qr)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                            if !qr.isEmpty { Label("QR siap diperiksa", systemImage: "qrcode") }

                    }.disabled(isTrying)
                    Section("3 · Hubungkan") {
                        if isTrying {
                            ProgressView("Menunggu autentikasi motor…")
                            Button("Batalkan", role: .cancel) { store.cancelPairing() }
                        } else {
                            Button("Coba hubungkan") { tryConnect(selected) }
                                .disabled(qr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        Text("Motor baru ditandai paired setelah menerima autentikasi. Jika gagal, data pairing baru tidak disimpan.")
                            .font(.footnote)
                    }
                } else {
                    Section("1 · Pilih Bluetooth motor") {
                        Text(discovery.message).font(.footnote)
                        if discovery.isScanning { ProgressView("Mencari…") }
                        ForEach(discovery.devices.sorted {
                            if ($0.ccuid != nil) != ($1.ccuid != nil) { return $0.ccuid != nil }
                            return $0.name < $1.name
                        }) { device in
                            Button {
                                selected = device
                                discovery.stop()
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                    Text(device.ccuid == nil ? "Bukan CCU Yamaha yang didukung" : "Sinyal \(device.rssi) dBm")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }.disabled(device.ccuid == nil)
                        }
                        Button(discovery.isScanning ? "Hentikan pencarian" : "Cari lagi") {
                            if discovery.isScanning { discovery.stop() } else { discovery.start() }
                        }
                    }
                    if store.hasPairing {
                        Section {
                            Text("Pairing lama tetap tersimpan sampai motor baru berhasil diautentikasi.")
                                .font(.footnote)
                            Button("Lupakan motor tersimpan", role: .destructive) { confirmForget = true }
                        }
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if case .failed(let message) = store.pairingAttempt {
                    Section("Pairing belum berhasil") { Text(message).foregroundStyle(.red) }
                }
            }
            .navigationTitle("Pairing Motor")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Tutup") { store.cancelPairing(); dismiss() }
            } }
            .confirmationDialog("Hapus data pairing motor dari iPhone ini?", isPresented: $confirmForget, titleVisibility: .visible) {
                Button("Lupakan motor", role: .destructive) {
                    do { try store.forgetPairing() } catch { self.error = error.localizedDescription }
                }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner { payload in
                        qr = payload
                        scanning = false
                        error = nil
                    } onError: {
                        scanning = false
                        error = "Kamera tidak tersedia. Coba lagi atau tempel isi QR."
                    }
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan QR Motor")
                    .safeAreaInset(edge: .bottom) {
                        VStack(spacing: 12) {
                            Button(torchOn ? "Matikan flash" : "Nyalakan flash", systemImage: torchOn ? "flashlight.on.fill" : "flashlight.off.fill") { toggleTorch() }
                            Button("Input / tempel isi QR", systemImage: "keyboard") { manualQR = true }
                        }.padding().frame(maxWidth: .infinity).background(.ultraThinMaterial)
                    }
                    .onDisappear { setTorch(false) }
                    .sheet(isPresented: $manualQR) {
                        NavigationStack {
                            Form {
                                Section("Isi QR Y-Connect") {
                                    SecureField("Tempel atau ketik isi QR", text: $qr)
                                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                                    Text("Masukkan seluruh isi QR, bukan nomor rangka.").font(.footnote)
                                }
                            }
                            .navigationTitle("Input QR")
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) {
                                    Button("Gunakan QR") { manualQR = false; scanning = false; error = nil }
                                        .disabled(qr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                                }
                                ToolbarItem(placement: .cancellationAction) { Button("Batal") { manualQR = false } }
                            }
                        }
                    }

                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Batal") { scanning = false } } }
                }
            }
            .onAppear {
                if selected == nil {
                    store.resetPairingAttempt()
                    discovery.start()
                }
            }
            .onDisappear {
                discovery.stop()
                store.cancelPairing()
            }
            .interactiveDismissDisabled(isTrying)
        }
    }

    private func toggleTorch() { setTorch(!torchOn) }
    private func setTorch(_ enabled: Bool) {
        guard let device = AVCaptureDevice.default(for: .video), device.hasTorch else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.torchMode = enabled ? .on : .off
            torchOn = enabled
        } catch { self.error = "Flash tidak tersedia saat ini." }
    }

    private func tryConnect(_ device: NearbyPairingDevice) {
        error = nil
        do {
            guard let ccuid = device.ccuid else { throw PairingError.wrongMotorcycle }
            let credentials = try PairingDecoder.decode(qr, matching: ccuid)
            discovery.stop()
            try store.beginPairing(credentials, device: device)
        } catch { self.error = error.localizedDescription }
    }
    private func openCamera() async {
        guard DataScannerViewController.isSupported else {
            error = "Scanner tidak didukung pada perangkat ini. Tempel isi QR."
            return
        }
        let allowed = await AVCaptureDevice.requestAccess(for: .video)
        guard allowed, DataScannerViewController.isAvailable else {
            error = "Izinkan akses kamera di Pengaturan iPhone untuk memindai QR."
            return
        }
        scanning = true
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    let onRead: (String) -> Void
    let onError: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                recognizesMultipleItems: false, isGuidanceEnabled: true,
                                                isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        do { try scanner.startScanning() } catch { Task { @MainActor in onError() } }
        return scanner
    }
    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}
    static func dismantleUIViewController(_ uiViewController: DataScannerViewController, coordinator: Coordinator) {
        uiViewController.stopScanning()
    }
    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let parent: QRScanner
        var finished = false
        init(parent: QRScanner) { self.parent = parent }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            guard !finished else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let payload = barcode.payloadStringValue {
                    finished = true
                    dataScanner.stopScanning()
                    parent.onRead(payload)
                    return
                }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            guard !finished else { return }
            finished = true
            parent.onError()
        }
    }
}
