import SwiftUI
import Charts

struct TripQualityCard: View {
    let analysis: TripAnalysis
    let playback: TripPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                TripStatTile(title: "Data motor valid", value: percent(analysis.ecuCoverage), icon: "motorcycle")
                if analysis.availableColumns.contains("gps_lat") {
                    TripStatTile(title: "GPS valid", value: percent(analysis.gpsCoverage), icon: "location")
                }
                if analysis.hasPhoneColumns {
                    TripStatTile(title: "Gerakan tersedia", value: percent(analysis.motionCoverage), icon: "gyroscope")
                }
                TripStatTile(title: "Jeda rekaman", value: RecordingFormat.duration(analysis.recordingGapSeconds), icon: "clock.badge.exclamationmark")
                if analysis.hasQualityColumns {
                    TripStatTile(title: "BLE belum streaming", value: RecordingFormat.duration(analysis.bleUnavailableSeconds), icon: "antenna.radiowaves.left.and.right.slash")
                }
            }
            Text("Persentase terhadap durasi rekaman, termasuk jeda penulisan. Data motor/GPS yang basi tidak dihitung sebagai data valid.")
                .font(.caption).foregroundStyle(.secondary)
            if !analysis.hasQualityColumns {
                Text("CSV lama: usia sensor dan status koneksi belum dicatat; kualitas motor hanya berdasarkan nilai yang tersedia.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !analysis.gaps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Jeda data · \(analysis.gaps.count)").font(.subheadline.weight(.semibold))
                    ForEach(worstGaps) { gap in
                        Button { playback.seek(to: gap.start) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(gap.kind.title).foregroundStyle(.white)
                                Text("\(RecordingFormat.clock(gap.start))–\(RecordingFormat.clock(gap.end)) · \(RecordingFormat.duration(gap.duration))")
                                    .foregroundStyle(.secondary)
                            }
                            .font(.caption)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 3)
                        }.buttonStyle(.plain)
                    }
                    if analysis.gaps.count > 20 { Text("Menampilkan 20 jeda terlama.").font(.caption2).foregroundStyle(.secondary) }
                }
            }
        }
    }

    private var worstGaps: [TripDataGap] {
        Array(analysis.gaps.sorted { $0.duration > $1.duration }.prefix(20)).sorted { $0.start < $1.start }
    }
    private func percent(_ value: Double) -> String { String(format: "%.1f%%", value) }
}

struct TripPhoneSummary: View {
    let analysis: TripAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                if let start = analysis.phoneBatteryStart, let end = analysis.phoneBatteryEnd {
                    TripStatTile(title: "Baterai iPhone", value: String(format: "%.0f → %.0f%%", start, end), icon: "battery.75percent",
                                 detail: String(format: "Perubahan %+.0f poin", end - start))
                }
                if let peak = analysis.maxMotionPeak {
                    TripStatTile(title: "Puncak gerakan HP", value: String(format: "%.1f m/s²", peak), icon: "waveform.path")
                }
            }
            Text("Posisi iPhone: \(analysis.samples.first?.placement.title ?? PhonePlacement.unknown.title)")
                .font(.caption).foregroundStyle(.secondary)
            if analysis.chargingSeconds > 0 {
                Text("Pengisian terdeteksi selama \(RecordingFormat.duration(analysis.chargingSeconds)); perubahan baterai bukan ukuran konsumsi murni.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("Gerakan diringkas dari target 50 sampel/detik: puncak dan RMS per jendela. Orientasi mengikuti HP. Sensor yang tidak didukung atau tidak diizinkan akan kosong.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TripElevationSummary: View {
    let analysis: TripAnalysis

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            if let gain = analysis.altitudeGain, let loss = analysis.altitudeLoss {
                TripStatTile(title: "Total naik / turun", value: String(format: "%.0f / %.0f m", gain, loss), icon: "mountain.2",
                             detail: analysis.elevationSource)
            }
            if let up = analysis.maxGrade, let down = analysis.minGrade {
                TripStatTile(title: "Estimasi kemiringan", value: String(format: "%+.1f / %+.1f%%", up, down), icon: "angle",
                             detail: "Ruas ≥100 m; bergantung akurasi elevasi")
            }
        }
    }
}

struct TripPhoneCharts: View {
    let analysis: TripAnalysis
    let playback: TripPlayback

    var body: some View {
        if !analysis.accelerationSeries.isEmpty {
            chart("Akselerasi / perlambatan · m/s²", points: analysis.accelerationSeries, color: .orange, value: \.acceleration, format: "%+.2f")
        }
        if !analysis.motionPeakSeries.isEmpty {
            chart("Puncak gerakan iPhone · m/s²", points: analysis.motionPeakSeries, color: .pink, value: \.motionPeak, format: "%.2f")
        }
        if !analysis.verticalRMSSeries.isEmpty {
            chart("Guncangan vertikal RMS · m/s²", points: analysis.verticalRMSSeries, color: .purple, value: \.verticalRMS, format: "%.2f")
        }
        if !analysis.rollSeries.isEmpty {
            TripLineChart(title: "Orientasi HP · °", series: [
                TripLineSeries(id: "Roll", points: analysis.rollSeries, color: .pink),
                TripLineSeries(id: "Pitch", points: analysis.pitchSeries, color: .cyan)
            ], playback: playback) { s in
                "\(format(s?.roll, "%.1f")) / \(format(s?.pitch, "%.1f"))°"
            }
        }
        if !analysis.yawSeries.isEmpty {
            chart("Yaw HP · °", points: analysis.yawSeries, color: .mint, value: \.yaw, format: "%.1f")
        }
        if !analysis.rotationSeries.isEmpty {
            chart("Kecepatan rotasi HP · rad/s", points: analysis.rotationSeries, color: .cyan, value: \.rotationRate, format: "%.2f")
        }
        if !analysis.relativeAltitudeSeries.isEmpty {
            chart("Elevasi relatif · m", points: analysis.relativeAltitudeSeries, color: .purple, value: \.relativeAltitude, format: "%+.1f")
        }
        if !analysis.pressureSeries.isEmpty {
            chart("Tekanan udara iPhone · kPa", points: analysis.pressureSeries, color: .teal, value: \.pressure, format: "%.2f")
        }
        if !analysis.phoneBatterySeries.isEmpty {
            chart("Baterai iPhone · %", points: analysis.phoneBatterySeries, color: .green, value: \.phoneBattery, format: "%.0f")
        }
    }

    private func chart(_ title: String, points: [ChartPoint], color: Color,
                       value: KeyPath<TripSample, Double?>, format pattern: String) -> some View {
        TripLineChart(title: title, series: [TripLineSeries(id: title, points: points, color: color)], playback: playback) { s in
            format(s?[keyPath: value], pattern)
        }
    }
    private func format(_ value: Double?, _ pattern: String) -> String {
        value.map { String(format: pattern, $0) } ?? "—"
    }
}

struct TripSensorReadout: View {
    let playback: TripPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pada \(RecordingFormat.clock(playback.playhead))").font(.subheadline.weight(.semibold))
            if let s = playback.sample {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                    if !playback.analysis.availableColumns.isDisjoint(with: ["ble_state"]) {
                    row("Koneksi motor", connection(s.bleState))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["ecu_rpm_age_s"]) {
                    row("Usia data RPM", value(s.ecuAge, "%.2f s"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["gps_status"]) {
                    row("Status GPS", status(s.gpsStatus))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["gps_age_s", "gps_accuracy_m"]) {
                    row("Usia / akurasi GPS", value(s.gpsAge, "%.2f s") + " / " + value(s.accuracy, "±%.1f m"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["gps_speed_accuracy_mps"]) {
                    row("Akurasi kecepatan", value(s.speedAccuracy, "±%.2f m/s"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["gps_vertical_accuracy_m"]) {
                    row("Akurasi elevasi", value(s.verticalAccuracy, "±%.1f m"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["gps_course_deg", "gps_course_accuracy_deg"]) {
                    row("Arah perjalanan", value(s.course, "%.0f°") + " · " + value(s.courseAccuracy, "±%.0f°"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["motion_status", "motion_age_s"]) {
                    row("Gerakan", status(s.motionStatus) + " · " + value(s.motionAge, "%.2f s"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["motion_samples", "motion_span_s"]) {
                    row("Sampel / jendela", value(s.motionCount, "%.0f") + " / " + value(s.motionSpan, "%.2f s"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["gps_speed_kmh", "speed_kmh"]) {
                    row("Percepatan", value(s.acceleration, "%+.2f m/s²"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["motion_peak_mps2", "motion_rms_mps2"]) {
                    row("Puncak / RMS HP", value(s.motionPeak, "%.2f") + " / " + value(s.motionRMS, "%.2f m/s²"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["roll_deg", "pitch_deg", "yaw_deg"]) {
                    row("Roll / pitch / yaw HP", value(s.roll, "%.1f") + " / " + value(s.pitch, "%.1f") + " / " + value(s.yaw, "%.1f°"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["barometer_status", "barometer_age_s"]) {
                    row("Barometer", status(s.barometerStatus) + " · " + value(s.barometerAge, "%.2f s"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["phone_pressure_kpa", "phone_relative_alt_m"]) {
                    row("Tekanan / elevasi relatif", value(s.pressure, "%.2f kPa") + " / " + value(s.relativeAltitude, "%+.1f m"))
                    }
                    if !playback.analysis.availableColumns.isDisjoint(with: ["phone_battery_pct"]) {
                    row("Baterai iPhone", value(s.phoneBattery, "%.0f%%") + " · " + batteryState(s.phoneBatteryState))
                    }
                }.font(.caption)
            } else {
                Text("Tidak ada sampel pada waktu ini (jeda rekaman).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: String, _ text: String) -> some View {
        GridRow(alignment: .top) {
            Text(title).foregroundStyle(.secondary)
            Text(text).foregroundStyle(.white).monospacedDigit().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func value(_ value: Double?, _ pattern: String) -> String {
        value.map { String(format: pattern, $0) } ?? "—"
    }
    private func status(_ raw: String?) -> String {
        switch raw {
        case "active": return "Aktif"
        case "waiting": return "Menunggu"
        case "stale": return "Data basi"
        case "unavailable": return "Tidak didukung"
        case "denied": return "Izin ditolak"
        case "error": return "Gagal membaca"
        default: return "Belum dicatat"
        }
    }
    private func batteryState(_ raw: String?) -> String {
        switch raw {
        case "charging": return "Mengisi"
        case "full": return "Penuh / tersambung"
        case "unplugged": return "Tidak mengisi"
        default: return "Status tidak tersedia"
        }
    }
    private func connection(_ raw: String?) -> String {
        switch raw {
        case "streaming": return "Menerima telemetri"
        case "connecting": return "Menyambung"
        case "authenticating": return "Autentikasi"
        case "scanning": return "Mencari motor"
        case "poweredOff": return "Tidak tersambung"
        case "failed": return "Koneksi gagal"
        default: return "Belum dicatat"
        }
    }
}

struct TripEventsCard: View {
    let analysis: TripAnalysis
    let playback: TripPlayback
    @State private var showInfo = false
    @State private var showAll = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private let previewCount = 4

    private var events: [TripEvent] {
        analysis.events.sorted { $0.t < $1.t }
    }

    var body: some View {
        let items = events
        let visible = Array(items.prefix(previewCount))
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("ESTIMASI")
                    .font(.system(.caption2, design: .monospaced).weight(.medium))
                    .tracking(1.5)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { showInfo = true } label: {
                    Image(systemName: "info.circle")
                        .font(.body)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Tentang deteksi kejadian")
            }

            if items.isEmpty {
                Text("Tidak ada kejadian terdeteksi")
                    .font(.subheadline.weight(.medium))
                    .padding(.bottom, 6)
                Text("Data yang tersedia tidak memenuhi ambang deteksi.")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            } else {
                // Ringkasan angka tanpa badge/kartu tambahan.
                let summaryLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
                summaryLayout {
                    ForEach(TripEvent.Kind.allCases, id: \.rawValue) { kind in
                        if dynamicTypeSize.isAccessibilitySize {
                            HStack {
                                Text(title(kind)).font(.caption).foregroundStyle(.secondary)
                                Spacer()
                                Text(items.filter { $0.kind == kind }.count.formatted())
                                    .font(.system(.title2, design: .monospaced).weight(.medium))
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(items.filter { $0.kind == kind }.count.formatted())
                                    .font(.system(.title2, design: .monospaced).weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(title(kind))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(.bottom, 8)
                Divider()
                ForEach(visible) { event in
                    eventRow(event)
                    Divider()
                }
                if items.count > previewCount {
                    Button { showAll = true } label: {
                        HStack {
                            Text("Lihat semua \(items.count) kejadian")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                        }
                        .font(.subheadline.weight(.medium))
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.primary)
                }
            }
        }
        .sheet(isPresented: $showAll) {
            NavigationStack {
                List {
                    Section {
                        ForEach(items) { event in
                            eventRow(event)
                                .listRowInsets(EdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12))
                                .listRowBackground(RecordingPalette.card)
                        }
                    } header: {
                        Text("\(items.count) kejadian · Estimasi")
                    } footer: {
                        Text("Pilih kejadian untuk kembali ke detail pada waktu tersebut.")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
                .background(RecordingPalette.background)
                .navigationTitle("Kejadian perjalanan")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Selesai") { showAll = false }
                    }
                }
            }
            .preferredColorScheme(.dark)
        }
        .alert("Tentang kejadian", isPresented: $showInfo) {
            Button("Tutup", role: .cancel) {}
        } message: {
            Text("Hasil masih estimasi, bukan penilaian gaya berkendara. Akselerasi/perlambatan dihitung dari perubahan kecepatan dengan ambang ±2,5 m/s². Perlambatan tidak selalu berarti tuas rem ditekan. Guncangan memakai percepatan vertikal ≥8 m/s² saat melaju dengan HP di holder. Jarak kejadian sejenis minimal 10 detik. Ketuk baris untuk melihat momennya pada replay.")
        }
    }

    private func eventRow(_ event: TripEvent) -> some View {
        Button {
            playback.seek(to: event.t)
            showAll = false
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    Text(RecordingFormat.clock(event.t))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .fixedSize()
                    eventLabel(event)
                    Spacer(minLength: 8)
                    eventValue(event)
                }
                // Ukuran teks aksesibilitas: pindahkan waktu, jangan mengecilkan huruf.
                VStack(alignment: .leading, spacing: 10) {
                    Text(RecordingFormat.clock(event.t))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    eventLabel(event)
                    eventValue(event)
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title(event.kind)), \(RecordingFormat.clock(event.t)), \(String(format: "%+.2f", event.value)) meter per detik kuadrat")
        .accessibilityHint("Lompat ke waktu kejadian pada replay")
    }

    private func eventLabel(_ event: TripEvent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: event.kind.icon)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(title(event.kind))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    private func eventValue(_ event: TripEvent) -> some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(String(format: event.kind == .bump ? "%.2f" : "%+.2f", event.value))
                .font(.system(.subheadline, design: .monospaced).weight(.medium))
                .foregroundStyle(.primary)
            Text("m/s²").font(.caption2).foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private func title(_ kind: TripEvent.Kind) -> String {
        switch kind {
        case .acceleration: return "Akselerasi"
        case .braking: return "Perlambatan"
        case .bump: return "Guncangan HP"
        }
    }

}

struct TripElevationProfile: View {
    let analysis: TripAnalysis
    let playback: TripPlayback

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Elevasi sepanjang jarak").font(.subheadline.weight(.semibold))
            Text(analysis.elevationSource).font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(analysis.elevationProfile) { p in
                    LineMark(x: .value("Jarak (km)", p.km), y: .value("Elevasi (m)", p.altitude), series: .value("Ruas", p.segment))
                        .foregroundStyle(.purple)
                }
                if let s = playback.sample {
                    RuleMark(x: .value("Posisi", s.distanceKm)).foregroundStyle(.white.opacity(0.6))
                }
            }
            .frame(height: 150)
            .chartXAxisLabel("Jarak GPS (km)")
            .chartYAxisLabel("m")
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onTapGesture { point in
                            guard let anchor = proxy.plotFrame else { return }
                            let x = point.x - geometry[anchor].minX
                            guard let km = proxy.value(atX: x, as: Double.self),
                                  let p = analysis.elevationProfile.min(by: { abs($0.km - km) < abs($1.km - km) }) else { return }
                            playback.seek(to: p.t)
                        }
                }
            }
            if !analysis.gradeSeries.isEmpty {
                TripLineChart(title: "Estimasi kemiringan · %", series: [TripLineSeries(id: "Kemiringan", points: analysis.gradeSeries, color: .purple)], playback: playback) { s in
                    guard let s, let p = analysis.gradeSeries.min(by: { abs($0.t - s.t) < abs($1.t - s.t) }), abs(p.t - s.t) <= 2 else { return "—" }
                    return String(format: "%+.1f%%", p.v)
                }
            }
            Text("Ketuk profil untuk replay. Elevasi dan kemiringan adalah estimasi; tekanan udara dan akurasi GPS memengaruhi hasil.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
