import SwiftUI
import MapKit

/// Layar navigasi full-screen untuk iPhone di holder: peta mengikuti arah
/// motor, petunjuk belok besar di atas, dan telemetri motor (kalau terhubung)
/// di bawah. Telemetri hanya dibaca dari `TelemetryStore`; layar ini tidak
/// mengirim apa pun ke motor.
struct RideNavigationView: View {
    @ObservedObject var store: TelemetryStore
    let accent: Color

    @StateObject private var nav = NavigationSession()
    @State private var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @FocusState private var searchFocused: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    var body: some View {
        ZStack {
            map
                .ignoresSafeArea()
        }
        .safeAreaInset(edge: .top, spacing: 0) { topPanel.padding(.horizontal, 12).padding(.top, 4) }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomPanel.padding(.horizontal, 12).padding(.bottom, 4) }
        .preferredColorScheme(.dark)
        .onAppear { nav.activate() }
        .onDisappear { nav.deactivate() }
        .onChange(of: nav.phase) { _, phase in
            switch phase {
            case .preview: showWholeRoute()
            case .navigating: followRider()
            default: break
            }
        }
    }

    // MARK: - Peta

    private var map: some View {
        Map(position: $camera) {
            UserAnnotation()
            if let route = nav.route {
                MapPolyline(route.polyline)
                    .stroke(accent, style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round))
            }
            if let dest = nav.destination {
                Marker(dest.name ?? "Tujuan", systemImage: "flag.checkered", coordinate: dest.location.coordinate)
                    .tint(.red)
            }
        }
        // Peta 2D (tanpa gedung 3D) lebih ringan untuk GPU = lebih hemat baterai.
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .including([.gasStation, .evCharger, .parking])))
        .mapControls {
            MapCompass()
            MapScaleView()
        }
    }

    private func followRider() {
        withAnimation { camera = .userLocation(followsHeading: true, fallback: .automatic) }
    }

    private func showWholeRoute() {
        guard let route = nav.route else { return }
        let rect = route.polyline.boundingMapRect
        let padded = rect.insetBy(dx: -rect.size.width * 0.25 - 500, dy: -rect.size.height * 0.35 - 500)
        withAnimation { camera = .rect(padded) }
    }

    // MARK: - Panel atas

    @ViewBuilder
    private var topPanel: some View {
        switch nav.phase {
        case .navigating, .arrived:
            VStack(spacing: 8) {
                maneuverBanner
                if nav.phase == .navigating, let rain = nav.rainOutlook { weatherChip(rain) }
            }
        default:
            searchPanel
        }
    }

    private var searchPanel: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Tutup navigasi")

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Mau ke mana?", text: $nav.query)
                        .focused($searchFocused)
                        .submitLabel(.search)
                        .autocorrectionDisabled()
                    if !nav.query.isEmpty {
                        Button { nav.query = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .accessibilityLabel("Hapus pencarian")
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 44)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.08)))
            }

            if !nav.suggestions.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(nav.suggestions.enumerated()), id: \.offset) { index, item in
                        Button {
                            searchFocused = false
                            nav.select(item)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "mappin.circle.fill").foregroundStyle(accent).font(.title3)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                                    if !item.subtitle.isEmpty {
                                        Text(item.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if index < nav.suggestions.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 12)
            }
        }
        .padding(10)
        .background(panelBackground)
    }

    private var maneuverBanner: some View {
        HStack(spacing: 14) {
            Image(systemName: nav.phase == .arrived ? "flag.checkered" : nav.nextManeuver.symbol)
                .font(.system(size: 44, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 64)
            VStack(alignment: .leading, spacing: 4) {
                if nav.phase == .arrived {
                    Text("Sudah sampai").font(.system(size: 30, weight: .bold, design: .rounded))
                } else {
                    Text(DistanceText.format(nav.distanceToManeuver))
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(nav.nextInstruction)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)
                    if let then = nav.thenInstruction {
                        Text("Lalu: \(then)").font(.footnote).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
                    }
                }
            }
            .foregroundStyle(.white)
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(accent.gradient))
        .overlay(alignment: .topTrailing) {
            if nav.isRerouting {
                Label("Mencari rute baru…", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(.black.opacity(0.5)))
                    .padding(8)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Panel bawah

    @ViewBuilder
    private var bottomPanel: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Spacer()
                if nav.phase == .navigating { googleMapsButton(compact: true) }
                if nav.phase == .navigating && !camera.followsUserLocation {
                    Button(action: followRider) {
                        Label("Ikuti", systemImage: "location.north.line.fill")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).frame(height: 44)
                            .background(Capsule().fill(.black.opacity(0.7)))
                    }
                    .foregroundStyle(.white)
                }
            }

            switch nav.phase {
            case .planning:
                if isLocationDenied { locationNotice }
            case .calculating:
                statusCard {
                    ProgressView().tint(.white)
                    Text("Menghitung rute…").font(.subheadline.weight(.medium))
                }
            case .preview:
                previewCard
            case .navigating:
                telemetryBar
            case .arrived:
                arrivedCard
            case .failed(let message):
                statusCard {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    VStack(spacing: 8) {
                        Button("Coba lagi") { nav.retry() }.buttonStyle(.borderedProminent).tint(accent)
                        if nav.destination != nil { googleMapsButton(compact: true) }
                    }
                }
            }
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(nav.destination?.name ?? "Tujuan")
                        .font(.headline).foregroundStyle(.white).lineLimit(2)
                    if let route = nav.route {
                        Text("\(DistanceText.format(route.distance)) · \(durationText(route.expectedTravelTime)) · tanpa tol")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button { nav.clearDestination() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Batalkan tujuan")
            }
            if let rain = nav.rainOutlook { weatherChip(rain) }
            HStack(spacing: 10) {
                voiceToggle
                Button {
                    nav.start()
                } label: {
                    Label("Mulai", systemImage: "location.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
            }
            HStack(alignment: .center) {
                Text("Waktu tempuh dari Apple Maps untuk mobil; motor bisa lebih cepat.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer(minLength: 8)
                googleMapsButton(compact: false)
            }
        }
        .padding(16)
        .background(panelBackground)
    }

    private var telemetryBar: some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(spacing: 0) {
                    Text(speedText)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)
                    Text(speedSource).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                .frame(minWidth: 90)

                if motorConnected {
                    gauge("RPM", value: live("rpm").map { String(format: "%.0f", $0) })
                    gauge("Mesin", value: live("coolant").map { String(format: "%.0f°", $0) },
                          warn: (live("coolant") ?? 0) >= 110)
                    gauge("Aki", value: live("battery").map { String(format: "%.1fV", $0) },
                          warn: (live("battery").map { $0 < 12 }) ?? false)
                } else {
                    Text("Motor belum terhubung — kecepatan dari GPS iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Divider()

            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(arrivalClock).font(.headline.monospacedDigit()).foregroundStyle(.white)
                    Text("\(DistanceText.format(nav.remainingDistance)) · \(durationText(nav.remainingTime))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                voiceToggle
                Button(role: .destructive) { nav.stop() } label: {
                    Text("Selesai").font(.headline).padding(.horizontal, 14).frame(height: 44)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            }
        }
        .padding(14)
        .background(panelBackground)
    }

    /// Prakiraan hujan dari Open-Meteo. Atribusi "Open-Meteo.com" wajib
    /// ditampilkan (lisensi data CC BY 4.0).
    private func weatherChip(_ rain: RainOutlook) -> some View {
        HStack(spacing: 10) {
            Image(systemName: rain.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text(rain.text(indonesian: true))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text("Cuaca: Open-Meteo.com · \(rain.fetchedAt.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 14)
            .fill(rain.isRain ? Color.orange.opacity(0.28) : Color.white.opacity(0.08)))
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.06, green: 0.09, blue: 0.14).opacity(0.9)))
        .accessibilityElement(children: .combine)
    }

    /// Buka tujuan yang sama di Google Maps mode motor (two-wheeler). Kalau app
    /// Google Maps terpasang, universal link ini langsung membukanya; kalau
    /// tidak, terbuka di browser.
    @ViewBuilder
    private func googleMapsButton(compact: Bool) -> some View {
        if let url = googleMapsURL {
            Button { openURL(url) } label: {
                Label(compact ? "G Maps" : "Google Maps", systemImage: "arrow.up.forward.app")
                    .font(compact ? .subheadline.weight(.semibold) : .caption.weight(.semibold))
                    .padding(.horizontal, 12).frame(height: compact ? 44 : 32)
                    .background(Capsule().fill(compact ? Color.black.opacity(0.7) : Color.white.opacity(0.1)))
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Buka rute di Google Maps")
        }
    }

    private var googleMapsURL: URL? {
        guard let c = nav.destination?.location.coordinate else { return nil }
        var comps = URLComponents(string: "https://www.google.com/maps/dir/")
        comps?.queryItems = [
            URLQueryItem(name: "api", value: "1"),
            URLQueryItem(name: "destination", value: String(format: "%.6f,%.6f", c.latitude, c.longitude)),
            URLQueryItem(name: "travelmode", value: "two-wheeler"),
            URLQueryItem(name: "dir_action", value: "navigate"),
        ]
        return comps?.url
    }

    /// Tombol suara on/off — besar dan berlabel supaya gampang ditekan pakai
    /// sarung tangan. Pilihan disimpan dan dipakai lagi di navigasi berikutnya.
    private var voiceToggle: some View {
        Button {
            nav.voiceEnabled.toggle()
        } label: {
            VStack(spacing: 2) {
                Image(systemName: nav.voiceEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.title3)
                Text(nav.voiceEnabled ? "Suara on" : "Suara off")
                    .font(.caption2.weight(.semibold))
            }
            .frame(width: 64, height: 50)
            .background(RoundedRectangle(cornerRadius: 12)
                .fill(nav.voiceEnabled ? accent.opacity(0.25) : Color.white.opacity(0.08)))
        }
        .foregroundStyle(nav.voiceEnabled ? .white : .secondary)
        .sensoryFeedback(.selection, trigger: nav.voiceEnabled)
        .accessibilityLabel("Suara navigasi")
        .accessibilityValue(nav.voiceEnabled ? "Nyala" : "Mati")
        .accessibilityHint("Ketuk dua kali untuk \(nav.voiceEnabled ? "mematikan" : "menyalakan") suara petunjuk arah")
    }

    private var arrivedCard: some View {
        statusCard {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title2)
            Text(nav.destination?.name ?? "Tujuan").font(.headline).frame(maxWidth: .infinity, alignment: .leading)
            Button("Selesai") { nav.stop() }.buttonStyle(.borderedProminent).tint(accent)
        }
    }

    private var locationNotice: some View {
        statusCard {
            Image(systemName: "location.slash.fill").foregroundStyle(.orange)
            Text("Izin lokasi ditolak. Aktifkan di Pengaturan › TelAerox › Lokasi untuk navigasi.")
                .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusCard<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 12, content: content)
            .foregroundStyle(.white)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(panelBackground)
    }

    private func gauge(_ title: String, value: String?, warn: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value ?? "--")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : (warn ? Color.orange : Color.white))
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: 20)
            .fill(Color(red: 0.06, green: 0.09, blue: 0.14).opacity(0.94))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }

    // MARK: - Data

    private var isLocationDenied: Bool {
        nav.authorizationStatus == .denied || nav.authorizationStatus == .restricted
    }

    private var motorConnected: Bool { store.isActive }

    /// Nilai telemetri yang masih segar (≤ 5 dt), aturan sama dengan Home.
    private func live(_ key: String) -> Double? {
        HomeTelemetry(snapshot: store.snapshot, isStreaming: store.isActive, now: Date()).value(key)
    }

    /// Kecepatan dari motor kalau tersedia, selain itu dari GPS iPhone.
    private var speedText: String {
        if let v = live("speed") { return String(format: "%.0f", v) }
        if let s = nav.location?.speed, s >= 0 { return String(format: "%.0f", s * 3.6) }
        return "--"
    }

    private var speedSource: String {
        live("speed") != nil ? "km/h · motor" : "km/h · GPS"
    }

    private var arrivalClock: String {
        Date().addingTimeInterval(nav.remainingTime).formatted(date: .omitted, time: .shortened)
    }

    private func durationText(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) mnt" }
        return "\(minutes / 60) j \(minutes % 60) mnt"
    }
}
