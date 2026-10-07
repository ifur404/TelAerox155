import SwiftUI
import UniformTypeIdentifiers
#if canImport(UIKit)
import UIKit
#endif

// Kartu sosmed: Story 9:16 (1080×1920), Feed 4:5 (1080×1350), atau
// stiker PNG transparan buat ditempel di atas foto sendiri (IG Story dsb).
//
// Privasi: rute digambar sebagai SILUET tanpa peta di belakangnya, dan secara
// default 200 m awal & akhir dipotong — titik start/finish sering = rumah
// atau kantor. VIN tidak pernah ditampilkan di kartu.

// MARK: - Opsi

enum ShareCardFormat: String, CaseIterable, Identifiable {
    case story, feed, sticker
    var id: String { rawValue }

    var title: String {
        switch self {
        case .story: return "Story 9:16"
        case .feed: return "Feed 4:5"
        case .sticker: return "Stiker"
        }
    }

    /// Ukuran logis (pt). Dirender dengan skala 3 → 1080×1920 / 1080×1350.
    var size: CGSize {
        switch self {
        case .story: return CGSize(width: 360, height: 640)
        case .feed, .sticker: return CGSize(width: 360, height: 450)
        }
    }
}

enum ShareCardTheme: String, CaseIterable, Identifiable {
    case malam, senja, racing
    var id: String { rawValue }

    var title: String {
        switch self {
        case .malam: return "Malam"
        case .senja: return "Senja"
        case .racing: return "Racing"
        }
    }

    var colors: [Color] {
        switch self {
        case .malam:
            return [Color(red: 0.03, green: 0.06, blue: 0.13), Color(red: 0.05, green: 0.16, blue: 0.30)]
        case .senja:
            return [Color(red: 0.16, green: 0.06, blue: 0.28), Color(red: 0.62, green: 0.20, blue: 0.30),
                    Color(red: 0.98, green: 0.55, blue: 0.25)]
        case .racing:
            return [Color(red: 0.02, green: 0.02, blue: 0.03), Color(red: 0.10, green: 0.04, blue: 0.05),
                    Color(red: 0.45, green: 0.04, blue: 0.08)]
        }
    }

    var glow: Color {
        switch self {
        case .malam: return Color(red: 0.25, green: 0.70, blue: 1.0)
        case .senja: return Color(red: 1.0, green: 0.65, blue: 0.35)
        case .racing: return Color(red: 1.0, green: 0.22, blue: 0.25)
        }
    }
}

// MARK: - Konten kartu

/// Semua teks & data yang tampil di kartu — disiapkan sekali dari
/// `TripAnalysis`, supaya view kartunya murni tampilan (juga dipakai
/// `ImageRenderer`).
struct ShareCardContent {
    let dateText: String
    let title: String?
    let route: [RoutePoint]
    let speedSeries: [ChartPoint]
    let distance: String?
    let duration: String
    let maxSpeed: String?
    let maxRPM: String?
    let avgSpeed: String?
    let maxCoolant: String?
    let topMode: String?
    let movingTime: String?
    let stoppedTime: String?
    let movingFraction: Double?
    let elevationGain: String?
    let batteryMin: String?
    let sourceText: String
    let routeIsPrivate: Bool
    let qualityNote: String?

    init(analysis a: TripAnalysis, session: RecordingSession, hideEnds: Bool) {
        dateText = session.startedAt.formatted(
            .dateTime.weekday(.wide).day().month(.abbreviated).year().hour().minute()
                .locale(Locale(identifier: "id_ID")))
        if let t = session.title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            title = t
        } else {
            title = nil
        }
        route = hideEnds ? TripAnalysis.trimmedForPrivacy(a.route, meters: 200) : a.route
        speedSeries = a.speedSeries.isEmpty ? a.gpsSpeedSeries : a.speedSeries
        routeIsPrivate = hideEnds && a.hasRoute
        sourceText = a.hasECU ? (a.hasRoute ? "ECU + GPS" : "TELEMETRI ECU") : (a.hasRoute ? "GPS iPHONE" : "DATA REKAMAN")
        qualityNote = (a.hasECU && a.ecuCoverage < 90) || (a.hasRoute && a.gpsCoverage < 90) || a.recordingGapSeconds > 0
            ? "Data tidak lengkap · statistik dari sampel tersedia" : nil
        let movingTotal = a.movingSeconds + a.stoppedSeconds
        movingTime = movingTotal > 0 ? RecordingFormat.clock(a.movingSeconds) : nil
        stoppedTime = movingTotal > 0 ? RecordingFormat.clock(a.stoppedSeconds) : nil
        movingFraction = movingTotal > 0 ? min(1, max(0, a.movingSeconds / movingTotal)) : nil
        elevationGain = a.altitudeGain.map { String(format: "%.0f", $0) }
        batteryMin = a.batteryMin.map { String(format: "%.2f", $0) }

        let km = a.gpsDistanceKm ?? a.odometerDistanceKm
        distance = km.map { String(format: $0 < 10 ? "%.2f" : "%.1f", $0) }
        duration = RecordingFormat.clock(session.duration ?? a.duration)
        maxSpeed = a.maxSpeed.map { String(format: "%.0f", $0) }
        maxRPM = a.maxRPM.map { Int($0).formatted(.number.locale(Locale(identifier: "id_ID"))) }
        avgSpeed = a.avgMovingSpeed.map { String(format: "Ø %.0f km/h", $0) }
        maxCoolant = a.coolantMax.map { String(format: "%.0f °C", $0) }

        let moving = a.modeSeconds.filter { $0.key != .idle }
        let total = a.modeSeconds.values.reduce(0, +)
        if let top = moving.max(by: { $0.value < $1.value }), total > 0 {
            let name = top.key == .coasting ? "Coasting" : top.key.title
            topMode = String(format: "%@ %.0f%%", name, top.value / total * 100)
        } else {
            topMode = nil
        }
    }
}

// MARK: - Kartu

struct TripShareCard: View {
    let content: ShareCardContent
    let format: ShareCardFormat
    let theme: ShareCardTheme
    /// true = rute diwarnai kecepatan, false = putih polos.
    let speedColors: Bool

    var body: some View {
        switch format {
        case .story, .feed:
            RichRideShareCard(content: content, format: format, theme: theme, speedColors: speedColors)
        case .sticker: sticker
        }
    }

    // MARK: Stiker

    /// Tanpa latar — teks putih dengan bayangan supaya tetap terbaca di atas
    /// foto terang maupun gelap.
    private var sticker: some View {
        VStack(spacing: 14) {
            if content.route.count > 1 {
                RouteSilhouette(points: content.route, speedColors: speedColors, lineWidth: 6)
                    .frame(height: 270)
            } else {
                SpeedSparkline(points: content.speedSeries, color: .white, lineWidth: 4)
                    .frame(height: 140)
            }
            HStack(alignment: .top, spacing: 0) {
                stickerStat(content.distance ?? "—", unit: "km")
                stickerStat(content.duration, unit: "waktu")
                stickerStat(content.maxSpeed ?? "—", unit: "km/h maks")
            }
            Text("AEROX 155 · TelAerox")
                .font(.system(size: 10, weight: .heavy))
                .tracking(2)
                .foregroundStyle(.white.opacity(0.9))
        }
        .shadow(color: .black.opacity(0.55), radius: 4, y: 1)
        .padding(20)
        .frame(width: format.size.width, height: format.size.height)
    }

    private func stickerStat(_ value: String, unit: String) -> some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 30, weight: .heavy, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(unit.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(1)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Siluet rute & sparkline

/// Rute digambar tanpa peta: proyeksi equirectangular sederhana (cukup akurat
/// untuk skala kota), dipas ke kotak dengan rasio aspek dipertahankan.
/// Canvas (bukan Map) supaya bisa dirender `ImageRenderer`.
struct RouteSilhouette: View {
    let points: [RoutePoint]
    let speedColors: Bool
    var lineWidth: CGFloat = 5

    var body: some View {
        Canvas { ctx, size in
            let pts = project(in: size)
            guard pts.count > 1 else { return }
            let style = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)

            var full = Path()
            for i in pts.indices {
                if i == 0 || points[i].segment != points[i - 1].segment {
                    full.move(to: pts[i])
                } else {
                    full.addLine(to: pts[i])
                }
            }
            // Glow tipis di bawah garis utama.
            ctx.stroke(full, with: .color(.white.opacity(0.14)),
                       style: StrokeStyle(lineWidth: lineWidth * 3, lineCap: .round, lineJoin: .round))

            if speedColors {
                for i in 1..<pts.count where points[i].segment == points[i - 1].segment {
                    var seg = Path()
                    seg.move(to: pts[i - 1])
                    seg.addLine(to: pts[i])
                    ctx.stroke(seg, with: .color(TripPalette.speedColor(level: points[i].level)), style: style)
                }
            } else {
                ctx.stroke(full, with: .color(.white), style: style)
            }

            let r = lineWidth * 1.3
            if let s = pts.first {
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - r, y: s.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white))
                let inner = r * 0.5
                ctx.fill(Path(ellipseIn: CGRect(x: s.x - inner, y: s.y - inner, width: inner * 2, height: inner * 2)),
                         with: .color(.black.opacity(0.8)))
            }
            if let e = pts.last {
                ctx.fill(Path(ellipseIn: CGRect(x: e.x - r, y: e.y - r, width: r * 2, height: r * 2)),
                         with: .color(.white))
            }
        }
    }

    private func project(in size: CGSize) -> [CGPoint] {
        guard let first = points.first else { return [] }
        let k = cos(first.lat * .pi / 180)
        let xs = points.map { $0.lon * k }, ys = points.map { -$0.lat }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return [] }
        let pad = lineWidth * 2
        let w = max(1, size.width - pad * 2), h = max(1, size.height - pad * 2)
        let bw = max(maxX - minX, 1e-9), bh = max(maxY - minY, 1e-9)
        let scale = min(w / bw, h / bh)
        let ox = pad + (w - bw * scale) / 2, oy = pad + (h - bh * scale) / 2
        return zip(xs, ys).map { CGPoint(x: ox + ($0 - minX) * scale, y: oy + ($1 - minY) * scale) }
    }
}

struct SpeedSparkline: View {
    let points: [ChartPoint]
    let color: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { ctx, size in
            guard points.count > 1, let t0 = points.first?.t, let t1 = points.last?.t, t1 > t0 else { return }
            let vmax = max(points.map(\.v).max() ?? 1, 1)
            let pts = points.map { p in
                CGPoint(x: (p.t - t0) / (t1 - t0) * size.width,
                        y: size.height - p.v / vmax * (size.height - lineWidth) - lineWidth / 2)
            }
            // Jangan menggambar garis/area melintasi jeda data.
            let groups = Dictionary(grouping: points.indices, by: { points[$0].segment })
            for indices in groups.values {
                let segment = indices.map { pts[$0] }
                guard segment.count > 1, let first = segment.first, let last = segment.last else { continue }
                var line = Path()
                line.addLines(segment)
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: size.height))
                area.addLine(to: CGPoint(x: first.x, y: size.height))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(Gradient(colors: [color.opacity(0.35), color.opacity(0)]),
                                                     startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(color),
                           style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            }
        }
    }
}

// MARK: - Sheet pembuat kartu

struct TripShareCardSheet: View {
    let analysis: TripAnalysis
    let session: RecordingSession
    let accent: Color
    @Environment(\.dismiss) private var dismiss

    @AppStorage("shareCardFormat") private var formatRaw = ShareCardFormat.story.rawValue
    @AppStorage("shareCardTheme") private var themeRaw = ShareCardTheme.malam.rawValue
    @AppStorage("shareCardHideEnds") private var hideEnds = true
    @AppStorage("shareCardSpeedColors") private var speedColors = true
    @State private var shareURL: URL?
    @State private var copied = false
    @State private var renderFailed = false

    private var format: ShareCardFormat { ShareCardFormat(rawValue: formatRaw) ?? .story }
    private var theme: ShareCardTheme { ShareCardTheme(rawValue: themeRaw) ?? .malam }

    private var card: TripShareCard {
        TripShareCard(content: ShareCardContent(analysis: analysis, session: session, hideEnds: hideEnds),
                      format: format, theme: theme, speedColors: speedColors)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    preview

                    Picker("Format", selection: $formatRaw) {
                        ForEach(ShareCardFormat.allCases) { f in
                            Text(f.title).tag(f.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(spacing: 0) {
                        if format != .sticker {
                            HStack {
                                Text("Tema")
                                Spacer()
                                ForEach(ShareCardTheme.allCases) { t in
                                    Button { themeRaw = t.rawValue } label: {
                                        Circle()
                                            .fill(LinearGradient(colors: t.colors, startPoint: .top, endPoint: .bottom))
                                            .frame(width: 30, height: 30)
                                            .overlay(Circle().stroke(t == theme ? accent : Color.white.opacity(0.2),
                                                                     lineWidth: t == theme ? 2.5 : 1))
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("Tema \(t.title)")
                                }
                            }
                            .padding(.vertical, 10)
                            Divider()
                        }
                        Toggle("Rute berwarna kecepatan", isOn: $speedColors)
                            .padding(.vertical, 10)
                        Divider()
                        Toggle(isOn: $hideEnds) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Sembunyikan awal & akhir rute")
                                Text("Potong 200 m pertama & terakhir. Bentuk rute tetap bisa dikenali; periksa pratinjau sebelum berbagi.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 10)
                    }
                    .padding(.horizontal, 14)
                    .background(RecordingPalette.card, in: RoundedRectangle(cornerRadius: 14))
                    .tint(accent)

                    Button { share() } label: {
                        Label("Bagikan / Simpan Gambar", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.black)
                            .background(accent, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)

                    if format == .sticker {
                        Button { copySticker() } label: {
                            Label(copied ? "Tersalin!" : "Salin Stiker", systemImage: copied ? "checkmark" : "doc.on.doc")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(.white)
                                .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.plain)
                        Text("Salin, lalu buka IG Story dengan foto motormu dan pilih Tempel — stiker muncul di atas foto dengan latar transparan.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(16)
            }
            .background(RecordingPalette.background.ignoresSafeArea())
            .navigationTitle("Kartu Sosmed")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Tutup") { dismiss() }
                }
            }
            .sheet(item: Binding(get: { shareURL.map(ShareItem.init) },
                                 set: { shareURL = $0?.url })) { item in
                ActivityShareSheet(activityItems: [item.url])
            }
            .alert("Gagal membuat gambar", isPresented: $renderFailed) {
                Button("OK", role: .cancel) {}
            }
        }
        .preferredColorScheme(.dark)
    }

    /// Pratinjau diperkecil dari ukuran asli kartu. Stiker ditampilkan di
    /// atas pola kotak-kotak supaya kelihatan latarnya transparan.
    private var preview: some View {
        let size = format.size
        let scale: CGFloat = format == .story ? 0.72 : 0.85
        return card
            .scaleEffect(scale)
            .frame(width: size.width * scale, height: size.height * scale)
            .background {
                if format == .sticker { Checkerboard() }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
            .frame(maxWidth: .infinity)
    }

    // MARK: Render

    private func renderPNG() -> Data? {
        let renderer = ImageRenderer(content: card.environment(\.colorScheme, .dark))
        renderer.scale = 3
        renderer.isOpaque = format != .sticker
        #if canImport(UIKit)
        return renderer.uiImage?.pngData()
        #else
        return nil
        #endif
    }

    private func share() {
        guard let png = renderPNG() else { renderFailed = true; return }
        // File PNG (bukan UIImage) supaya transparansi stiker tetap utuh
        // saat disimpan ke Foto / dikirim.
        let name = "TelAerox-\(format.rawValue)-\(Int(session.startedAt.timeIntervalSince1970)).png"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try png.write(to: url, options: .atomic)
            shareURL = url
        } catch {
            renderFailed = true
        }
    }

    private func copySticker() {
        guard let png = renderPNG() else { renderFailed = true; return }
        #if canImport(UIKit)
        UIPasteboard.general.setData(png, forPasteboardType: UTType.png.identifier)
        #endif
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for row in 0..<Int(size.height / s) + 1 {
                for col in 0..<Int(size.width / s) + 1 where (row + col).isMultiple(of: 2) {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * s, y: CGFloat(row) * s, width: s, height: s)),
                             with: .color(.white.opacity(0.08)))
                }
            }
        }
        .background(Color(white: 0.18))
    }
}
