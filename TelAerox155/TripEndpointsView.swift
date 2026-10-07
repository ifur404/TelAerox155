import SwiftUI
import MapKit

/// Alamat hanya untuk detail pribadi, tidak ditambahkan ke ekspor/kartu sosmed.
/// Cache hidup selama view ini terbuka; tidak menyimpan lokasi tambahan ke disk.
struct TripEndpointsView: View {
    let start: RoutePoint
    let finish: RoutePoint
    let startedAt: Date

    @State private var addresses: [String: String] = [:]
    @State private var loading = true
    @State private var attempt = 0
    @State private var request: MKReverseGeocodingRequest?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            endpoint(start, title: "Mulai", icon: "circle.fill", color: .green)
            Divider()
            endpoint(finish, title: "Selesai", icon: "flag.checkered", color: .white)

            if loading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Mencari alamat…").font(.caption).foregroundStyle(.secondary)
                }
            } else if addresses[key(start)] == nil || addresses[key(finish)] == nil {
                Text("Alamat belum tersedia. Koordinat tetap ditampilkan; coba lagi saat koneksi internet tersedia.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Coba cari alamat lagi") { attempt += 1 }
                    .font(.caption.weight(.semibold))
            }
            Text("Titik GPS valid pertama dan terakhir; bisa berbeda dari lokasi sebenarnya saat mulai/stop rekaman. Pencarian alamat mengirim koordinat ke Apple.")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .task(id: attempt) { await loadAddresses() }
        .onDisappear { request?.cancel() }
    }

    private func endpoint(_ point: RoutePoint, title: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(title).font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(startedAt.addingTimeInterval(point.t), format: .dateTime.hour().minute())
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Text(addresses[key(point)] ?? String(format: "%.5f, %.5f", point.lat, point.lon))
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }

    private func key(_ point: RoutePoint) -> String { "\(point.lat),\(point.lon)" }

    private func loadAddresses() async {
        loading = true
        defer { loading = false }
        // Maksimal dua request berurutan. Titik identik memakai hasil yang sama.
        for point in [start, finish] {
            guard !Task.isCancelled else { return }
            if addresses[key(point)] != nil { continue }
            guard let lookup = MKReverseGeocodingRequest(location: CLLocation(latitude: point.lat, longitude: point.lon)) else { continue }
            lookup.preferredLocale = Locale(identifier: "id_ID")
            request = lookup
            do {
                let items = try await lookup.mapItems
                guard !Task.isCancelled else { return }
                if let item = items.first {
                    // Pilih alamat singkat; jangan gunakan nama POI sebagai alamat.
                    let short = item.address?.shortAddress
                    let city = item.addressRepresentations?.cityName
                    let parts = [short, city].compactMap { value -> String? in
                        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
                        return value
                    }
                    var unique: [String] = []
                    for part in parts where !unique.contains(where: { $0.localizedCaseInsensitiveContains(part) }) {
                        unique.append(part)
                    }
                    if !unique.isEmpty { addresses[key(point)] = unique.joined(separator: ", ") }
                }
            } catch {
                // Tidak mencetak error/koordinat: lokasi perjalanan bersifat pribadi.
                if Task.isCancelled { return }
            }
            request = nil
        }
    }
}
