import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

struct ContentView: View {
    @StateObject private var store = TelemetryStore()
    // Default "Penuh" — hasil uji lapangan paling stabil. Perangkat yang sudah
    // pernah menyimpan pilihan lain tidak ikut berubah (lihat TelemetryStore).
    @AppStorage("keepAlivePolicy") private var keepAlivePolicyRaw: String = KeepAlivePolicy.full.rawValue
    @State private var showLogSheet = false
    @State private var showAuthCopiedToast = false
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
        .preferredColorScheme(.dark)
        .alert("Kesalahan", isPresented: errorBinding) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "Terjadi kesalahan")
        }
        .sheet(isPresented: $showLogSheet) {
            LogSheetView(store: store, recorder: store.recorder, location: store.location, accent: accent)
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
                if let model = store.modelCode {
                    Text(model)
                        .font(.caption2.weight(.semibold).monospaced())
                        .foregroundStyle(.secondary)
                }
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
                    metricCard(fiLampMetric)
                    metricCard(injectionMetric)
                }

                metricCard(odometerMetric)

                extraInfoSection
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
                Button { selectedSensorKey = "rpm" } label: {
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
                }
                .buttonStyle(.plain)
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
        return Button { selectedSensorKey = "speed" } label: {
            ZStack {
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
        }
        .buttonStyle(.plain)
        .animation(.snappy, value: speed)
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
                    .lineLimit(1)
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

    private var fiLampMetric: MetricValue {
        guard let n = store.snapshot.value("fiWarningLamp") else {
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
            HStack {
                Text("Info Tambahan")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
            }
            HStack(spacing: 14) {
                metricCard(ecuPowerOnMetric, corner: 18)
                metricCard(ignOnCountMetric, corner: 18)
            }
            metricCard(fuelMetric, corner: 18)
        }
    }

    private var ecuPowerOnMetric: MetricValue {
        guard let d = store.snapshot.decoded("ecuPowerOnTime") else {
            return MetricValue(key: "ecuPowerOnTime", icon: "power", title: "ECU Total Nyala",
                               valueText: "--", unit: "", color: .secondary)
        }
        let hari = d.value / 86_400
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
        guard let d = store.snapshot.decoded(key) else {
            return MetricValue(key: key, icon: icon, title: title, valueText: "--",
                               unit: "", color: .secondary)
        }
        return MetricValue(key: key, icon: icon, title: title,
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
        .padding(.horizontal, 32)
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
        case .full: return "Sama seperti app resmi — juga ikut men-set jam di dashboard motor. Paling stabil pada uji lapangan."
        }
    }

    /// Dibungkus ScrollView: panel "Tahap auth" bisa berisi puluhan baris
    /// (retry berulang menumpuk dalam satu sesi idle) — tanpa scroll, konten
    /// mendorong header ("TelAerox" + status bar) keluar layar sepenuhnya.
    private var idleView: some View {
        ScrollView {
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

/// Sheet "Log Diagnostik" — diekstrak jadi View sendiri (bukan computed
/// property di ContentView) supaya `.fileExporter` menempel pada hierarki DI
/// DALAM sheet, bukan di root ZStack milik ContentView. Sebelumnya
/// `.fileExporter` dipasang di root sementara dipicu dari dalam sheet — UIKit
/// menolak mem-present modal kedua di atas sheet yang sudah aktif, dan
/// kegagalannya senyap total (completion handler membuang `Result`).
struct LogSheetView: View {
    @ObservedObject var store: TelemetryStore
    @ObservedObject var recorder: SessionRecorder
    @ObservedObject var location: LocationProvider
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    @State private var recordFormat: SessionRecorder.Format = .bleRaw

    // Binding lokal ke key yang sama dengan TelemetryStore.diagLogEnabled —
    // pola ini sudah dipakai buat keepAlivePolicy (lihat ContentView.keepAlivePicker):
    // @AppStorage sendiri yang memicu re-render View saat berubah, sedangkan
    // TelemetryStore membaca key yang sama buat gating logika internal.
    // Binding lewat $store.diagLogEnabled TIDAK dipakai karena properti itu
    // bukan @Published — perubahannya tidak akan memicu objectWillChange.
    @AppStorage("diagLogEnabled") private var diagLogEnabled: Bool = false

    @State private var showLogExporter = false
    @State private var showCopiedToast = false
    // Di-set SEKALI saat tombol ditekan, bukan dibaca ulang tiap body
    // dievaluasi (snapshot telemetri berubah ~20 Hz saat streaming — building
    // ulang string log yang bisa ribuan baris tiap frame itu boros).
    @State private var logSnapshotForExport = ""
    @State private var exportFilename = ""
    @State private var exportResultMessage: String?
    @State private var exportResultIsError = false
    // File temp buat ShareLink — dibuat sekali per tap "Bagikan", dibaca dari
    // App Sandbox tmp/ (bukan Documents) karena isinya sekali-pakai.
    @State private var shareURL: URL?

    var body: some View {
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

                Toggle(isOn: $store.diagLogEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Aktifkan Log Diagnostik")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(.white)
                        Text("Mati secara default. Saat aktif, semua frame BLE mentah + tahap koneksi disimpan ke buffer ini sampai dihapus atau app ditutup.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(accent)
                .padding(.horizontal, 24)

                recordingSection
                    .padding(.horizontal, 24)

                Divider()
                    .overlay(Color.white.opacity(0.1))
                    .padding(.horizontal, 24)

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
                        prepareShareFile()
                    } label: {
                        Label("Bagikan Log…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        logSnapshotForExport = store.logText()
                        exportFilename = Self.makeLogFileName()
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

                    if let message = exportResultMessage {
                        Text(message)
                            .font(.caption)
                            .foregroundStyle(exportResultIsError ? .red : .green)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal, 24)

                Spacer()
            }
            .navigationTitle("Log Diagnostik")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
        .fileExporter(isPresented: $showLogExporter,
                      document: LogDocument(text: logSnapshotForExport),
                      contentType: .plainText,
                      defaultFilename: exportFilename) { result in
            switch result {
            case .success(let url):
                showExportResult("Tersimpan: \(url.lastPathComponent)", isError: false)
            case .failure(let error):
                // NSUserCancelledError (batal dari document picker) bukan
                // kegagalan sungguhan — jangan tampilkan sebagai error.
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError {
                    return
                }
                showExportResult("Gagal menyimpan: \(error.localizedDescription)", isError: true)
            }
        }
        .sheet(item: Binding(get: { shareURL.map(ShareItem.init) },
                              set: { shareURL = $0?.url })) { item in
            ActivityShareSheet(activityItems: [item.url])
        }
    }

    /// Rekaman sesi ke FILE (bukan buffer memori) — beda dari toggle "Log
    /// Diagnostik" di atas: dua format (BLE Raw / CSV per detik), ditulis
    /// langsung ke disk (aman buat sesi panjang termasuk di background), dan
    /// otomatis berhenti kalau kena limit ukuran/durasi (lihat SessionRecorder).
    private var recordingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Rekaman Sesi")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)

            if recorder.isRecording {
                TimelineView(.periodic(from: recorder.startedAt ?? .now, by: 1)) { context in
                    let elapsed = Int(context.date.timeIntervalSince(recorder.startedAt ?? context.date))
                    HStack {
                        Circle().fill(.red).frame(width: 8, height: 8)
                        Text("Merekam \(recorder.format.rawValue) — \(elapsed / 60)m \(elapsed % 60)d — \(formattedSize(recorder.bytesWritten))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                if recorder.format == .csv {
                    gpsStatusRow
                }
                Button(role: .destructive) {
                    recorder.stop()
                } label: {
                    Label("Stop Rekam", systemImage: "stop.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            } else {
                Picker("Format", selection: $recordFormat) {
                    ForEach(SessionRecorder.Format.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)

                Text("BLE Raw: semua frame TX/RX mentah (kredensial/VIN disensor). CSV: satu baris per detik, nilai terdecode + header (termasuk GPS). Otomatis berhenti di 20 MB atau 6 jam. Tetap berjalan kalau app diminimize (background BLE) selama sesi masih terhubung.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if recordFormat == .csv {
                    gpsStatusRow
                }

                Button {
                    _ = recorder.start(format: recordFormat)
                } label: {
                    Label("Mulai Rekam", systemImage: "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                if let url = recorder.fileURL {
                    if let reason = recorder.stopReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    HStack {
                        Text(url.lastPathComponent)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            shareURL = url
                        } label: {
                            Label("Bagikan", systemImage: "square.and.arrow.up")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(accent)
                    }
                }
            }
        }
    }

    private func formattedSize(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    /// Status GPS buat kolom gps_* di CSV — GPS baru benar-benar nyala saat
    /// rekaman CSV berjalan (lihat TelemetryStore.startLogCountTimer), jadi
    /// baris ini juga jadi indikator "kenapa kolom gps_* di CSV kosong" kalau
    /// izin belum diberikan atau belum ada fix.
    private var gpsStatusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "location.fill")
                .font(.caption2)
                .foregroundStyle(gpsColor)
            Text(gpsStatusText)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            if location.authorizationStatus == .denied || location.authorizationStatus == .restricted {
                Button("Buka Pengaturan") {
                    #if canImport(UIKit)
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                    #endif
                }
                .font(.caption2)
                .foregroundStyle(accent)
            }
        }
    }

    private var gpsColor: Color {
        switch location.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return location.lastLocation != nil ? .green : .orange
        case .denied, .restricted:
            return .red
        case .notDetermined:
            return .secondary
        @unknown default:
            return .secondary
        }
    }

    private var gpsStatusText: String {
        switch location.authorizationStatus {
        case .denied, .restricted:
            return "Izin lokasi ditolak — kolom gps_* akan kosong."
        case .notDetermined:
            return "Izin lokasi akan diminta saat rekaman dimulai."
        case .authorizedWhenInUse:
            return "Izin lokasi \"Saat Digunakan\" saja — GPS berhenti kalau app di-background. Pilih \"Selalu\" di Pengaturan buat rekaman background."
        case .authorizedAlways:
            return location.lastLocation != nil ? "GPS aktif, ada fix." : "GPS aktif, menunggu fix pertama…"
        @unknown default:
            return ""
        }
    }

    /// "telaerox-log_2026-09-22_20-14-05" — cukup unik + gampang dibaca kalau
    /// beberapa kali export dalam satu sesi ujicoba di motor.
    private static func makeLogFileName() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return "telaerox-log_\(f.string(from: Date()))"
    }

    private func showExportResult(_ message: String, isError: Bool) {
        exportResultMessage = message
        exportResultIsError = isError
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
            if exportResultMessage == message { exportResultMessage = nil }
        }
    }

    /// Tulis snapshot log ke file temp lalu tampilkan share sheet — jalur ini
    /// tidak lewat document picker sama sekali, jadi tidak kena masalah
    /// "modal ganda" yang bikin fileExporter gagal diam.
    private func prepareShareFile() {
        let text = store.logText()
        let name = Self.makeLogFileName() + ".txt"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            shareURL = url
        } catch {
            showExportResult("Gagal menyiapkan berkas: \(error.localizedDescription)", isError: true)
        }
    }
}

/// Wrapper `Identifiable` supaya `URL` (yang bukan Identifiable) bisa dipakai
/// dengan `.sheet(item:)`.
private struct ShareItem: Identifiable {
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

/// Dokumen plain-text buat `.fileExporter` — dipakai tombol "Simpan sebagai
/// File…" di LogSheetView. Cukup write-only (init(configuration:) tidak akan
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