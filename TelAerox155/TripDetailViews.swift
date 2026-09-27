import SwiftUI
import Charts
import MapKit
import CoreLocation
import Observation

// Komponen halaman detail rekaman CSV: peta rute, chart timeline, kurva CVT,
// gaya berkendara, histogram, dan replay. Datanya dari `TripAnalysis`
// (dihitung di background); semua ini murni membaca file rekaman di HP —
// tidak ada komunikasi ke motor sama sekali.

// MARK: - Playback (kursor waktu bersama)

/// Satu "kursor waktu" yang dipakai bersama oleh peta, semua chart, dan bar
/// replay: scrub di chart → titik di peta ikut pindah, tap di peta → garis di
/// chart ikut pindah, tombol ▶︎ → semuanya bergerak.
///
/// @Observable (bukan ObservableObject) sengaja: view hanya di-render ulang
/// kalau properti yang BENAR-BENAR dibacanya berubah. Chart dasar (ratusan
/// titik) tidak membaca `playhead`, cuma overlay kursornya — jadi saat replay
/// jalan 10×/detik yang di-render ulang cuma garis kursor, bukan chart-nya.
@Observable
final class TripPlayback {
    let analysis: TripAnalysis
    let range: ClosedRange<Double>
    private(set) var playhead: Double
    /// Indeks titik rute (peta) terdekat ke `playhead` — dipisah supaya Map
    /// cuma di-render ulang saat penanda benar-benar pindah titik.
    private(set) var markerIndex: Int?
    private(set) var isPlaying = false
    /// Kelipatan waktu nyata saat replay.
    var rate: Double = 8

    static let rates: [Double] = [1, 4, 8, 16, 60]

    @ObservationIgnored private var timer: Task<Void, Never>?

    init(analysis: TripAnalysis) {
        self.analysis = analysis
        let lo = analysis.startTime
        range = lo...max(analysis.endTime, lo + 1)
        playhead = lo
        markerIndex = analysis.routeIndex(at: lo)
    }

    var sample: TripSample? { analysis.sample(at: playhead) }

    func seek(to t: Double) {
        let c = min(range.upperBound, max(range.lowerBound, t))
        playhead = c
        let idx = analysis.routeIndex(at: c)
        if idx != markerIndex { markerIndex = idx }
    }

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        if playhead >= range.upperBound { seek(to: range.lowerBound) }
        isPlaying = true
        timer?.cancel()
        // Task mewarisi MainActor (kelas ini MainActor lewat default
        // isolation) — aman mengubah state dari sini. `weak self`: kalau
        // halaman ditutup, loop berhenti sendiri.
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, self.isPlaying else { return }
                self.seek(to: self.playhead + 0.1 * self.rate)
                if self.playhead >= self.range.upperBound { self.pause() }
            }
        }
    }

    func pause() {
        isPlaying = false
        timer?.cancel()
        timer = nil
    }
}

// MARK: - Warna

enum TripPalette {
    /// Hijau (pelan) → merah (paling kencang di trip ini).
    static func speedColor(level: Int) -> Color {
        let x = Double(level) / Double(max(1, TripAnalysis.speedLevels - 1))
        return Color(hue: 0.36 * (1 - x), saturation: 0.85, brightness: 0.95)
    }

    static var speedGradient: LinearGradient {
        LinearGradient(colors: (0..<TripAnalysis.speedLevels).map { speedColor(level: $0) },
                       startPoint: .leading, endPoint: .trailing)
    }

    /// Biru (gas tutup) → merah (gas penuh), relatif ke `maxThrottle`.
    static func throttleColor(_ v: Double, max maxThrottle: Double) -> Color {
        let x = min(1, max(0, v / Swift.max(10, maxThrottle)))
        return Color(hue: 0.6 * (1 - x), saturation: 0.8, brightness: 0.95)
    }

    static func modeColor(_ m: RidingMode) -> Color {
        switch m {
        case .idle: return Color.white.opacity(0.35)
        case .accelerating: return Color(red: 0.98, green: 0.47, blue: 0.25)
        case .cruising: return Color(red: 0.30, green: 0.72, blue: 1.0)
        case .coasting: return Color(red: 0.62, green: 0.50, blue: 0.98)
        }
    }

    static let ecu = Color(red: 0.30, green: 0.85, blue: 1.0)
    static let rpm = Color(red: 1.0, green: 0.62, blue: 0.20)
    static let throttle = Color(red: 1.0, green: 0.84, blue: 0.25)
    static let coolant = Color(red: 1.0, green: 0.38, blue: 0.40)
    static let intake = Color(red: 0.45, green: 0.90, blue: 0.85)
    static let battery = Color(red: 0.45, green: 0.90, blue: 0.45)
    static let altitude = Color(red: 0.72, green: 0.58, blue: 1.0)
}

private extension RoutePoint {
    nonisolated var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

// MARK: - Peta

struct TripRouteMap: View {
    let analysis: TripAnalysis
    let playback: TripPlayback
    let accent: Color
    @Binding var position: MapCameraPosition

    var body: some View {
        MapReader { proxy in
            Map(position: $position) {
                ForEach(analysis.routeSegments) { seg in
                    MapPolyline(coordinates: seg.points.map { $0.coordinate })
                        .stroke(TripPalette.speedColor(level: seg.level),
                                style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                }

                ForEach(longestStops) { stop in
                    Annotation("Berhenti", coordinate: stop.coordinate) {
                        Image(systemName: "pause.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Color.gray, in: Circle())
                            .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 1))
                    }
                }

                if let first = analysis.route.first {
                    Annotation("Start", coordinate: first.coordinate) {
                        pin("flag.fill", color: .green)
                    }
                }
                if let last = analysis.route.last {
                    Annotation("Finish", coordinate: last.coordinate) {
                        pin("flag.checkered", color: .white, foreground: .black)
                    }
                }
                if let t = analysis.maxSpeedTime, let p = analysis.routePoint(at: t),
                   let v = analysis.maxSpeed {
                    Annotation("Tercepat", coordinate: p.coordinate, anchor: .bottom) {
                        HStack(spacing: 3) {
                            Image(systemName: "bolt.fill")
                            Text(String(format: "%.0f km/h", v))
                        }
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(TripPalette.speedColor(level: TripAnalysis.speedLevels - 1), in: Capsule())
                    }
                }

                if let i = playback.markerIndex, analysis.route.indices.contains(i) {
                    Annotation("Posisi", coordinate: analysis.route[i].coordinate) {
                        Circle()
                            .fill(accent)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().stroke(.white, lineWidth: 3))
                            .shadow(color: accent.opacity(0.8), radius: 6)
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
            .annotationTitles(.hidden)
            .onTapGesture { screenPoint in
                // Tap di dekat rute → lompat ke waktu titik terdekat.
                guard let c = proxy.convert(screenPoint, from: .local),
                      let p = analysis.nearestRoutePoint(lat: c.latitude, lon: c.longitude) else { return }
                playback.seek(to: p.t)
            }
        }
    }

    private struct StopPin: Identifiable {
        let id: Double
        let coordinate: CLLocationCoordinate2D
    }

    /// Maks 8 titik berhenti terlama (yang punya koordinat) supaya peta
    /// tidak penuh ikon di perjalanan macet.
    private var longestStops: [StopPin] {
        analysis.stops
            .sorted { $0.duration > $1.duration }
            .compactMap { s in
                guard let lat = s.lat, let lon = s.lon else { return nil }
                return StopPin(id: s.start, coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon))
            }
            .prefix(8)
            .map { $0 }
    }

    private func pin(_ icon: String, color: Color, foreground: Color = .white) -> some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(foreground)
            .frame(width: 26, height: 26)
            .background(color, in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 3)
    }
}

/// Legenda warna rute.
struct TripSpeedLegend: View {
    let scale: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("0")
            Capsule()
                .fill(TripPalette.speedGradient)
                .frame(height: 6)
            Text(String(format: "%.0f km/h", scale))
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
    }
}

struct TripMapCard: View {
    let analysis: TripAnalysis
    let playback: TripPlayback
    let accent: Color
    @State private var position: MapCameraPosition = .automatic
    @State private var showFullScreen = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack(alignment: .topTrailing) {
                TripRouteMap(analysis: analysis, playback: playback, accent: accent, position: $position)
                    .frame(height: 280)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                Button {
                    showFullScreen = true
                } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .accessibilityLabel("Buka peta layar penuh")
            }
            TripSpeedLegend(scale: analysis.routeSpeedScale)
            Text("Tap rute untuk lompat ke momen itu. Warna = kecepatan relatif terhadap yang tercepat di perjalanan ini.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fullScreenCover(isPresented: $showFullScreen) {
            TripMapFullScreen(analysis: analysis, playback: playback, accent: accent)
        }
    }
}

/// Peta layar penuh + bar replay, dengan mode "ikuti" ala kamera dashcam:
/// kamera menempel ke posisi dan menghadap arah laju.
struct TripMapFullScreen: View {
    let analysis: TripAnalysis
    let playback: TripPlayback
    let accent: Color
    @Environment(\.dismiss) private var dismiss
    @State private var position: MapCameraPosition = .automatic
    @State private var follow = false

    var body: some View {
        NavigationStack {
            TripRouteMap(analysis: analysis, playback: playback, accent: accent, position: $position)
                .ignoresSafeArea(edges: .bottom)
                .safeAreaInset(edge: .bottom) {
                    TripPlaybackBar(playback: playback, accent: accent)
                }
                .navigationTitle("Rute")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Tutup") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            follow.toggle()
                            if follow {
                                updateCamera(animated: true)
                            } else {
                                withAnimation { position = .automatic }
                            }
                        } label: {
                            Label(follow ? "Lepas" : "Ikuti",
                                  systemImage: follow ? "location.fill" : "location")
                        }
                    }
                }
                .onChange(of: playback.markerIndex) { _, _ in
                    if follow { updateCamera(animated: true) }
                }
        }
        .preferredColorScheme(.dark)
    }

    private func updateCamera(animated: Bool) {
        guard let i = playback.markerIndex, analysis.route.indices.contains(i) else { return }
        let p = analysis.route[i]
        // Arah laju dari titik sebelumnya (atau berikutnya kalau di awal).
        let a = analysis.route[max(0, i - 1)]
        let b = i > 0 ? p : analysis.route[min(analysis.route.count - 1, i + 1)]
        let heading = bearing(a, b)
        let cam = MapCamera(centerCoordinate: p.coordinate, distance: 450, heading: heading, pitch: 55)
        if animated {
            withAnimation(.easeInOut(duration: 0.4)) { position = .camera(cam) }
        } else {
            position = .camera(cam)
        }
    }

    private func bearing(_ a: RoutePoint, _ b: RoutePoint) -> Double {
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLon = (b.lon - a.lon) * .pi / 180
        let y = sin(dLon) * cos(lat2)
        let x = cos(lat1) * sin(lat2) - sin(lat1) * cos(lat2) * cos(dLon)
        let deg = atan2(y, x) * 180 / .pi
        return (deg + 360).truncatingRemainder(dividingBy: 360)
    }
}

// MARK: - Bar replay

/// Bar replay di bawah layar: play/pause, slider waktu, kecepatan replay, dan
/// nilai sensor di posisi kursor. Selalu kelihatan saat scroll chart.
struct TripPlaybackBar: View {
    let playback: TripPlayback
    let accent: Color

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                readout(value: fmt(playback.sample?.speed, "%.0f"), unit: "km/h", color: TripPalette.ecu)
                readout(value: fmt(playback.sample?.rpm, "%.0f"), unit: "rpm", color: TripPalette.rpm)
                readout(value: fmt(playback.sample?.throttle, "%.1f"), unit: "° gas", color: TripPalette.throttle)
                readout(value: fmt(playback.sample?.coolant, "%.0f"), unit: "°C", color: TripPalette.coolant)
            }
            HStack(spacing: 10) {
                Button {
                    playback.togglePlay()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 38, height: 38)
                        .background(accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(playback.isPlaying ? "Jeda replay" : "Putar replay")

                VStack(spacing: 2) {
                    Slider(value: Binding(get: { playback.playhead },
                                          set: { playback.seek(to: $0) }),
                           in: playback.range)
                        .tint(accent)
                    HStack {
                        Text(RecordingFormat.clock(playback.playhead))
                        Spacer()
                        Text(RecordingFormat.clock(playback.range.upperBound))
                    }
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                }

                Menu {
                    Picker("Kecepatan replay", selection: Binding(get: { playback.rate },
                                                                  set: { playback.rate = $0 })) {
                        ForEach(TripPlayback.rates, id: \.self) { r in
                            Text(String(format: "%.0f×", r)).tag(r)
                        }
                    }
                } label: {
                    Text(String(format: "%.0f×", playback.rate))
                        .font(.caption.weight(.bold).monospacedDigit())
                        .foregroundStyle(accent)
                        .frame(width: 40, height: 30)
                        .background(accent.opacity(0.15), in: Capsule())
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    private func fmt(_ v: Double?, _ f: String) -> String {
        v.map { String(format: f, $0) } ?? "—"
    }

    private func readout(value: String, unit: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(.headline, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(unit)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Statistik

struct TripStatsGrid: View {
    let analysis: TripAnalysis

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            if let km = analysis.gpsDistanceKm {
                TripStatTile(title: "Jarak (GPS)", value: String(format: "%.2f km", km), icon: "point.topleft.down.to.point.bottomright.curvepath",
                             detail: analysis.odometerDistanceKm.map { String(format: "Odometer: %.1f km", $0) })
            } else if let km = analysis.odometerDistanceKm {
                TripStatTile(title: "Jarak (odometer)", value: String(format: "%.1f km", km), icon: "road.lanes")
            }
            if let v = analysis.maxSpeed {
                TripStatTile(title: "Kecepatan maks", value: String(format: "%.0f km/h", v), icon: "bolt.fill",
                             detail: analysis.avgMovingSpeed.map { String(format: "Rata-rata saat jalan %.1f", $0) })
            }
            if let v = analysis.maxRPM {
                TripStatTile(title: "RPM maks", value: String(format: "%.0f", v), icon: "gauge.with.dots.needle.67percent")
            }
            if analysis.movingSeconds + analysis.stoppedSeconds > 0 {
                TripStatTile(title: "Waktu jalan", value: RecordingFormat.duration(analysis.movingSeconds), icon: "figure.outdoor.cycle",
                             detail: "Berhenti " + RecordingFormat.duration(analysis.stoppedSeconds)
                                + (analysis.stops.isEmpty ? "" : " • \(analysis.stops.count)× stop"))
            }
            if let a = analysis.coolantStart, let b = analysis.coolantEnd {
                TripStatTile(title: "Suhu mesin", value: String(format: "%.0f → %.0f °C", a, b), icon: "thermometer.medium",
                             detail: analysis.coolantMax.map { String(format: "Tertinggi %.0f °C", $0) })
            }
            if let v = analysis.batteryMin {
                TripStatTile(title: "Aki (mesin hidup)", value: String(format: "min %.2f V", v), icon: "minus.plus.batteryblock",
                             detail: analysis.batteryAvg.map { String(format: "Rata-rata %.2f V", $0) })
            }
            if let e = analysis.speedoErrorPercent {
                TripStatTile(title: "Selisih speedometer", value: String(format: "%+.1f%%", e), icon: "speedometer",
                             detail: e >= 0 ? "ECU lebih tinggi dari GPS" : "ECU lebih rendah dari GPS")
            }
            if let ml = analysis.fuelMl {
                TripStatTile(title: "Estimasi BBM ⓔ", value: String(format: "≈ %.0f ml", ml), icon: "fuelpump",
                             detail: analysis.fuelKmPerLiter.map { String(format: "≈ %.0f km/L", $0) })
            }
            if let lo = analysis.altitudeMin, let hi = analysis.altitudeMax {
                TripStatTile(title: "Ketinggian", value: String(format: "%.0f–%.0f m", lo, hi), icon: "mountain.2",
                             detail: analysis.altitudeGain.map { String(format: "Total nanjak %.0f m", $0) })
            }
        }
    }
}

struct TripStatTile: View {
    let title: String
    let value: String
    let icon: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(title, systemImage: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
        .padding(12)
        .background(RecordingPalette.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

// MARK: - Chart timeline

struct TripLineSeries: Identifiable {
    let id: String
    let points: [ChartPoint]
    let color: Color
}

/// Satu chart garis dengan sumbu waktu yang sama dengan chart lain. Kursor
/// dan gesture scrub ada di overlay (lihat `TripChartCursor`) supaya chart-nya
/// sendiri tidak di-render ulang tiap kursor bergerak.
struct TripLineChart: View {
    let title: String
    let series: [TripLineSeries]
    let playback: TripPlayback
    var fromZero = false
    var area = false
    let readout: (TripSample?) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                if series.count > 1 {
                    ForEach(series) { s in
                        HStack(spacing: 3) {
                            Circle().fill(s.color).frame(width: 6, height: 6)
                            Text(s.id).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer(minLength: 4)
                TripChartReadout(playback: playback, text: readout, color: series.first?.color ?? .white)
            }
            chart
                .frame(height: 120)
        }
        .padding(.vertical, 4)
    }

    private var chart: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points) { p in
                    if area && series.count == 1 {
                        AreaMark(x: .value("Waktu", p.t), yStart: .value("Nilai", yDomain.lowerBound),
                                 yEnd: .value("Nilai", p.v))
                            .foregroundStyle(LinearGradient(colors: [s.color.opacity(0.35), s.color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Waktu", p.t), y: .value("Nilai", p.v), series: .value("Seri", s.id))
                        .foregroundStyle(s.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: playback.range)
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    if let d = value.as(Double.self) {
                        Text(RecordingFormat.clock(d))
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel()
            }
        }
        .chartOverlay { proxy in
            TripChartCursor(proxy: proxy, playback: playback)
        }
    }

    private var yDomain: ClosedRange<Double> {
        let vals = series.flatMap { $0.points.map(\.v) }
        guard var lo = vals.min(), var hi = vals.max() else { return 0...1 }
        if fromZero { lo = min(0, lo) }
        let pad = max((hi - lo) * 0.08, 0.5)
        if !fromZero { lo -= pad }
        hi += pad
        return lo...hi
    }
}

/// Nilai di posisi kursor — View terpisah supaya cuma teks ini yang di-render
/// ulang saat kursor bergerak.
private struct TripChartReadout: View {
    let playback: TripPlayback
    let text: (TripSample?) -> String
    let color: Color

    var body: some View {
        Text(text(playback.sample))
            .font(.caption.weight(.semibold).monospacedDigit())
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Garis kursor + gesture scrub di atas area plot chart.
///
/// Scrub pakai `simultaneousGesture` dan hanya bereaksi ke geser HORIZONTAL,
/// supaya scroll vertikal halaman di atas chart tetap jalan normal. Tap =
/// lompat ke titik itu.
private struct TripChartCursor: View {
    let proxy: ChartProxy
    let playback: TripPlayback

    var body: some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame {
                let plot = geo[anchor]
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { pt in seek(x: pt.x - plot.minX) }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 8)
                                .onChanged { g in
                                    guard abs(g.translation.width) > abs(g.translation.height) else { return }
                                    seek(x: g.location.x - plot.minX)
                                }
                        )
                    if let x = proxy.position(forX: playback.playhead) {
                        Rectangle()
                            .fill(Color.white.opacity(0.75))
                            .frame(width: 1.5, height: plot.height)
                            .offset(x: plot.minX + x - 0.75, y: plot.minY)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }

    private func seek(x: CGFloat) {
        if let t = proxy.value(atX: x, as: Double.self) { playback.seek(to: t) }
    }
}

struct TripTimelineCharts: View {
    let analysis: TripAnalysis
    let playback: TripPlayback

    var body: some View {
        if !analysis.speedSeries.isEmpty {
            TripLineChart(title: "Kecepatan",
                          series: [TripLineSeries(id: "ECU", points: analysis.speedSeries, color: TripPalette.ecu)]
                            + (analysis.gpsSpeedSeries.isEmpty ? [] :
                                [TripLineSeries(id: "GPS", points: analysis.gpsSpeedSeries, color: .white.opacity(0.55))]),
                          playback: playback, fromZero: true) { s in
                guard let s else { return "—" }
                var t = s.speed.map { String(format: "%.0f km/h", $0) } ?? "—"
                if let g = s.gpsSpeed { t += String(format: " • GPS %.1f", g) }
                return t
            }
        }
        if !analysis.rpmSeries.isEmpty {
            TripLineChart(title: "RPM",
                          series: [TripLineSeries(id: "RPM", points: analysis.rpmSeries, color: TripPalette.rpm)],
                          playback: playback, fromZero: true, area: true) { s in
                s?.rpm.map { String(format: "%.0f rpm", $0) } ?? "—"
            }
        }
        if !analysis.throttleSeries.isEmpty {
            TripLineChart(title: "Bukaan gas",
                          series: [TripLineSeries(id: "Gas", points: analysis.throttleSeries, color: TripPalette.throttle)],
                          playback: playback, fromZero: true, area: true) { s in
                s?.throttle.map { String(format: "%.1f°", $0) } ?? "—"
            }
        }
        if !analysis.coolantSeries.isEmpty {
            TripLineChart(title: "Suhu",
                          series: [TripLineSeries(id: "Mesin", points: analysis.coolantSeries, color: TripPalette.coolant)]
                            + (analysis.intakeSeries.isEmpty ? [] :
                                [TripLineSeries(id: "Udara", points: analysis.intakeSeries, color: TripPalette.intake)]),
                          playback: playback) { s in
                guard let s else { return "—" }
                let c = s.coolant.map { String(format: "%.0f", $0) } ?? "—"
                let i = s.intake.map { String(format: "%.0f", $0) } ?? "—"
                return "\(c) / \(i) °C"
            }
        }
        if !analysis.batterySeries.isEmpty {
            TripLineChart(title: "Tegangan aki",
                          series: [TripLineSeries(id: "Aki", points: analysis.batterySeries, color: TripPalette.battery)],
                          playback: playback) { s in
                s?.battery.map { String(format: "%.2f V", $0) } ?? "—"
            }
        }
        if !analysis.altitudeSeries.isEmpty {
            TripLineChart(title: "Ketinggian (GPS)",
                          series: [TripLineSeries(id: "Alt", points: analysis.altitudeSeries, color: TripPalette.altitude)],
                          playback: playback, area: true) { s in
                s?.altitude.map { String(format: "%.0f m", $0) } ?? "—"
            }
        }
    }
}

// MARK: - Kurva CVT

/// Scatter RPM vs kecepatan. Aerox pakai CVT: di kecepatan rendah RPM naik
/// cepat sampai kopling sentrifugal "menggigit", lalu RPM cenderung tertahan
/// di satu pita sementara kecepatan terus naik (rasio CVT membesar). Warna
/// titik = bukaan gas.
struct TripCVTChart: View {
    let analysis: TripAnalysis
    let playback: TripPlayback

    private var maxThrottle: Double {
        analysis.cvtPoints.map(\.throttle).max() ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Kurva CVT")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                HStack(spacing: 6) {
                    Text("gas tutup")
                    Capsule()
                        .fill(LinearGradient(colors: [TripPalette.throttleColor(0, max: maxThrottle),
                                                      TripPalette.throttleColor(maxThrottle / 2, max: maxThrottle),
                                                      TripPalette.throttleColor(maxThrottle, max: maxThrottle)],
                                             startPoint: .leading, endPoint: .trailing))
                        .frame(width: 44, height: 5)
                    Text("buka")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Chart(analysis.cvtPoints) { p in
                PointMark(x: .value("Kecepatan", p.speed), y: .value("RPM", p.rpm))
                    .foregroundStyle(TripPalette.throttleColor(p.throttle, max: maxThrottle))
                    .symbolSize(18)
                    .opacity(0.75)
            }
            .chartXAxisLabel("km/h", alignment: .trailing)
            .chartYAxisLabel("rpm")
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel()
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel()
                }
            }
            .chartOverlay { proxy in
                TripScatterCursor(proxy: proxy, playback: playback)
            }
            .frame(height: 220)
            Text("Tiap titik = satu detik saat melaju. Titik putih = posisi kursor/replay. Pita datar di RPM tertentu menunjukkan CVT sedang \"menahan\" RPM sementara kecepatan naik.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct TripScatterCursor: View {
    let proxy: ChartProxy
    let playback: TripPlayback

    var body: some View {
        GeometryReader { geo in
            if let anchor = proxy.plotFrame, let s = playback.sample,
               let v = s.speed, let r = s.rpm, v > 0,
               let x = proxy.position(forX: v), let y = proxy.position(forY: r) {
                let plot = geo[anchor]
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 2))
                    .position(x: plot.minX + x, y: plot.minY + y)
                    .allowsHitTesting(false)
            }
        }
    }
}

// MARK: - Gaya berkendara

struct TripModeBreakdown: View {
    let analysis: TripAnalysis

    private var total: Double {
        analysis.modeSeconds.values.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Gaya berkendara")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(RidingMode.allCases) { m in
                        let secs = analysis.modeSeconds[m] ?? 0
                        if secs > 0 {
                            Rectangle()
                                .fill(TripPalette.modeColor(m))
                                .frame(width: max(2, (geo.size.width - 6) * secs / max(total, 1)))
                        }
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)
            ForEach(RidingMode.allCases) { m in
                let secs = analysis.modeSeconds[m] ?? 0
                HStack(spacing: 8) {
                    Circle().fill(TripPalette.modeColor(m)).frame(width: 8, height: 8)
                    Text(m.title)
                        .font(.caption)
                        .foregroundStyle(.white)
                    Spacer()
                    Text(RecordingFormat.duration(secs))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.0f%%", total > 0 ? secs / total * 100 : 0))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            Text("Akselerasi = gas dibuka & kecepatan naik ≥1 km/h/detik. Coasting = gas tertutup (<1°) tapi motor masih melaju.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Histogram

struct TripHistogramCard: View {
    let analysis: TripAnalysis
    @State private var metric = 0

    private var bins: [HistogramBin] {
        metric == 0 ? analysis.speedHistogram : analysis.rpmHistogram
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Distribusi waktu")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                Spacer()
                Picker("Metrik", selection: $metric) {
                    Text("Kecepatan").tag(0)
                    Text("RPM").tag(1)
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }
            Chart(bins) { b in
                BarMark(x: .value("Rentang", label(b)), y: .value("Menit", b.seconds / 60))
                    .foregroundStyle(metric == 0 ? TripPalette.ecu.gradient : TripPalette.rpm.gradient)
                    .cornerRadius(3)
            }
            .chartYAxisLabel("menit")
            .chartXAxis {
                AxisMarks { value in
                    AxisValueLabel {
                        if let s = value.as(String.self) {
                            Text(s).font(.system(size: 8))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                    AxisValueLabel()
                }
            }
            .frame(height: 160)
            Text(metric == 0 ? "Lama waktu di tiap rentang 10 km/h (hanya saat melaju)."
                             : "Lama waktu di tiap rentang 1.000 rpm (mesin hidup).")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private func label(_ b: HistogramBin) -> String {
        metric == 0 ? String(format: "%.0f", b.lower) : String(format: "%.0fk", b.lower / 1000)
    }
}

// MARK: - Kendaraan & catatan data

struct TripVehicleInfo: View {
    let analysis: TripAnalysis

    var body: some View {
        if let vin = analysis.vin { row("VIN", vin, mono: true) }
        if let m = analysis.modelCode { row("Kode model", m, mono: true) }
        if let n = analysis.ignOnCount { row("Kontak ON (total)", String(format: "%.0f×", n)) }
        if let h = analysis.ecuPowerOnHours { row("ECU total nyala", String(format: "%.0f jam", h)) }
        if analysis.maxFiError > 0 || analysis.maxDTC > 0 || analysis.fiLampOn {
            Label("ECU mencatat error selama rekaman (FI error \(Int(analysis.maxFiError)), DTC \(Int(analysis.maxDTC))\(analysis.fiLampOn ? ", lampu FI menyala" : "")). Cek di layar utama saat terhubung.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        } else if analysis.hasECU {
            Label("Tidak ada error FI / DTC selama rekaman.", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        }
    }

    private func row(_ title: String, _ value: String, mono: Bool = false) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(mono ? .body.monospaced() : .body.monospacedDigit())
                .foregroundStyle(.white)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

struct TripDataNotes: View {
    let analysis: TripAnalysis

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if analysis.rowsBeforeECU > 0 {
                note("\(analysis.rowsBeforeECU) baris awal belum ada data motor (masih menyambung) — hanya GPS yang dipakai.")
            }
            if analysis.rowsAfterKeyOff > 0 {
                note("\(analysis.rowsAfterKeyOff) baris setelah kunci kontak OFF (tegangan ~0 V) — nilai ECU di baris itu diabaikan.")
            }
            if analysis.gpsRejected > 0 {
                note("\(analysis.gpsRejected) titik GPS dibuang (akurasi > 30 m atau lompatan mustahil).")
            }
            if analysis.fuelMl != nil {
                note("ⓔ Estimasi BBM eksperimental: menjumlahkan injection_cc per detik dengan asumsi nilainya laju cc/detik. Belum dikalibrasi — bandingkan dengan pengisian full-to-full sebelum dipercaya.")
            }
            if analysis.speedoErrorPercent != nil {
                note("Selisih speedometer dihitung dari \(analysis.speedoErrorSamples) detik saat melaju ≥15 km/h dengan akurasi GPS ≤5 m.")
            }
        }
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}
