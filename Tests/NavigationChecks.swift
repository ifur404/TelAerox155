import Foundation
import CoreLocation

/// Regression checks hitungan progres rute navigasi (tanpa MapKit/jaringan).
/// Dijalankan lewat Tests/run.sh.
@main
struct NavigationChecks {
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }

    static func main() {
        // Dua step lurus ke utara di garis bujur yang sama, masing-masing ~111 m.
        let a = CLLocationCoordinate2D(latitude: -6.2000, longitude: 106.8000)
        let b = CLLocationCoordinate2D(latitude: -6.1990, longitude: 106.8000)
        let c = CLLocationCoordinate2D(latitude: -6.1980, longitude: 106.8000)
        let g = RouteGeometry(steps: [[a], [a, b], [b, c]])

        check(g.points.count == 3, "titik sambungan antar-step harus digabung")
        check(abs(g.totalDistance - 221) < 2, "total jarak sekitar 221 m")
        check(g.stepEnds.count == 3 && g.stepEnds[0] == 0, "step awal panjangnya nol")

        // Pengendara sedikit di timur titik tengah step kedua (~10 m dari garis).
        let rider = CLLocationCoordinate2D(latitude: -6.1995, longitude: 106.80009)
        let m = g.match(rider)!
        check(abs(m.progress - 55) < 2, "progres sekitar 55 m")
        check(abs(m.offset - 10) < 1.5, "offset sekitar 10 m")
        check(g.stepIndex(at: m.progress) == 1, "sedang di step kedua")
        check(g.stepIndex(at: 150) == 2, "lewat titik b masuk step ketiga")

        // minProgress mencegah progres mundur.
        let back = g.match(a, minProgress: 100)!
        check(back.progress >= 100, "progres tidak boleh mundur di bawah minProgress")

        check(ManeuverKind(instruction: "Belok kiri ke Jl. Sudirman") == .left, "kiri")
        check(ManeuverKind(instruction: "Turn right onto Main St") == .right, "right")
        check(ManeuverKind(instruction: "Di bundaran, ambil jalan keluar kedua") == .roundabout, "bundaran")
        check(ManeuverKind(instruction: "Tujuan ada di sebelah kiri") == .arrive, "tujuan")
        check(ManeuverKind(instruction: "Tetap di kanan di persimpangan") == .slightRight, "tetap kanan")

        check(DistanceText.format(437) == "450 m", "pembulatan 50 m")
        check(DistanceText.format(84) == "80 m", "pembulatan 10 m")
        check(DistanceText.format(2345) == "2,3 km", "km memakai koma")
        check(DistanceText.spoken(1500) == "1 koma 5 kilometer", "jarak diucapkan Indonesia")
        check(DistanceText.spoken(300, indonesian: false) == "300 meters", "jarak diucapkan Inggris")
        check(VoicePhrases(indonesian: false).upcoming(300, "Turn left") == "In 300 meters, Turn left", "kalimat Inggris")

        // Titik di tengah rute.
        let mid = g.coordinate(at: g.totalDistance / 2)!
        check(abs(mid.latitude - b.latitude) < 0.00002, "koordinat tengah rute di titik b")

        // Prakiraan hujan: objek tunggal dan array sama-sama terbaca.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t0 = now.timeIntervalSince1970 - 300
        func json(_ mm: [Double], prob: Double) -> String {
            let times = (0..<mm.count).map { String(Int(t0) + $0 * 900) }.joined(separator: ",")
            return #"{"minutely_15":{"time":[\#(times)],"precipitation":[\#(mm.map { String($0) }.joined(separator: ","))]},"hourly":{"time":[\#(Int(t0))],"precipitation_probability":[\#(prob)]}}"#
        }
        let points = RainForecast.checkpoints(geometry: g, progress: 0, remainingTime: 1800, now: now)
        check(points.count == 2 && points[0].place == .here && points[1].place == .destination,
              "rute pendek cukup cek lokasi sekarang dan tujuan")

        let dry = try! RainForecast.decode(Data("[\(json([0, 0, 0], prob: 10)),\(json([0, 0, 0], prob: 70))]".utf8))
        check(dry.count == 2, "respons array dua lokasi")
        check(RainForecast.outlook(points: points, series: dry, now: now).kind == .chance(70, .destination),
              "peluang hujan tinggi di tujuan")

        // Tujuan dicapai 30 menit lagi → slot ke-3 (t0 + 1800) berisi 1 mm/15 mnt = 4 mm/jam (sedang).
        let wet = try! RainForecast.decode(Data("[\(json([0, 0, 0], prob: 0)),\(json([0, 0, 1], prob: 90))]".utf8))
        if case .rainAhead(let level, let place, _) = RainForecast.outlook(points: points, series: wet, now: now).kind {
            check(level == .moderate && place == .destination, "hujan sedang di tujuan")
        } else {
            check(false, "harus terdeteksi hujan di depan")
        }
        let single = try! RainForecast.decode(Data(json([0.5], prob: 0).utf8))
        check(single.count == 1, "respons objek tunggal")
        check(RainForecast.outlook(points: [points[0]], series: single, now: now).kind == .rainingNow(.light),
              "sedang hujan ringan di lokasi")

        print("NavigationChecks OK")
    }
}
