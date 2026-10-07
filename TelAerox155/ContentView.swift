import SwiftUI
import Combine
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var store = TelemetryStore()
    // Default "Penuh" — hasil uji lapangan paling stabil. Perangkat yang sudah
    // pernah menyimpan pilihan lain tidak ikut berubah (lihat TelemetryStore).
    @AppStorage("keepAlivePolicy") private var keepAlivePolicyRaw: String = KeepAlivePolicy.full.rawValue
    @State private var showPairing = false
    @State private var showRecordSheet = false
    @State private var showAuthCopiedToast = false
    @State private var displayTime = Date()
    // Tick tampilan saja: tidak mengirim frame atau mengubah ritme BLE.
    private let displayClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    // Kartu sensor yang di-tap → tampilkan penjelasan (SensorCatalog). key
    // di sini merujuk ke MetricValue.key / MappingItem.key yang sama dipakai
    // buat decode, bukan string bebas.
    @State private var selectedSensorKey: String?

    private let accent = Color(red: 0.20, green: 0.56, blue: 0.95)

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.04, green: 0.07, blue: 0.12),
                                    Color(red: 0.09, green: 0.13, blue: 0.20)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                    .padding(.horizontal)
                    .padding(.top, 8)

                if store.isActive {
                    metricsView
                } else {
                    idleView
                        .frame(maxHeight: .infinity)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            RecordingDock(recorder: store.recorder) { showRecordSheet = true }
        }
        .preferredColorScheme(.dark)
        .onReceive(displayClock) { displayTime = $0 }
        .alert("Kesalahan", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Terjadi kesalahan")
        }
        .sheet(isPresented: $showPairing) { PairingView(store: store) }
        .sheet(isPresented: $showRecordSheet) {
            RecordingView(store: store, recorder: store.recorder, library: store.recorder.library,
                          location: store.location, accent: accent)
        }
        .sheet(item: Binding(
            get: { selectedSensorKey.map(SensorSheetItem.init) },
            set: { selectedSensorKey = $0?.key }
        )) { item in
            SensorInfoSheet(key: item.key, accent: accent)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("TelAerox")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Aerox 155 — Telemetri BLE")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button { showPairing = true } label: {
                    Image(systemName: "qrcode").font(.title3)
                }
                .accessibilityLabel("Pairing Motor")
                .frame(width: 44, height: 44)
                .disabled(store.isActive || store.isConnecting)
            }

            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                connectButton
            }
        }
    }

    /// Sebelumnya: tombol cuma tahu Hubungkan/Putuskan, dan di-DISABLE selama
    /// scanning/connecting/authenticating — jadi kalau nyangkut di tengah
    /// (mis. auth diem sebelum watchdog kepicu) tidak ada cara membatalkan
    /// selain kill app. Sekarang tombol jadi "Batalkan" di fase itu.
    private var connectButton: some View {
        let label: String
        let icon: String
        if store.isActive {
            label = "Putuskan"; icon = "stop.circle.fill"
        } else if store.isConnecting {
            label = "Batalkan"; icon = "xmark.circle.fill"
        } else {
            label = store.hasPairing ? "Hubungkan" : "Pairing"; icon = "bolt.fill"
        }
        return Button {
            if store.isActive || store.isConnecting {
                store.disconnect()
            } else if store.hasPairing {
                store.connect()
            } else {
                showPairing = true
            }
        } label: {
            Label(label, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: [accent, accent.opacity(0.7)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                    )
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Metrics

    private var metricsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                bigRpmCard
                if homeTelemetry.missingPrimaryData { liveDataNotice }

                LazyVGrid(columns: metricColumns, spacing: 12) {
                    metricCard(coolantMetric)
                    metricCard(batteryMetric)
                    metricCard(odometerMetric)
                    metricCard(throttleMetric)
                }
                diagnosticSummary

                technicalPanel("Sensor & diagnostik") {
                    LazyVGrid(columns: metricColumns, spacing: 12) {
                        metricCard(intakeMetric)
                        metricCard(baroMetric)
                        metricCard(injectionMetric)
                        metricCard(fiMetric)
                        metricCard(dtcMetric)
                        metricCard(fiLampMetric)
                        metricCard(fuelMetric)
                    }
                }
                technicalPanel("Info kendaraan") {
                    vehicleIdentity
                    extraInfoSection
                }
                connectionDetails
            }
            .padding(.top, 18)
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
    }

    private var metricColumns: [GridItem] {
        [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]
    }

    private var homeTelemetry: HomeTelemetry {
        HomeTelemetry(snapshot: store.snapshot, isStreaming: store.isActive, now: displayTime)
    }

    private func liveValue(_ key: String) -> Double? { homeTelemetry.value(key) }

    private func technicalPanel<Content: View>(_ title: String, @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12, content: content)
                .padding(.top, 12)
        } label: {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
        }
        .tint(accent)
        .padding(16)
        .background(.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
    }

    private var liveDataNotice: some View {
        Label("Menunggu pembaruan kecepatan / RPM", systemImage: "clock.badge.exclamationmark")
            .font(.caption)
            .foregroundStyle(homeTelemetry.missingPrimaryData ? Color.orange : Color.secondary)
    }

    private var diagnosticSummary: some View {
        let telemetry = homeTelemetry
        return Label {
            Text(telemetry.hasDiagnosticWarning
                 ? "Peringatan motor · cek Sensor & diagnostik"
                 : (telemetry.hasCompleteDiagnostics
                    ? "FI / DTC · tidak ada kode error terbaca"
                    : "FI / DTC · menunggu data"))
        } icon: {
            Image(systemName: telemetry.hasDiagnosticWarning ? "exclamationmark.triangle.fill" : "info.circle")
        }
        .font(.caption)
        .foregroundStyle(telemetry.hasDiagnosticWarning ? Color.orange : Color.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var vehicleIdentity: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let model = store.modelCode { Text("Model: \(model)") }
            if let vin = store.vin { Text("VIN: \(vin)").textSelection(.enabled) }
            Text("Identitas kendaraan bersifat pribadi. Counter di bawah adalah nilai terakhir yang diterima dalam sesi ini.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .font(.subheadline.monospaced())
    }

    private var connectionDetails: some View {
        technicalPanel("Koneksi & pengaturan lanjutan") {
            Text("Keep-alive").font(.subheadline.weight(.semibold))
            keepAlivePicker
            if store.state == .scanning || !store.discovered.isEmpty {
                discoveryDebugList
            }
            if !store.authTrace.isEmpty { authTraceDebugList }
            Text("Log koneksi dapat memuat identitas perangkat. Periksa sebelum menyalin atau membagikannya.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var bigRpmCard: some View {
        let rpm = liveValue("rpm")
        let speed = liveValue("speed")
        return VStack(spacing: 18) {
            Button { selectedSensorKey = "speed" } label: {
                VStack(spacing: 0) {
                    Text("KECEPATAN").font(.caption.weight(.semibold)).tracking(2)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(speed.map { String(format: "%.0f", $0) } ?? "--")
                            .font(.system(size: 80, weight: .bold, design: .rounded).monospacedDigit())
                            .foregroundStyle(.white)
                            .lineLimit(1).minimumScaleFactor(0.6)
                        Text("km/h").font(.headline).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            Button { selectedSensorKey = "rpm" } label: {
                VStack(spacing: 8) {
                    HStack {
                        Text("PUTARAN MESIN").font(.caption.weight(.semibold)).tracking(1)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(rpm.map { String(format: "%.0f rpm", $0) } ?? "-- rpm")
                            .font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(.white)
                    }
                    ProgressView(value: min(max(rpm ?? 0, 0), 12000), total: 12000)
                        .tint(accent)
                        .accessibilityLabel("Putaran mesin")
                }
                .padding(.vertical, 4)
            }
            .buttonStyle(.plain)
        }
        .padding(20)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
    }

    /// Kalau `m.key` ada di `SensorCatalog`, kartu bisa di-tap untuk lihat
    /// penjelasan sensor (apa yang diukur, sumber frame/ID, kredibilitas, dan
    /// catatan tambahan — mis. kenapa tegangan aki bisa sedikit beda dari
    /// dashboard fisik). Kartu tanpa entri katalog (belum didokumentasikan)
    /// tetap tampil normal, cuma tidak interaktif.
    private func metricCard(_ m: MetricValue, corner: CGFloat = 18) -> some View {
        let content = VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: m.icon)
                    .font(.caption)
                    .foregroundStyle(m.color)
                Text(m.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if m.key != nil, SensorCatalog.info(for: m.key!) != nil {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.35))
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(m.valueText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(m.color)
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
                if !m.unit.isEmpty {
                    Text(m.unit)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: corner))
        .animation(.snappy, value: m.valueText)

        return Group {
            if let key = m.key, SensorCatalog.info(for: key) != nil {
                Button { selectedSensorKey = key } label: { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
    }

    private var batteryMetric: MetricValue {
        guard let v = liveValue("battery") else {
            return metric("battery", icon: "battery.75", title: "Tegangan Aki", decimals: 1)
        }
        let color: Color = v < 11 ? .red : (v < 12 ? .orange : .green)
        return metric("battery", icon: "battery.75", title: "Tegangan Aki",
                      decimals: 1, color: color)
    }

    private var coolantMetric: MetricValue {
        metric("coolant", icon: "thermometer.medium", title: "Suhu Mesin", decimals: 0)
    }

    private var intakeMetric: MetricValue {
        metric("intake", icon: "wind", title: "Suhu Udara", decimals: 0)
    }

    private var throttleMetric: MetricValue {
        metric("throttle", icon: "gauge.medium", title: "Bukaan Gas", decimals: 0)
    }
    // Catatan: unit field ini "°" (derajat throttle body), bukan persen —
    // lihat komentar di Mapping.swift (mapping-overrides.json menyatakan "deg").

    private var baroMetric: MetricValue {
        metric("baro", icon: "barometer", title: "Tekanan Udara", decimals: 1)
    }

    private var fiMetric: MetricValue {
        guard let n = liveValue("fiError") else {
            return metric("fiError", icon: "questionmark.circle", title: "Error FI", decimals: 0)
        }
        return metric("fiError", icon: n > 0 ? "exclamationmark.triangle" : "checkmark.circle", title: "Error FI",
                      decimals: 0, color: n > 0 ? .red : .green)
    }

    private var dtcMetric: MetricValue {
        guard let value = liveValue("dtc"), value != 0 else {
            return metric("dtc", icon: "wrench.and.screwdriver", title: "Kode DTC",
                          decimals: 0, color: .green)
        }
        return metric("dtc", icon: "wrench.and.screwdriver", title: "Kode DTC",
                      decimals: 0, color: .red)
    }

    private var odometerMetric: MetricValue {
        metric("odometer", icon: "road.lanes", title: "Jarak Tempuh", decimals: 1)
    }

    private var fiLampMetric: MetricValue {
        guard let n = liveValue("fiWarningLamp") else {
            return metric("fiWarningLamp", icon: "lightbulb", title: "Lampu FI", decimals: 0)
        }
        let color: Color = n > 0 ? .red : .green
        return metric("fiWarningLamp", icon: n > 0 ? "lightbulb.fill" : "lightbulb",
                      title: "Lampu FI", decimals: 0, color: color)
    }

    private var injectionMetric: MetricValue {
        metric("injection", icon: "drop.fill", title: "Jumlah Injeksi", decimals: 2)
    }

    /// Field frame 0x5B (`ecuPowerOnTime`, `ignOnCount`) kredibilitasnya TINGGI:
    /// selain struktur ByteNo tervalidasi ke capture nyata, faktor/offset kini
    /// juga tercross-check ke sumber independen kedua (dua log lapangan berjarak
    /// beberapa menit, nilai naik konsisten dengan selisih wall-clock).
    /// Lihat docs/research/02-mapping-reanalysis.md §3.
    private var extraInfoSection: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                metricCard(ecuPowerOnMetric, corner: 18)
                metricCard(ignOnCountMetric, corner: 18)
            }
        }
    }

    private var ecuPowerOnMetric: MetricValue {
        guard let value = liveValue("ecuPowerOnTime") else {
            return MetricValue(key: "ecuPowerOnTime", icon: "power", title: "ECU Total Nyala",
                               valueText: "--", unit: "", color: .secondary)
        }
        let hari = value / 86_400
        return MetricValue(key: "ecuPowerOnTime", icon: "power", title: "ECU Total Nyala",
                           valueText: String(format: "%.1f", hari), unit: "hari", color: .white)
    }

    /// Placeholder — BELUM ada mapping BBM yang terverifikasi (lihat
    /// SensorCatalog untuk penjelasan lengkap kenapa). Sengaja tetap
    /// ditampilkan (bukan disembunyikan) supaya transparan ke user bahwa ini
    /// gap riset yang diketahui, bukan bug/lupa.
    private var fuelMetric: MetricValue {
        MetricValue(key: "fuel", icon: "fuelpump", title: "Sisa BBM",
                   valueText: "--", unit: "", color: .secondary)
    }

    private var ignOnCountMetric: MetricValue {
        metric("ignOnCount", icon: "key.fill", title: "Total IGN ON", decimals: 0)
    }

    private func metric(_ key: String, icon: String, title: String,
                        decimals: Int, color: Color = .white) -> MetricValue {
        guard let value = liveValue(key), let d = store.snapshot.decoded(key) else {
            return MetricValue(key: key, icon: icon, title: title, valueText: "--",
                               unit: "", color: .secondary)
        }
        return MetricValue(key: key, icon: icon, title: title,
                           valueText: String(format: "%.\(decimals)f", value),
                           unit: d.unit, color: color)
    }

    // MARK: - Idle state

    /// Debug "gagal nemu CCU": daftar perangkat yang kebaca iOS pas scanning —
    /// nama adv asli + RSSI + tanda ✓ kalau namanya cocok CCUID kita. Kalau list
    /// ini kosong pas di motor (mesin nyala), berarti iOS nggak liat iklan sama
    /// sekali (masalah di bluetooth/izin/posisi motor), bukan di app.
    private var discoveryDebugList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Perangkat terlihat (\(store.discovered.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            if store.discovered.isEmpty {
                Text("Belum ada — tunggu iklan CCU (nama YSCCU_/YCCU_ pakai CCUID).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 4) {
                    ForEach(store.discovered) { d in
                        HStack(spacing: 8) {
                            Image(systemName: d.isMatch ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(d.isMatch ? .green : .secondary)
                                .font(.caption)
                            Text(d.displayName)
                                .font(.caption.monospaced())
                                .lineLimit(2)
                                .foregroundStyle(.white)
                            Spacer()
                            Text(d.isMatch ? "✓ CCU" : "")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                            Text("\(d.rssi) dBm")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 3)
                        .padding(.horizontal, 8)
                        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
        .padding(10)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Trace tahap auth (0xAA bonded → balas 0x5A StartProcessing / bonding
    /// fallback / watchdog timeout). Biar pas di motor keliatan nyangkut di
    /// langkah mana — bukan cuma "connect sukses tapi beberapa detik kemudian
    /// timeout" yang misterius.
    private var authTraceDebugList: some View {
        VStack(spacing: 8) {
            HStack {
                Text("Tahap auth (\(store.authTrace.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Button {
                    #if canImport(UIKit)
                    UIPasteboard.general.string = store.authTrace.enumerated()
                        .map { "\($0.offset + 1). \($0.element)" }
                        .joined(separator: "\n")
                    #endif
                    showAuthCopiedToast = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                        showAuthCopiedToast = false
                    }
                } label: {
                    Label(showAuthCopiedToast ? "Tersalin!" : "Salin", systemImage: "doc.on.doc")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(accent)
                }
                .buttonStyle(.plain)
            }
            ForEach(store.authTrace.indices, id: \.self) { i in
                HStack(alignment: .top, spacing: 6) {
                    Text("\(i + 1)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(store.authTrace[i])
                        .font(.caption2.monospaced())
                        .fixedSize(horizontal: false, vertical: true)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    /// Keep-alive 0xA6: app resmi Yamaha mengirim frame ini tiap 1 detik selama
    /// sesi hidup; sebelumnya app ini diam total setelah auth — kemungkinan
    /// besar itu penyebab "connect sukses tapi timeout beberapa detik kemudian".
    /// Default "Penuh" — hasil uji lapangan paling stabil (lihat TelemetryStore).
    private var keepAlivePicker: some View {
        let policy = Binding<KeepAlivePolicy>(
            get: { KeepAlivePolicy(rawValue: keepAlivePolicyRaw) ?? .full },
            set: { keepAlivePolicyRaw = $0.rawValue }
        )
        return VStack(spacing: 6) {
            Picker("Keep-alive 0xA6", selection: policy) {
                Text("Mati").tag(KeepAlivePolicy.off)
                Text("Notifikasi saja").tag(KeepAlivePolicy.notifyOnly)
                Text("Penuh").tag(KeepAlivePolicy.full)
            }
            .pickerStyle(.segmented)
            .disabled(store.isActive || store.isConnecting)

            Text(keepAlivePolicyHint(policy.wrappedValue))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func keepAlivePolicyHint(_ policy: KeepAlivePolicy) -> String {
        switch policy {
        case .off: return "Tidak kirim apa-apa setelah auth (perilaku lama)."
        case .notifyOnly: return "Kirim frame \"tidak ada notifikasi\" tiap detik — nol efek samping ke motor."
        case .full: return "Sama seperti app resmi — juga ikut men-set jam di dashboard motor. Paling stabil pada uji lapangan."
        }
    }

    /// Dibungkus ScrollView: panel "Tahap auth" bisa berisi puluhan baris
    /// (retry berulang menumpuk dalam satu sesi idle) — tanpa scroll, konten
    /// mendorong header ("TelAerox" + status bar) keluar layar sepenuhnya.
    private var idleView: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 14) {
                    Image(systemName: store.isConnecting ? "antenna.radiowaves.left.and.right" : "motorcycle")
                        .font(.system(size: 48))
                        .foregroundStyle(accent)
                    if store.isConnecting { ProgressView().tint(accent) }
                    Text(store.isConnecting ? statusText : (store.hasPairing ? "Siap terhubung" : "Pasangkan motor dulu"))
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                    Text(store.isConnecting
                         ? "Dekatkan iPhone ke motor."
                         : (store.hasPairing
                            ? "Nyalakan kontak motor, lalu tekan Hubungkan."
                            : "Pindai QR motor untuk mulai terhubung."))
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 24))

                connectionDetails
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity)
            .padding(.top, 24)
            .padding(.bottom, 40)
        }
    }

    // MARK: - Helpers

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } })
    }

    private var statusText: String {
        switch store.state {
        case .poweredOff: return "Belum terhubung"
        case .scanning: return "Mencari CCU…"
        case .connecting: return "Menghubungkan…"
        case .authenticating: return "Otentikasi…"
        case .streaming: return "Streaming telemetri"
        case .failed(let msg): return "Gagal — \(msg)"
        }
    }

    private var statusColor: Color {
        switch store.state {
        case .streaming: return .green
        case .failed: return .red
        case .scanning, .connecting, .authenticating: return .orange
        case .poweredOff: return .gray
        }
    }
}

/// Wrapper `Identifiable` supaya `URL` (yang bukan Identifiable) bisa dipakai
/// dengan `.sheet(item:)`.
struct ShareItem: Identifiable {
    let url: URL
    var id: URL { url }
}

#if canImport(UIKit)
/// Bungkus tipis `UIActivityViewController` — SwiftUI `ShareLink` tidak
/// menyediakan cara mendeteksi kapan share sheet ditutup dari sisi kita, jadi
/// pakai UIKit langsung supaya presentasinya konsisten dengan `.sheet(item:)`
/// yang sudah dipakai di tempat lain pada view ini.
struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

struct MetricValue: Identifiable {
    let id = UUID()
    /// Kunci ke `SensorCatalog` (biasanya sama dengan `MappingItem.key`) — kalau
    /// nil, kartu tidak bisa di-tap (dipakai buat kartu tanpa entri katalog).
    let key: String?
    let icon: String
    let title: String
    let valueText: String
    let unit: String
    var color: Color = .white
}

#Preview {
    ContentView()
}
