import SwiftUI

/// Komposisi editorial berukuran tetap untuk ImageRenderer, bukan layout layar.
/// Rute sudah dipotong untuk privasi oleh ShareCardContent; tidak memuat alamat/VIN.
struct RichRideShareCard: View {
    let content: ShareCardContent
    let format: ShareCardFormat
    let theme: ShareCardTheme
    let speedColors: Bool

    private var compact: Bool { format == .feed }

    private var metrics: [(String, String, String)] {
        var result: [(String, String, String)] = []
        if let value = content.maxSpeed { result.append(("KECEPATAN MAKS", value, "km/h")) }
        if let value = content.maxRPM { result.append(("RPM MAKS", value, "rpm")) }
        if let value = content.maxCoolant { result.append(("SUHU MAKS", value, "")) }
        if let value = content.elevationGain { result.append(("EST. TANJAKAN", "+" + value, "m")) }
        if let value = content.batteryMin { result.append(("AKI MIN · MESIN ON", value, "V")) }
        if let value = content.topMode { result.append(("MODE DOMINAN", value, "")) }
        return result
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: theme.colors, startPoint: .topLeading, endPoint: .bottomTrailing)
            // Grid kartografi tanpa basemap: tidak mengungkap nama jalan/lokasi.
            Canvas { context, size in
                var grid = Path()
                for x in stride(from: CGFloat(0), through: size.width, by: 24) {
                    grid.move(to: CGPoint(x: x, y: 0)); grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), through: size.height, by: 24) {
                    grid.move(to: CGPoint(x: 0, y: y)); grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(.white.opacity(0.045)), lineWidth: 0.5)
            }
            LinearGradient(colors: [.black.opacity(0.04), .black.opacity(0.6)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                header
                hero
                route
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .layoutPriority(-1)
                if !metrics.isEmpty { telemetry }
                if !compact, let fraction = content.movingFraction { movement(fraction) }
                if !compact, content.speedSeries.count > 1 { speedProfile }
                footer
            }
            .padding(.horizontal, 22)
            .padding(.vertical, compact ? 18 : 22)
        }
        .frame(width: format.size.width, height: format.size.height)
        .clipped()
        .environment(\.colorScheme, .dark)
        .environment(\.dynamicTypeSize, .medium)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text("AEROX / RIDE REPORT")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.8)
                Spacer()
                Image(systemName: "waveform.path.ecg").font(.system(size: 13))
            }
            .foregroundStyle(theme.glow)
            Text(content.title ?? "Every ride counts.")
                .font(.custom("AvenirNextCondensed-Heavy", size: compact ? 25 : 30))
                .foregroundStyle(.white)
                .lineLimit(compact ? 1 : 2)
                .minimumScaleFactor(0.7)
            Text(content.dateText)
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.65))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 16) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(content.distance ?? "—")
                    .font(.custom("AvenirNextCondensed-Heavy", size: compact ? 54 : 66))
                    .monospacedDigit()
                    .tracking(-2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text("km").font(.system(size: 14, weight: .medium))
                    .foregroundStyle(theme.glow)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 5) {
                Text(content.duration)
                    .font(.system(size: compact ? 19 : 22, weight: .semibold, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text("DURASI REKAMAN")
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(.white.opacity(0.55))
                if let speed = content.avgSpeed {
                    Text(speed + " saat jalan")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
            }
        }
        .foregroundStyle(.white)
        .frame(height: compact ? 54 : 68)
    }

    private var route: some View {
        VStack(spacing: 6) {
            HStack {
                Text(content.route.count > 1 ? "JEJAK PERJALANAN" : "PROFIL PERJALANAN")
                Spacer()
                if content.routeIsPrivate { Image(systemName: "lock.shield") }
            }
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .tracking(1)
            .foregroundStyle(.white.opacity(0.55))
            ZStack {
                RadialGradient(colors: [theme.glow.opacity(0.17), .clear], center: .center, startRadius: 0, endRadius: 140)
                if content.route.count > 1 {
                    RouteSilhouette(points: content.route, speedColors: speedColors, lineWidth: compact ? 3.2 : 4)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                } else if content.speedSeries.count > 1 {
                    SpeedSparkline(points: content.speedSeries, color: theme.glow, lineWidth: 2)
                        .padding(.vertical, 16)
                } else {
                    Text(content.routeIsPrivate ? "Rute disembunyikan untuk privasi" : "Rute GPS tidak tersedia")
                        .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                }
            }
            if content.routeIsPrivate {
                Text("200 m awal & akhir rute disembunyikan")
                    .font(.system(size: 7, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
    }

    private var telemetry: some View {
        VStack(spacing: compact ? 6 : 8) {
            Rectangle().fill(.white.opacity(0.2)).frame(height: 0.5)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                      alignment: .leading, spacing: compact ? 8 : 12) {
                ForEach(metrics.indices, id: \.self) { index in
                    let metric = metrics[index]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(metric.0)
                            .font(.system(size: 6.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                            .lineLimit(1).minimumScaleFactor(0.8)
                        HStack(alignment: .firstTextBaseline, spacing: 3) {
                            Text(metric.1)
                                .font(.custom("AvenirNextCondensed-DemiBold", size: compact ? 19 : 22))
                                .monospacedDigit()
                                .lineLimit(1).minimumScaleFactor(0.5)
                            if !metric.2.isEmpty {
                                Text(metric.2).font(.system(size: 8)).foregroundStyle(.white.opacity(0.65))
                            }
                        }
                        .foregroundStyle(.white)
                    }
                }
            }
        }
    }

    private func movement(_ fraction: Double) -> some View {
        VStack(spacing: 5) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle().fill(.white.opacity(0.15))
                    Rectangle().fill(theme.glow).frame(width: geometry.size.width * fraction)
                }
            }
            .frame(height: 3)
            HStack {
                Text("JALAN " + (content.movingTime ?? "—"))
                Spacer()
                Text("BERHENTI " + (content.stoppedTime ?? "—"))
            }
            .font(.system(size: 7, weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
        }
    }

    private var speedProfile: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("RITME KECEPATAN")
                .font(.system(size: 7, weight: .medium, design: .monospaced))
                .tracking(1).foregroundStyle(.white.opacity(0.5))
            SpeedSparkline(points: content.speedSeries, color: theme.glow, lineWidth: 1.3)
                .frame(height: 30)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let note = content.qualityNote {
                Text(note).font(.system(size: 7)).foregroundStyle(.white.opacity(0.65))
            }
            HStack(alignment: .firstTextBaseline) {
                Text("TelAerox").font(.custom("AvenirNextCondensed-Heavy", size: 16))
                Spacer()
                Text(content.sourceText)
                    .font(.system(size: 7, weight: .medium, design: .monospaced))
                    .tracking(1)
            }
            .foregroundStyle(.white.opacity(0.8))
        }
    }
}
