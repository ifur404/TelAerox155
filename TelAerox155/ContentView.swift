import SwiftUI

struct ContentView: View {
    @StateObject private var store = TelemetryStore()

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

    private var connectButton: some View {
        Button {
            store.isActive ? store.disconnect() : store.connect()
        } label: {
            Label(store.isActive ? "Putuskan" : "Hubungkan",
                  systemImage: store.isActive ? "stop.circle.fill" : "bolt.fill")
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
        .disabled(store.isActive ? false : store.state == .scanning ||
                  store.state == .connecting || store.state == .authenticating)
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

            if store.state == .scanning {
                discoveryDebugList
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 40)
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