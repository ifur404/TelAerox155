import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var store = TelemetryStore()
    @AppStorage("keepAlivePolicy") private var keepAlivePolicyRaw: String = KeepAlivePolicy.notifyOnly.rawValue
    @State private var showLogExporter = false
    @State private var showCopiedToast = false
    @State private var showLogSheet = false
    // Di-set SEKALI saat tombol "Simpan" ditekan, bukan dibaca ulang tiap body
    // dievaluasi (snapshot telemetri berubah ~20 Hz saat streaming — building
    // ulang string log yang bisa ribuan baris tiap frame itu boros).
    @State private var logSnapshotForExport = ""

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
        .preferredColorScheme(.dark)
        .alert("Kesalahan", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Terjadi kesalahan")
        }
        .sheet(isPresented: $showLogSheet) { logSheet }
        .fileExporter(isPresented: $showLogExporter,
                      document: LogDocument(text: logSnapshotForExport),
                      contentType: .plainText,
                      defaultFilename: logFileName) { _ in }
    }

    /// "log_2026-09-22_20-14-05.txt" — cukup unik + gampang dibaca kalau
    /// beberapa kali export dalam satu sesi ujicoba di motor.
    private var logFileName: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "telaerox-log_\(f.string(from: Date()))"
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
                logButton
                connectButton
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                if let vin = store.vin {
                    Text("VIN \(vin)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    /// Tombol log diagnostik — selalu ada di header (idle ATAU streaming),
    /// karena mau lihat log paling sering justru PAS/SEHABIS gagal, bukan cuma
    /// saat idle. Badge titik oranye muncul kalau ada baris terkumpul.
    private var logButton: some View {
        Button { showLogSheet = true } label: {
            ZStack(alignment: .topTrailing) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.08), in: Circle())
                if store.logLineCount > 0 {
                    Circle().fill(accent).frame(width: 7, height: 7)
                }
            }
        }
        .buttonStyle(.plain)
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
            label = "Hubungkan"; icon = "bolt.fill"
        }
        return Button {
            (store.isActive || store.isConnecting) ? store.disconnect() : store.connect()
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
            VStack(spacing: 14) {
                bigRpmCard

                HStack(spacing: 14) {
                    metricCard(speedMetric, corner: 20)
                    metricCard(batteryMetric, corner: 20)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                    GridItem(.flexible(), spacing: 14)], spacing: 14) {
                    metricCard(coolantMetric)
                    metricCard(intakeMetric)
                    metricCard(throttleMetric)
                    metricCard(baroMetric)
                    metricCard(fiMetric)
                    metricCard(dtcMetric)
                }

                metricCard(odometerMetric)
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
        .frame(maxHeight: .infinity)
    }

    private var bigRpmCard: some View {
        let rpm = store.snapshot.rpm
        let value = rpm.map { String(format: "%.0f", $0) } ?? "--"
        return ZStack {
            RoundedRectangle(cornerRadius: 24)
                .fill(LinearGradient(colors: [accent.opacity(0.35), accent.opacity(0.12)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Putaran Mesin", systemImage: "gauge.high")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(value)
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                        Text("rpm")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                speedRing
            }
            .padding(22)
        }
        .frame(height: 150)
        .animation(.snappy, value: store.snapshot.rpm)
    }

    private var speedRing: some View {
        let speed = store.snapshot.speed ?? 0
        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 8)
            Circle()
                .trim(from: 0, to: min(speed / 140, 1))
                .stroke(accent, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(String(format: "%.0f", speed))
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("km/h")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: 84, height: 84)
        .animation(.snappy, value: speed)
    }

    private func metricCard(_ m: MetricValue, corner: CGFloat = 18) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: m.icon)
                    .font(.caption)
                    .foregroundStyle(m.color)
                Text(m.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(m.valueText)
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(m.color)
                    .contentTransition(.numericText())
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
    }

    private var speedMetric: MetricValue {
        metric("speed", icon: "speedometer", title: "Kecepatan", decimals: 0)
    }

    private var batteryMetric: MetricValue {
        guard let v = store.snapshot.battery else {
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
        guard let n = store.snapshot.value("fiError"), n > 0 else {
            return metric("fiError", icon: "checkmark.circle", title: "Error FI",
                          decimals: 0, color: .green)
        }
        return metric("fiError", icon: "exclamationmark.triangle", title: "Error FI",
                      decimals: 0, color: .red)
    }

    private var dtcMetric: MetricValue {
        guard let d = store.snapshot.decoded("dtc"), d.value != 0 else {
            return metric("dtc", icon: "wrench.and.screwdriver", title: "Kode DTC",
                          decimals: 0, color: .green)
        }
        return metric("dtc", icon: "wrench.and.screwdriver", title: "Kode DTC",
                      decimals: 0, color: .red)
    }

    private var odometerMetric: MetricValue {
        metric("odometer", icon: "road.lanes", title: "Jarak Tempuh", decimals: 1)
    }

    private func metric(_ key: String, icon: String, title: String,
                        decimals: Int, color: Color = .white) -> MetricValue {
        guard let d = store.snapshot.decoded(key) else {
            return MetricValue(icon: icon, title: title, valueText: "--",
                               unit: "", color: .secondary)
        }
        return MetricValue(icon: icon, title: title,
                           valueText: String(format: "%.\(decimals)f", d.value),
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
                                .lineLimit(1)
                                .truncationMode(.middle)
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
        .padding(.horizontal, 32)
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
            }
            ForEach(store.authTrace.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    Text("\(i + 1)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                    Text(store.authTrace[i])
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .foregroundStyle(.white)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(10)
        .background(.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 32)
    }

    /// Keep-alive 0xA6: app resmi Yamaha mengirim frame ini tiap 1 detik selama
    /// sesi hidup; sebelumnya app ini diam total setelah auth — kemungkinan
    /// besar itu penyebab "connect sukses tapi timeout beberapa detik kemudian".
    /// Default "Notifikasi saja" nol efek samping ke motor.
    private var keepAlivePicker: some View {
        let policy = Binding<KeepAlivePolicy>(
            get: { KeepAlivePolicy(rawValue: keepAlivePolicyRaw) ?? .notifyOnly },
            set: { keepAlivePolicyRaw = $0.rawValue }
        )
        return VStack(spacing: 6) {
            Picker("Keep-alive 0xA6", selection: policy) {
                Text("Mati").tag(KeepAlivePolicy.off)
                Text("Notifikasi saja").tag(KeepAlivePolicy.notifyOnly)
                Text("Penuh").tag(KeepAlivePolicy.full)
            }
            .pickerStyle(.segmented)
            .disabled(store.isActive || store.state == .connecting || store.state == .authenticating)

            Text(keepAlivePolicyHint(policy.wrappedValue))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 32)
    }

    private func keepAlivePolicyHint(_ policy: KeepAlivePolicy) -> String {
        switch policy {
        case .off: return "Tidak kirim apa-apa setelah auth (perilaku lama)."
        case .notifyOnly: return "Kirim frame \"tidak ada notifikasi\" tiap detik — nol efek samping ke motor."
        case .full: return "Sama seperti app resmi — juga ikut men-set jam di dashboard motor."
        }
    }

    private var idleView: some View {
        VStack(spacing: 14) {
            Image(systemName: "bicycle")
                .font(.system(size: 56))
                .foregroundStyle(accent.opacity(0.7))
            Text("Belum terhubung")
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
            Text("Nyalakan mesin / kontak Aerox, lalu tekan Hubungkan.\nAplikasi menampilkan telemetri langsung dari CCU via Bluetooth.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 32)

            keepAlivePicker

            if store.state == .scanning {
                discoveryDebugList
            }
            // Auth trace: muncul pas idle (connecting → authenticating → failed/
            // terputus). Jadi kalau pas di motor "berhasil connect tapi timeout
            // beberapa detik kemudian", di sini kelihatan auth-nya nyangkut di
            // langkah mana (kirim 0xAA bonded=? → terima/tidak 0x5A → fallback
            // bonding → watchdog timeout) — bukan tebak-tebakan lagi.
            if !store.authTrace.isEmpty {
                authTraceDebugList
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
    }

    // MARK: - Log diagnostik

    /// Isi lengkap: semua frame TX/RX mentah (hex, kredensial disensor) +
    /// narasi tahap koneksi, dari sejak app dibuka — bukan cuma sesi terakhir.
    /// Ini yang dibagikan kalau connect "berhasil tapi timeout" biar bisa
    /// dianalisa persis nyangkut di byte/detik yang mana.
    private var logSheet: some View {
        NavigationStack {
            VStack(spacing: 20) {
                VStack(spacing: 6) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 40))
                        .foregroundStyle(accent)
                    Text("\(store.logLineCount) baris terkumpul")
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text("Rekaman semua frame BLE (TX/RX mentah) + tahap koneksi sejak app dibuka. Kredensial (ccuid/passKey/phoneUUID) dan VIN otomatis disensor — aman dibagikan/dikirim buat dianalisa.")
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 24)
                }
                .padding(.top, 12)

                VStack(spacing: 10) {
                    Button {
                        #if canImport(UIKit)
                        UIPasteboard.general.string = store.logText()
                        #endif
                        showCopiedToast = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                            showCopiedToast = false
                        }
                    } label: {
                        Label(showCopiedToast ? "Tersalin!" : "Salin Log", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(accent)

                    Button {
                        logSnapshotForExport = store.logText()
                        showLogExporter = true
                    } label: {
                        Label("Simpan sebagai File…", systemImage: "square.and.arrow.down")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        store.clearLog()
                    } label: {
                        Label("Hapus Log", systemImage: "trash")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.logLineCount == 0)
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Log Diagnostik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { showLogSheet = false }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: - Helpers

    private var errorBinding: Binding<Bool> {
        Binding(get: { store.errorMessage != nil },
                set: { if !$0 { store.errorMessage = nil } })
    }

    private var statusText: String {
        switch store.state {
        case .poweredOff: return "Bluetooth mati"
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

/// Dokumen plain-text buat `.fileExporter` — dipakai tombol "Simpan sebagai
/// File…" di logSheet. Cukup write-only (init(configuration:) tidak akan
/// pernah dipakai karena app ini tidak menawarkan buka-log-lama), tapi
/// FileDocument mewajibkan itu ada.
struct LogDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }

    var text: String
    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let string = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        text = string
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

struct MetricValue: Identifiable {
    let id = UUID()
    let icon: String
    let title: String
    let valueText: String
    let unit: String
    var color: Color = .white
}

#Preview {
    ContentView()
}