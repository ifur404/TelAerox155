import Foundation
import CoreLocation

/// Regression checks memakai data buatan; tidak membaca kredensial atau
/// menyentuh folder Documents. Dijalankan lewat Tests/run.sh.
@main
@MainActor
struct SensorRecordingChecks {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
        checks += 1
    }
    static func near(_ a: Double?, _ b: Double, _ message: String) {
        expect(a.map { abs($0 - b) < 0.001 } == true, message)
    }
    static func csv(_ rows: [[String: String]]) -> String {
        CSVCodec.row(SessionRecorder.csvColumns) + "\n" + rows.map { row in
            CSVCodec.row(SessionRecorder.csvColumns.map { row[$0] ?? "" })
        }.joined(separator: "\n")
    }
    static func row(_ t: Double, speed: Double? = nil, lat: Double? = nil,
                    altitude: Double? = nil, mounted: Bool = true) -> [String: String] {
        var r = ["elapsed_s": String(t), "ble_state": speed == nil ? "connecting" : "streaming",
                 "gps_status": lat == nil ? "waiting" : "active", "gps_age_s": "0",
                 "gps_accuracy_m": "3", "gps_vertical_accuracy_m": "3", "gps_speed_accuracy_mps": "0.5",
                 "gps_timestamp_iso": "fix-\(t)", "phone_placement": mounted ? "mounted" : "pocket",
                 "motion_status": "active", "motion_age_s": "0", "motion_samples": "50", "motion_span_s": "0.98",
                 "motion_peak_mps2": "10", "motion_vertical_peak_mps2": "9", "motion_vertical_rms_mps2": "1.5",
                 "phone_battery_pct": String(80 - t / 100), "phone_battery_state": "unplugged"]
        for key in SessionRecorder.ecuFields.map(\.key) { r["ecu_\(key)_age_s"] = "0" }
        if let speed {
            r["rpm"] = "3000"; r["speed_kmh"] = String(speed); r["battery_v"] = "14"
        }
        if let lat { r["gps_lat"] = String(lat); r["gps_lon"] = "106.8" }
        if let altitude {
            r["barometer_status"] = "active"; r["barometer_age_s"] = "0"
            r["barometer_timestamp_iso"] = "baro-\(t)"; r["phone_relative_alt_m"] = String(altitude)
        }
        return r
    }

    static func reading(_ time: Double, z: Double = 0) -> MotionReading {
        MotionReading(uptime: time, ax: 0, ay: 0, az: z, gx: 0, gy: 0, gz: -1,
                      rx: 0, ry: 0, rz: 0, roll: 0, pitch: 0, yaw: 0, qw: 1, qx: 0, qy: 0, qz: 0)
    }

    static func main() {
        var accumulator = MotionAccumulator()
        for i in 0..<50 { accumulator.append(reading(Double(i) / 50, z: i == 25 ? 10 : 0)) }
        let motion = accumulator.take(at: 1)!
        expect(motion.count == 50, "Agregasi mempertahankan semua 50 sampel")
        near(motion.peak, 10, "Puncak singkat tidak hilang pada CSV 1 Hz")
        near(motion.verticalPeak, 10, "Proyeksi gravitasi menghasilkan puncak vertikal")
        near(motion.verticalRMS, sqrt(2), "RMS tidak dirata-rata sebagai percepatan biasa")
        expect(accumulator.take(at: 1) == nil, "Jendela kosong tidak mengulang puncak lama")
        accumulator.append(reading(2, z: 99)); accumulator.append(reading(10, z: 1))
        near(accumulator.take(at: 10.1)?.peak, 1, "Suspend memutus jendela agregasi")
        accumulator.append(reading(20, z: 5))
        expect(accumulator.take(at: 23) == nil, "Gerakan basi dikosongkan")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var snapshot = TelemetrySnapshot()
        let rpm = DecodedValue(key: "rpm", name: "RPM", raw: 3000, value: 3000, unit: "rpm")
        let injection = DecodedValue(key: "injection", name: "Injeksi", raw: 1, value: 0.01, unit: "cc")
        snapshot.merge([rpm, injection], at: now.addingTimeInterval(-10))
        snapshot.merge([rpm], at: now)
        expect(snapshot.receivedAt["rpm"] == now, "Nilai sama tetap memperbarui timestamp")
        expect(snapshot.receivedAt["injection"] == now.addingTimeInterval(-10), "Usia field frame lain tidak ikut disegarkan")
        let location = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -6.2, longitude: 106.8),
                                  altitude: 20, horizontalAccuracy: 3, verticalAccuracy: -1,
                                  course: -1, courseAccuracy: -1, speed: -1, speedAccuracy: -1, timestamp: now)
        func export(_ state: String, location: CLLocation? = location, at date: Date = now) -> [String: String] {
            let text = SessionRecorder.csvRow(snapshot: snapshot, vin: "TEST,VIN", modelCode: "Model \"Test\"",
                                              location: location, bleState: state, phone: PhoneSensorSample(),
                                              gpsAuthorization: "always", gpsPrecise: true, appState: "foreground",
                                              at: date, startedAt: now)
            let fields = CSVCodec.fields(text)
            expect(fields.count == SessionRecorder.csvColumns.count, "Jumlah kolom header dan row sama")
            return Dictionary(uniqueKeysWithValues: zip(SessionRecorder.csvColumns, fields))
        }
        let current = export("streaming")
        expect(current["rpm"] == "3000.000", "ECU segar tetap diekspor")
        expect(current["injection_cc"] == "", "Field lama dari frame lain dikosongkan")
        expect(current["gps_alt_m"] == "" && current["gps_speed_kmh"] == "" && current["gps_course_deg"] == "", "Nilai lokasi invalid tidak menjadi nol / -1")
        expect(current["vin"] == "TEST,VIN" && current["modelCode"] == "Model \"Test\"", "CSV roundtrip metadata quoted")
        let disconnected = export("connecting")
        expect(disconnected["rpm"] == "" && disconnected["gps_lat"] != "", "iPhone tetap diekspor saat BLE putus")
        let stale = export("streaming", at: now.addingTimeInterval(10))
        expect(stale["gps_status"] == "stale" && stale["gps_lat"] == "" && stale["gps_age_s"] == "10.000", "GPS basi menyimpan usia tanpa posisi palsu")
        expect(CSVCodec.number(1.25) == "1.250", "Titik desimal konsisten")
        expect(CSVCodec.number(.nan) == "", "Nilai non-finite tidak diekspor")
        expect(Set(SessionRecorder.csvColumns).count == SessionRecorder.csvColumns.count, "Nama kolom unik")

        let legacy = TripAnalysis.parse("elapsed_s,rpm,speed_kmh,battery_v,gps_lat,gps_lon,gps_speed_kmh,gps_alt_m,gps_accuracy_m\n0,1000,0,14,-6.2,106.8,0,10,3\n1,3000,36,14,-6.1999,106.8,35,12,3")!
        expect(!legacy.hasPhoneColumns && !legacy.hasQualityColumns && legacy.hasRoute, "CSV lama tetap terbaca")
        near(legacy.maxSpeed, 36, "Statistik CSV lama tetap tersedia")

        var duplicateFix = row(1, lat: -6.2)
        duplicateFix["gps_timestamp_iso"] = "fix-0.0"
        let stationary = TripAnalysis.parse(csv([row(0, lat: -6.2), duplicateFix, row(2, lat: -6.2)]))!
        expect(stationary.samples.map(\.gpsFresh) == [true, false, true], "GPS baru saat diam dibedakan dari pengulangan fix")
        near(stationary.gpsDistanceKm, 0, "GPS diam tidak menambah jarak")
        expect(stationary.ecuCoverage == 0 && stationary.gpsCoverage == 100, "Sesi iPhone saja mempunyai kualitas yang benar")

        let interrupted = TripAnalysis.parse(csv([row(0, speed: 20), row(1, speed: 20), row(10, speed: 20)]))!
        near(interrupted.recordingGapSeconds, 8, "Jeda panjang tidak menjadi waktu berkendara")
        near(interrupted.movingSeconds, 3, "Waktu bergerak tidak mengisi gap")
        near(interrupted.ecuCoverage, 300.0 / 11, "Coverage memasukkan gap pada denominator")
        expect(interrupted.accelerationSeries.count == 1, "Tidak menghitung akselerasi melintasi gap")
        expect(interrupted.speedSeries.last?.segment != interrupted.speedSeries.first?.segment, "Grafik terputus pada gap")

        let maneuvers = TripAnalysis.parse(csv([row(0, speed: 0, lat: -6.2), row(1, speed: 36, lat: -6.1999), row(2, speed: 0, lat: -6.1998)]))!
        expect(maneuvers.events.contains { $0.kind == .acceleration }, "Akselerasi kuat terdeteksi")
        expect(maneuvers.events.contains { $0.kind == .braking }, "Perlambatan sampai berhenti terdeteksi")
        expect(maneuvers.events.filter { $0.kind == .bump }.count == 1, "Bump terdeteksi dan cooldown berlaku")
        let pocket = TripAnalysis.parse(csv([row(0, speed: 30, mounted: false), row(1, speed: 30, mounted: false)]))!
        expect(!pocket.events.contains { $0.kind == .bump }, "Gerakan saku tidak ditafsirkan sebagai guncangan motor")
        let heights = [0.0, 4, 8, 4, 0].enumerated().map { row(Double($0.offset), lat: -6.2 + Double($0.offset) * 0.0003, altitude: $0.element) }
        let elevation = TripAnalysis.parse(csv(heights))!
        near(elevation.altitudeGain, 8, "Barometer menjumlahkan naik")
        near(elevation.altitudeLoss, 8, "Barometer menjumlahkan turun")
        expect(elevation.elevationSource.hasPrefix("Barometer") && !elevation.elevationProfile.isEmpty, "Profil jarak memakai barometer jika tersedia")
        expect(!elevation.gradeSeries.isEmpty, "Kemiringan dihasilkan dari ruas minimal 100 m")
        let stops = TripAnalysis.parse(csv([row(0, speed: 0), row(1), row(100, speed: 0)]))!
        expect(stops.stops.isEmpty, "Stop tidak menjembatani data yang hilang")

        let longRows = (0..<9000).map { i in row(Double(i), speed: 30, lat: -6.2 + Double(i) * 0.00001) }
        let long = TripAnalysis.parse(csv(longRows))!
        expect(!long.routeSegments.isEmpty, "Downsampling rute panjang tidak menghapus semua garis")
        expect(long.route.count <= TripAnalysis.maxRoutePoints + 1, "Rute panjang dibatasi untuk UI")
        expect(long.motionPeakSeries.count <= TripAnalysis.maxChartPoints, "Seri sensor dibatasi untuk UI")
        expect(long.events.filter { $0.kind == .bump }.count == 900, "Cooldown kejadian per jenis konsisten")
        let gapRows = (Array(0..<10) + Array(50..<60)).map { i in row(Double(i), speed: 30, lat: -6.2 + Double(i) * 0.00001) }
        let routeGap = TripAnalysis.parse(csv(gapRows))!
        expect(Set(routeGap.route.map(\.segment)).count == 2, "Rute terpisah pada gap GPS")
        expect(routeGap.routeSegments.allSatisfy { Set($0.points.map(\.segment)).count == 1 }, "Polyline tidak menjembatani gap GPS")

        var badAge = row(0, speed: 30, lat: -6.2)
        badAge["ecu_speed_age_s"] = "10"; badAge["gps_age_s"] = "10"
        let filtered = TripAnalysis.parse(csv([badAge]))!
        expect(filtered.samples[0].speed == nil && !filtered.samples[0].hasGPS, "Parser menolak ECU/GPS basi walau nilai masih terisi")
        let fragmented = TripAnalysis.parse(csv((0..<2000).map { row(Double($0), speed: $0.isMultiple(of: 2) ? 30 : nil) }))!
        expect(fragmented.speedSeries.count <= TripAnalysis.maxChartPoints, "Ribuan ruas terputus tidak membuat grafik melampaui batas titik")

        print("Lulus \(checks) pemeriksaan regresi sensor, ekspor CSV, kompatibilitas, kualitas, event, elevasi, dan rute.")
    }
}
