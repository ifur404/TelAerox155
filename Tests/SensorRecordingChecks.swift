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
        checkBackgroundRecording()
        checkWorkScheduling()
        let tripColumns = SessionRecorder.columns(includingMotionAndBarometer: false)
        expect(tripColumns.filter { $0.hasPrefix("gps_") } == SessionRecorder.csvColumns.filter { $0.hasPrefix("gps_") },
               "Semua kolom GPS tetap tersedia saat gerakan/barometer mati")
        expect(!tripColumns.contains("motion_status") && !tripColumns.contains("gyro_x_radps")
               && !tripColumns.contains("attitude_qw") && !tripColumns.contains("phone_pressure_kpa")
               && !tripColumns.contains("barometer_status") && !tripColumns.contains("phone_placement"),
               "Kolom gerakan, orientasi, barometer, dan pemasangan mengikuti toggle")
        expect(tripColumns.contains("phone_battery_pct"), "Status perangkat tidak bergantung pada sensor gerakan")
        expect(SessionRecorder.columns(includingMotionAndBarometer: true) == SessionRecorder.csvColumns,
               "Toggle aktif mempertahankan semua kolom sensor")
        let tripCSV = CSVCodec.row(tripColumns) + "\n" + [row(0, speed: 20, lat: -6.2), row(1, speed: 25, lat: -6.1999)].map { r in
            CSVCodec.row(tripColumns.map { r[$0] ?? "" })
        }.joined(separator: "\n")
        let basicTrip = TripAnalysis.parse(tripCSV)!
        expect(!basicTrip.hasPhoneColumns && basicTrip.hasRoute, "Rute GPS tetap tersedia tanpa gerakan/barometer")
        expect(basicTrip.maxSpeed == 25, "Telemetri tetap terbaca tanpa gerakan/barometer")
        expect(!basicTrip.gaps.contains { $0.kind == .gps || $0.kind == .motion }, "GPS terisi dan sensor nonaktif tidak dianggap jeda")
        let motorOnly = TripAnalysis.parse("elapsed_s,rpm,speed_kmh\n0,3000,20\n1,3000,25")!
        expect(!motorOnly.hasRoute && motorOnly.maxSpeed == 25, "CSV motor saja dari versi lama tetap terbaca")

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
        let liveHome = HomeTelemetry(snapshot: snapshot, isStreaming: true, now: now)
        near(liveHome.value("rpm"), 3000, "Home menampilkan RPM segar")
        expect(liveHome.value("injection") == nil, "Home tidak menampilkan sensor basi sebagai live")
        expect(liveHome.value("speed") == nil && liveHome.missingPrimaryData, "Kecepatan kosong bukan nol")
        expect(HomeTelemetry(snapshot: snapshot, isStreaming: false, now: now).value("rpm") == nil,
               "Home tidak menampilkan snapshot sesi yang tidak streaming")
        expect(HomeTelemetry(snapshot: snapshot, isStreaming: true, now: now.addingTimeInterval(6)).value("rpm") == nil,
               "Nilai Home kedaluwarsa meski tidak ada frame berikutnya")
        expect(!liveHome.hasCompleteDiagnostics && !liveHome.hasDiagnosticWarning, "Diagnostik kosong tidak berarti bebas error")
        var homeSnapshot = TelemetrySnapshot()
        func homeField(_ key: String, _ value: Double) -> DecodedValue {
            DecodedValue(key: key, name: key, raw: value, value: value, unit: "")
        }
        homeSnapshot.merge([homeField("fiError", 0), homeField("dtc", 0), homeField("fiWarningLamp", 0),
                            homeField("ecuPowerOnTime", 86400)], at: now)
        let clearHome = HomeTelemetry(snapshot: homeSnapshot, isStreaming: true, now: now)
        expect(clearHome.hasCompleteDiagnostics && !clearHome.hasDiagnosticWarning, "Tiga nilai diagnostik nol yang segar tersedia")
        let staleHome = HomeTelemetry(snapshot: homeSnapshot, isStreaming: true, now: now.addingTimeInterval(6))
        expect(!staleHome.hasCompleteDiagnostics, "Diagnostik Home basi tidak dianggap normal")
        near(staleHome.value("ecuPowerOnTime"), 86400, "Counter non-streaming tetap tersedia dalam sesi")
        homeSnapshot.merge([homeField("dtc", 3)], at: now.addingTimeInterval(6))
        let warningHome = HomeTelemetry(snapshot: homeSnapshot, isStreaming: true, now: now.addingTimeInterval(6))
        expect(warningHome.hasDiagnosticWarning && !warningHome.hasCompleteDiagnostics, "Error segar tetap diperingatkan meski diagnostik lain basi")
        homeSnapshot.merge([homeField("speed", .nan)], at: now)
        expect(HomeTelemetry(snapshot: homeSnapshot, isStreaming: true, now: now).value("speed") == nil,
               "Home menolak nilai non-finite")

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
        expect(!legacy.hasDiagnosticData, "CSV tanpa kolom diagnostik tidak berarti bebas error")
        expect(!motorOnly.hasDiagnosticData, "Kolom diagnostik kosong tidak dianggap sebagai pembacaan nol")

        var diagnostic = row(0, speed: 20)
        diagnostic["fiError"] = "0"; diagnostic["dtc"] = "0"; diagnostic["fiWarningLamp"] = "0"
        let clearDiagnostics = TripAnalysis.parse(csv([diagnostic]))!
        expect(clearDiagnostics.hasDiagnosticData && clearDiagnostics.maxFiError == 0
               && clearDiagnostics.maxDTC == 0 && !clearDiagnostics.fiLampOn,
               "Pembacaan diagnostik nol yang valid dibedakan dari data kosong")
        diagnostic["fiError"] = "12"; diagnostic["dtc"] = "3"; diagnostic["fiWarningLamp"] = "1"
        let errors = TripAnalysis.parse(csv([diagnostic]))!
        expect(errors.hasDiagnosticData && errors.maxFiError == 12 && errors.maxDTC == 3 && errors.fiLampOn,
               "Error dan lampu FI tetap terdeteksi")
        for key in ["fiError", "dtc", "fiWarningLamp"] { diagnostic["ecu_\(key)_age_s"] = "100" }
        let staleDiagnostics = TripAnalysis.parse(csv([diagnostic]))!
        expect(!staleDiagnostics.hasDiagnosticData && !staleDiagnostics.fiLampOn && staleDiagnostics.maxDTC == 0,
               "Diagnostik basi tidak menjadi status kendaraan")
        for key in ["fiError", "dtc", "fiWarningLamp"] {
            diagnostic["ecu_\(key)_age_s"] = "0"
            diagnostic[key] = "-1"
        }
        expect(!TripAnalysis.parse(csv([diagnostic]))!.hasDiagnosticData, "Nilai diagnostik negatif ditolak")
        diagnostic["fiError"] = "0"; diagnostic["ble_state"] = "connecting"
        expect(!TripAnalysis.parse(csv([diagnostic]))!.hasDiagnosticData, "Diagnostik saat BLE tidak streaming diabaikan")

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

        print("Lulus \(checks) pemeriksaan regresi background, sensor, CSV, kualitas, event, elevasi, dan rute.")
    }

    static func checkBackgroundRecording() {
        var full = KeepAliveSchedule()
        expect(full.next(at: 10, policy: .full) == .clock, "Full mulai dengan 058A")
        expect(full.next(at: 10, policy: .full) == nil, "RX dan timer bersamaan tidak menggandakan frame")
        expect(full.next(at: 10.099, policy: .full) == nil, "058B tidak mendahului jarak 100 ms")
        expect(full.next(at: 10.1, policy: .full) == .notification, "058B menyusul 100 ms")
        expect(full.next(at: 10.99, policy: .full) == nil, "058A berikutnya menunggu satu siklus")
        expect(full.next(at: 11.001, policy: .full) == .clock, "Siklus normal tetap 1 Hz")
        expect(full.next(at: 90, policy: .full) == .notification, "Callback RX melanjutkan pasangan setelah suspend")
        expect(full.next(at: 90, policy: .full) == nil, "Tidak mengirim backlog setelah suspend")
        expect(full.next(at: 90.899, policy: .full) == nil, "Pasangan terlambat tidak disusul burst")
        expect(full.next(at: 90.901, policy: .full) == .clock, "Cadence pulih setelah suspend")
        full = KeepAliveSchedule()
        expect(full.next(at: 91, policy: .full) == .clock, "Reconnect menghapus pasangan tertunda")

        var notify = KeepAliveSchedule()
        expect(notify.next(at: 0, policy: .off) == nil && notify.deadline == nil, "Policy off tidak menghasilkan write")
        expect(notify.next(at: 0, policy: .notifyOnly) == .notification, "Notify-only tidak mengirim 058A")
        for tick in 1..<100 {
            expect(notify.next(at: Double(tick) / 100, policy: .notifyOnly) == nil,
                   "Callback rapat tidak mempercepat keep-alive")
        }
        expect(notify.next(at: 1, policy: .notifyOnly) == .notification, "Notify-only tepat 1 Hz")
        expect(notify.next(at: 300, policy: .notifyOnly) == .notification, "Timer hilang digantikan callback RX")
        expect(notify.next(at: 300, policy: .notifyOnly) == nil, "Timer terlambat tidak mengirim ulang")

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("telaerox-recording-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = SessionRecorder(library: RecordingLibrary(directory: directory))
        let gpsFix = CLLocation(coordinate: CLLocationCoordinate2D(latitude: -6.2, longitude: 106.8),
                                altitude: 20, horizontalAccuracy: 3, verticalAccuracy: 4,
                                timestamp: Date())
        var events: [Bool] = []
        recorder.onRecordingChanged = { [weak recorder] active in
            guard let recorder else { preconditionFailure("Recorder hilang saat callback") }
            events.append(active)
            expect(recorder.isRecording == active, "Callback melihat state yang sudah diterapkan")
            if active {
                expect(!recorder.includesMotionAndBarometer, "Opsi sensor sudah siap sebelum callback start")
                expect(recorder.library.sessions.first?.endedAt == nil, "Indeks sesi siap sebelum callback")
                if recorder.format == .csv {
                    let text = try! String(contentsOf: recorder.fileURL!, encoding: .utf8)
                    expect(text.hasPrefix("timestamp_iso,") && text.contains("gps_lat") && !text.contains("motion_status"),
                           "Header lengkap sebelum GPS dan sampling pertama dimulai")
                    recorder.appendCSVRow(snapshot: TelemetrySnapshot(), vin: nil, modelCode: nil,
                        location: gpsFix, bleState: "connecting", phone: PhoneSensorSample(),
                        gpsAuthorization: "whenInUse", gpsPrecise: true, appState: "background", at: Date())
                }
            } else {
                expect(recorder.library.sessions.first?.endedAt != nil, "Indeks selesai sebelum callback stop")
            }
        }
        let csvURL = recorder.start(format: .csv, includesMotionAndBarometer: false)!
        expect(events == [true] && recorder.lineCount == 1, "Start dan sampling pertama sinkron")
        recorder.checkpoint()
        expect(recorder.isRecording && events == [true], "Checkpoint background tidak menghentikan sesi")
        expect(try! String(contentsOf: csvURL, encoding: .utf8).split(separator: "\n").count == 2,
               "Header dan baris callback tersimpan")
        expect(recorder.library.sessions.first?.lineCount == 1, "Checkpoint memperbarui indeks")
        let savedRows = try! String(contentsOf: csvURL, encoding: .utf8).split(separator: "\n").map { CSVCodec.fields(String($0)) }
        expect(savedRows[0].count == savedRows[1].count, "Header dan baris GPS tanpa sensor tambahan cocok")
        let saved = Dictionary(uniqueKeysWithValues: zip(savedRows[0], savedRows[1]))
        expect(saved["gps_lat"] == "-6.2000000" && saved["gps_lon"] == "106.8000000" && saved["gps_status"] == "active",
               "GPS benar-benar ditulis meski toggle mati dan motor terputus")
        expect(saved["motion_status"] == nil && saved["phone_pressure_kpa"] == nil,
               "File tanpa sensor tambahan tidak memuat gerakan atau tekanan")
        _ = recorder.start(format: .bleRaw, includesMotionAndBarometer: false)
        expect(events == [true, false, true], "Ganti format menghentikan sumber lama sebelum mulai baru")
        recorder.appendRaw(.info, "Uji data buatan")
        for _ in 0..<100 { recorder.appendRaw(.info, "Frame uji tambahan") }
        recorder.stop()
        let rawData = try! Data(contentsOf: recorder.fileURL!)
        expect(recorder.lineCount == 101 && recorder.bytesWritten == rawData.count,
               "Pembatas progres UI tidak membuang frame atau mengurangi hitungan akhir")
        let rawSession = recorder.library.sessions.first { $0.fileName == recorder.fileURL!.lastPathComponent }!
        expect(rawSession.lineCount == 101 && rawSession.bytes == rawData.count,
               "Indeks memakai hitungan file sebenarnya meski pembaruan UI dibatasi")
        recorder.stop()
        expect(events == [true, false, true, false], "Stop idempotent")
        recorder.onRecordingChanged = nil
    }

    static func checkWorkScheduling() {
        var csv = MonotonicThrottle(interval: 1)
        var ui = LiveTelemetryBuffer()
        var csvRows = 0
        var uiUpdates = 0
        for tick in 0..<200 {
            let uptime = Double(tick) / 20
            var packet = TelemetrySnapshot()
            packet.merge([DecodedValue(key: "rpm", name: "RPM", raw: Double(tick), value: Double(tick), unit: "rpm")])
            if ui.receive(packet, at: uptime, isForeground: true) != nil { uiUpdates += 1 }
            // BLE, GPS, dan timer tiba pada saat sama; hanya satu boleh menulis.
            for _ in 0..<3 { if csv.consume(at: uptime) { csvRows += 1 } }
        }
        expect(uiUpdates == 40, "200 paket BLE dalam 10 detik hanya menerbitkan 40 pembaruan dashboard")
        expect(csvRows == 10, "600 pemicu sampling menghasilkan 10 baris, tanpa duplikat")
        near(ui.latest.rpm, 199, "CSV tetap mendapatkan paket terakhir yang belum diterbitkan ke UI")
        var backgroundPacket = TelemetrySnapshot()
        backgroundPacket.merge([DecodedValue(key: "rpm", name: "RPM", raw: 9000, value: 9000, unit: "rpm")])
        expect(ui.receive(backgroundPacket, at: 20, isForeground: false) == nil,
               "Background tidak menerbitkan snapshot ke dashboard")
        near(ui.latest.rpm, 9000, "Data rekaman tetap segar ketika dashboard berhenti diperbarui")
        expect(ui.receive(backgroundPacket, at: 30, isForeground: true)?.rpm == 9000,
               "Foreground kembali menampilkan data terbaru")
        expect(csv.consume(at: 300) && !csv.consume(at: 300), "Suspend panjang tidak dikejar sebagai backlog CSV")
        var jitter = MonotonicThrottle(interval: 1)
        expect(jitter.consume(at: 0.002), "Callback BLE pertama mengambil slot sampling")
        expect(!jitter.consume(at: 1), "Timer yang sedikit terlalu awal tidak menggandakan sampling")
        near(jitter.remaining(at: 1), 0.002, "Timer dijadwalkan 2 ms lagi, bukan melewatkan satu detik")
        expect(jitter.consume(at: 1.002), "Sampling lanjut pada tenggat setelah jitter timer")

        var watchdog = InactivityDeadline()
        watchdog.recordActivity(at: 0, timeout: 5)
        watchdog.recordActivity(at: 4.9, timeout: 5)
        near(watchdog.remaining(at: 5), 4.9, "Timer lama menghormati RX baru tanpa timer baru per paket")
        near(watchdog.remaining(at: 9.9), 0, "Watchdog tetap mendeteksi stream yang benar-benar diam")
        watchdog = InactivityDeadline()
        expect(watchdog.remaining(at: 500) == nil, "Background/disconnect menghapus tenggat lama")
        watchdog.recordActivity(at: 500, timeout: 5)
        near(watchdog.remaining(at: 500), 5, "Foreground memberi tenggat baru")

        var keepAlive = KeepAliveSchedule()
        var clockTimes: [Double] = []
        var notificationTimes: [Double] = []
        for tick in 0..<2000 {
            let uptime = Double(tick) / 100
            // Dua pemicu bersamaan (timer dan RX) harus berbagi jadwal tunggal.
            for _ in 0..<2 {
                switch keepAlive.next(at: uptime, policy: .full) {
                case .clock: clockTimes.append(uptime)
                case .notification: notificationTimes.append(uptime)
                case nil: break
                }
            }
        }
        expect(clockTimes.count == 20 && notificationTimes.count == 20,
               "4000 callback hanya menghasilkan 20 pasangan 058A/058B selama 20 detik")
        expect(zip(clockTimes, notificationTimes).allSatisfy { $1 - $0 >= 0.099999 },
               "Pasangan 058A/058B tetap terpisah minimal 100 ms")
        expect(zip(clockTimes, clockTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.999999 },
               "Tidak ada double-send 058A dalam satu detik")
        expect(zip(notificationTimes, notificationTimes.dropFirst()).allSatisfy { $1 - $0 >= 0.999999 },
               "Tidak ada double-send 058B dalam satu detik")
    }
}
