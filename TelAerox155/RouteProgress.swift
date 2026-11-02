import Foundation
import CoreLocation

/// Geometri rute yang sudah diratakan untuk menghitung progres pengendara.
/// Murni hitungan (tanpa MapKit/SwiftUI) supaya bisa diuji terpisah dan
/// dipanggil dari mana saja.
///
/// Konsep: semua titik polyline rute disambung jadi satu garis dengan jarak
/// kumulatif. Tiap langkah (step) rute punya jarak kumulatif di titik akhirnya
/// — di situlah manuver langkah berikutnya terjadi.
nonisolated struct RouteGeometry {
    let points: [CLLocationCoordinate2D]
    /// `cumulative[i]` = jarak (meter) dari awal rute sampai `points[i]`.
    let cumulative: [Double]
    /// Jarak kumulatif di akhir tiap step (indeks sejajar dengan step rute).
    let stepEnds: [Double]

    var totalDistance: Double { cumulative.last ?? 0 }

    /// - Parameter steps: koordinat polyline tiap step berurutan. Titik pertama
    ///   step yang sama dengan titik terakhir step sebelumnya digabung.
    init(steps: [[CLLocationCoordinate2D]]) {
        var pts: [CLLocationCoordinate2D] = []
        var cum: [Double] = []
        var ends: [Double] = []
        for step in steps {
            for c in step {
                if let last = pts.last {
                    let d = RouteGeometry.distance(last, c)
                    if d < 0.01 { continue }   // titik sambungan antar-step
                    pts.append(c)
                    cum.append((cum.last ?? 0) + d)
                } else {
                    pts.append(c)
                    cum.append(0)
                }
            }
            ends.append(cum.last ?? 0)
        }
        points = pts
        cumulative = cum
        stepEnds = ends
    }

    struct Match {
        /// Jarak sepanjang rute dari awal sampai titik terdekat (meter).
        let progress: Double
        /// Jarak tegak lurus pengendara ke garis rute (meter).
        let offset: Double
    }

    /// Proyeksikan lokasi ke garis rute. `minProgress` mencegah titik "loncat
    /// mundur" ke ruas yang lebih awal saat jalan pulang-pergi berdekatan.
    func match(_ location: CLLocationCoordinate2D, minProgress: Double = 0) -> Match? {
        guard points.count >= 2 else { return nil }
        var best: Match?
        for i in 0..<(points.count - 1) where cumulative[i + 1] >= minProgress {
            let (t, off) = RouteGeometry.project(location, points[i], points[i + 1])
            let segLen = cumulative[i + 1] - cumulative[i]
            let prog = cumulative[i] + segLen * t
            if best == nil || off < best!.offset {
                best = Match(progress: max(prog, minProgress), offset: off)
            }
        }
        return best
    }

    /// Koordinat di jarak tertentu sepanjang rute (dibatasi 0...total).
    func coordinate(at distance: Double) -> CLLocationCoordinate2D? {
        guard let first = points.first else { return nil }
        guard points.count >= 2 else { return first }
        let d = min(max(distance, 0), totalDistance)
        guard let i = cumulative.indices.dropFirst().first(where: { cumulative[$0] >= d }) else { return points.last }
        let segLen = cumulative[i] - cumulative[i - 1]
        let t = segLen > 0 ? (d - cumulative[i - 1]) / segLen : 0
        let a = points[i - 1], b = points[i]
        return CLLocationCoordinate2D(latitude: a.latitude + (b.latitude - a.latitude) * t,
                                      longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    /// Indeks step yang sedang dijalani untuk progres tertentu.
    func stepIndex(at progress: Double) -> Int {
        stepEnds.firstIndex { progress < $0 - 0.5 } ?? max(stepEnds.count - 1, 0)
    }

    // MARK: - Geometri lokal

    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        CLLocation(latitude: a.latitude, longitude: a.longitude)
            .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
    }

    /// Proyeksi titik `p` ke ruas `a→b` memakai pendekatan equirectangular —
    /// cukup akurat untuk ruas jalan pendek (puluhan sampai ratusan meter).
    /// Mengembalikan posisi relatif (0...1) dan jarak tegak lurus dalam meter.
    static func project(_ p: CLLocationCoordinate2D, _ a: CLLocationCoordinate2D,
                        _ b: CLLocationCoordinate2D) -> (Double, Double) {
        let mPerDegLat = 111_320.0
        let mPerDegLon = 111_320.0 * cos(a.latitude * .pi / 180)
        let bx = (b.longitude - a.longitude) * mPerDegLon
        let by = (b.latitude - a.latitude) * mPerDegLat
        let px = (p.longitude - a.longitude) * mPerDegLon
        let py = (p.latitude - a.latitude) * mPerDegLat
        let len2 = bx * bx + by * by
        let t = len2 > 0 ? min(max((px * bx + py * by) / len2, 0), 1) : 0
        let dx = px - bx * t
        let dy = py - by * t
        return (t, (dx * dx + dy * dy).squareRoot())
    }
}

/// Jenis manuver ditebak dari teks instruksi MapKit (MKRoute.Step tidak
/// mengekspos tipe manuver). Teks mengikuti bahasa perangkat, jadi kata kunci
/// Indonesia dan Inggris sama-sama dicek.
nonisolated enum ManeuverKind: Equatable {
    case left, slightLeft, right, slightRight, uTurn, roundabout, arrive, straight

    init(instruction: String) {
        let s = instruction.lowercased()
        func has(_ words: String...) -> Bool { words.contains { s.contains($0) } }
        if has("tiba", "tujuan", "arrive", "destination") { self = .arrive }
        else if has("putar balik", "u-turn", "u turn") { self = .uTurn }
        else if has("bundaran", "roundabout", "rotary") { self = .roundabout }
        else if has("sedikit ke kiri", "serong kiri", "keep left", "slight left", "tetap di kiri", "tetap di sebelah kiri", "bear left") { self = .slightLeft }
        else if has("sedikit ke kanan", "serong kanan", "keep right", "slight right", "tetap di kanan", "tetap di sebelah kanan", "bear right") { self = .slightRight }
        else if has("kiri", "left") { self = .left }
        else if has("kanan", "right") { self = .right }
        else { self = .straight }
    }

    var symbol: String {
        switch self {
        case .left: return "arrow.turn.up.left"
        case .slightLeft: return "arrow.up.left"
        case .right: return "arrow.turn.up.right"
        case .slightRight: return "arrow.up.right"
        case .uTurn: return "arrow.uturn.down"
        case .roundabout: return "arrow.triangle.turn.up.right.circle"
        case .arrive: return "flag.checkered"
        case .straight: return "arrow.up"
        }
    }
}

nonisolated enum DistanceText {
    static func format(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(rounded(meters)) m"
        }
        return String(format: "%.1f km", meters / 1000).replacingOccurrences(of: ".", with: ",")
    }

    /// Versi untuk diucapkan (tanpa singkatan), mengikuti bahasa suara.
    static func spoken(_ meters: Double, indonesian: Bool = true) -> String {
        if meters < 1000 {
            return indonesian ? "\(rounded(meters)) meter" : "\(rounded(meters)) meters"
        }
        let km = String(format: "%.1f", meters / 1000)
        return indonesian ? "\(km.replacingOccurrences(of: ".", with: " koma ")) kilometer" : "\(km) kilometers"
    }

    private static func rounded(_ meters: Double) -> Int {
        let r = meters < 100 ? (meters / 10).rounded() * 10 : (meters / 50).rounded() * 50
        return Int(max(r, 0))
    }
}

/// Kalimat suara navigasi. Instruksi belok dari MapKit mengikuti bahasa iPhone
/// (lihat CFBundleAllowMixedLocalizations di Info.plist), jadi kalimat
/// pembuka dan suara TTS ikut bahasa yang sama supaya tidak campur aduk.
nonisolated struct VoicePhrases {
    let indonesian: Bool

    static var current: VoicePhrases {
        let lang = Locale.preferredLanguages.first?.lowercased() ?? "id"
        return VoicePhrases(indonesian: lang.hasPrefix("id") || lang.hasPrefix("ms"))
    }

    /// Kode bahasa untuk AVSpeechSynthesisVoice.
    var voiceLanguage: String {
        indonesian ? "id-ID" : (Locale.preferredLanguages.first ?? "en-US")
    }

    func upcoming(_ meters: Double, _ instruction: String) -> String {
        indonesian ? "\(DistanceText.spoken(meters)) lagi, \(instruction)"
                   : "In \(DistanceText.spoken(meters, indonesian: false)), \(instruction)"
    }
    func start(_ meters: Double, _ instruction: String) -> String {
        let first = instruction.isEmpty ? "" : " " + upcoming(meters, instruction)
        return (indonesian ? "Mulai navigasi." : "Starting navigation.") + first
    }
    var continueText: String { indonesian ? "Lanjutkan" : "Continue" }
    var arriveText: String { indonesian ? "Tiba di tujuan" : "Arrive at destination" }
    var rerouted: String { indonesian ? "Rute diperbarui." : "Route updated." }
    var arrived: String { indonesian ? "Anda telah tiba di tujuan." : "You have arrived at your destination." }
}
