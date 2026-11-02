import Foundation
import CoreLocation

/// Prakiraan hujan di sepanjang rute dari Open-Meteo (https://open-meteo.com):
/// API open source, data CC BY 4.0, gratis untuk pemakaian non-komersial,
/// tanpa API key. Atribusi "Open-Meteo.com" wajib ditampilkan di UI.
///
/// Yang dikirim ke Open-Meteo hanya beberapa titik koordinat di rute,
/// dibulatkan ke 2 desimal (±1 km) supaya posisi persis tidak ikut terkirim.
/// Tidak ada data motor/BLE yang dikirim.
nonisolated enum RainLevel: Int, Comparable {
    case dry, light, moderate, heavy

    /// Ambang intensitas (mm/jam) mengikuti klasifikasi umum hujan.
    init(mmPerHour: Double) {
        switch mmPerHour {
        case ..<0.4: self = .dry
        case ..<2.5: self = .light
        case ..<7.6: self = .moderate
        default: self = .heavy
        }
    }

    static func < (a: RainLevel, b: RainLevel) -> Bool { a.rawValue < b.rawValue }

    var indonesian: String {
        switch self {
        case .dry: return "kering"
        case .light: return "ringan"
        case .moderate: return "sedang"
        case .heavy: return "lebat"
        }
    }

    var english: String {
        switch self {
        case .dry: return "dry"
        case .light: return "light"
        case .moderate: return "moderate"
        case .heavy: return "heavy"
        }
    }
}

/// Satu titik yang dicek di rute beserta perkiraan jam tibanya.
nonisolated struct RainCheckpoint {
    enum Place: Equatable { case here, along(km: Int), destination }
    let place: Place
    let coordinate: CLLocationCoordinate2D
    let eta: Date
}

/// Hasil akhir yang ditampilkan/diucapkan.
nonisolated struct RainOutlook: Equatable {
    enum Kind: Equatable {
        case rainingNow(RainLevel)
        case rainAhead(RainLevel, RainCheckpoint.Place, Date)
        case chance(Int, RainCheckpoint.Place)
        case dry
    }
    let kind: Kind
    let fetchedAt: Date

    var isRain: Bool {
        switch kind {
        case .rainingNow, .rainAhead: return true
        default: return false
        }
    }

    func text(indonesian: Bool) -> String {
        func place(_ p: RainCheckpoint.Place) -> String {
            switch p {
            case .here: return indonesian ? "lokasimu" : "your location"
            case .along(let km): return indonesian ? "km \(km) rute" : "km \(km) of the route"
            case .destination: return indonesian ? "tujuan" : "your destination"
            }
        }
        func clock(_ d: Date) -> String { d.formatted(date: .omitted, time: .shortened) }
        switch kind {
        case .rainingNow(let l):
            return indonesian ? "Sedang hujan \(l.indonesian) di lokasimu" : "\(l.english.capitalized) rain at your location"
        case .rainAhead(let l, let p, let t):
            return indonesian ? "Hujan \(l.indonesian) diperkirakan di \(place(p)) sekitar \(clock(t))"
                              : "\(l.english.capitalized) rain expected near \(place(p)) around \(clock(t))"
        case .chance(let pct, let p):
            return indonesian ? "Peluang hujan \(pct)% di \(place(p))" : "\(pct)% chance of rain near \(place(p))"
        case .dry:
            return indonesian ? "Rute diperkirakan tidak hujan" : "No rain expected along the route"
        }
    }

    var symbol: String {
        switch kind {
        case .rainingNow(let l), .rainAhead(let l, _, _):
            return l == .heavy ? "cloud.heavyrain.fill" : "cloud.rain.fill"
        case .chance: return "cloud.drizzle.fill"
        case .dry: return "sun.max.fill"
        }
    }
}

nonisolated enum RainForecast {

    /// Titik cek: posisi sekarang, 25/50/75% sisa rute, dan tujuan.
    static func checkpoints(geometry: RouteGeometry, progress: Double,
                            remainingTime: TimeInterval, now: Date) -> [RainCheckpoint] {
        let remaining = max(geometry.totalDistance - progress, 0)
        var result: [RainCheckpoint] = []
        for f in [0.0, 0.25, 0.5, 0.75, 1.0] {
            // Rute pendek (< 4 km) cukup awal dan akhir saja.
            if remaining < 4000 && f > 0 && f < 1 { continue }
            let d = progress + remaining * f
            guard let c = geometry.coordinate(at: d) else { continue }
            let place: RainCheckpoint.Place = f == 0 ? .here : (f == 1 ? .destination : .along(km: Int((d / 1000).rounded())))
            result.append(RainCheckpoint(place: place, coordinate: c, eta: now.addingTimeInterval(remainingTime * f)))
        }
        return result
    }

    static func url(for points: [RainCheckpoint]) -> URL? {
        func r(_ v: Double) -> String { String(format: "%.2f", v) }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        c?.queryItems = [
            URLQueryItem(name: "latitude", value: points.map { r($0.coordinate.latitude) }.joined(separator: ",")),
            URLQueryItem(name: "longitude", value: points.map { r($0.coordinate.longitude) }.joined(separator: ",")),
            URLQueryItem(name: "minutely_15", value: "precipitation"),
            URLQueryItem(name: "hourly", value: "precipitation_probability"),
            URLQueryItem(name: "past_minutely_15", value: "1"),
            URLQueryItem(name: "forecast_minutely_15", value: "24"),   // 6 jam ke depan
            URLQueryItem(name: "forecast_hours", value: "7"),
            URLQueryItem(name: "timeformat", value: "unixtime"),
            URLQueryItem(name: "timezone", value: "GMT"),
        ]
        return c?.url
    }

    nonisolated struct Series: Decodable {
        struct Minutely: Decodable { let time: [Double]; let precipitation: [Double?] }
        struct Hourly: Decodable { let time: [Double]; let precipitation_probability: [Double?] }
        let minutely_15: Minutely?
        let hourly: Hourly?
    }

    /// Open-Meteo membalas objek tunggal untuk satu lokasi, array untuk banyak.
    static func decode(_ data: Data) throws -> [Series] {
        let decoder = JSONDecoder()
        if let many = try? decoder.decode([Series].self, from: data) { return many }
        return [try decoder.decode(Series.self, from: data)]
    }

    /// Nilai pada slot waktu terakhir yang ≤ `date` (atau slot pertama).
    static func value<T>(at date: Date, times: [Double], values: [T?]) -> T? {
        let t = date.timeIntervalSince1970
        guard !times.isEmpty, times.count == values.count else { return nil }
        let i = times.lastIndex { $0 <= t } ?? 0
        return values[i]
    }

    static func outlook(points: [RainCheckpoint], series: [Series], now: Date) -> RainOutlook {
        var bestChance: (Int, RainCheckpoint.Place)?
        for (p, s) in zip(points, series) {
            var level = RainLevel.dry
            if let m = s.minutely_15, let mm = value(at: p.eta, times: m.time, values: m.precipitation) {
                level = RainLevel(mmPerHour: mm * 4)   // mm per 15 menit → mm/jam
            }
            if level > .dry {
                let kind: RainOutlook.Kind = p.place == .here ? .rainingNow(level) : .rainAhead(level, p.place, p.eta)
                return RainOutlook(kind: kind, fetchedAt: now)
            }
            if let h = s.hourly, let prob = value(at: p.eta, times: h.time, values: h.precipitation_probability) {
                let pct = Int(prob.rounded())
                if pct >= 60, pct > (bestChance?.0 ?? 0) { bestChance = (pct, p.place) }
            }
        }
        if let c = bestChance { return RainOutlook(kind: .chance(c.0, c.1), fetchedAt: now) }
        return RainOutlook(kind: .dry, fetchedAt: now)
    }

    static func fetch(points: [RainCheckpoint], now: Date = Date()) async throws -> RainOutlook {
        guard !points.isEmpty, let url = url(for: points) else { return RainOutlook(kind: .dry, fetchedAt: now) }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return outlook(points: points, series: try decode(data), now: now)
    }
}
