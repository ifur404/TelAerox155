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
        print("NavigationChecks OK")
    }
}
