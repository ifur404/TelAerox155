import Foundation

// Analisis lengkap satu rekaman CSV untuk halaman detail rekaman: parser per
// baris, pembersihan data, statistik, dan seri siap-plot (chart, peta,
// replay). Murni Foundation, tanpa SwiftUI/MapKit, supaya bisa dihitung di
// background (file bisa sampai 20 MB / ~21.600 baris) dan dites terpisah.
//
// Semua tipe di sini `nonisolated`: di bawah SWIFT_DEFAULT_ACTOR_ISOLATION=
// MainActor, tanpa anotasi ini struct & fungsinya ikut ter-infer MainActor dan
// tidak bisa dipanggil dari Task.detached.

/// Satu baris CSV yang sudah dibersihkan. Field ECU nil kalau baris itu belum
/// ada data motor (masih connect) atau sudah kunci OFF; field GPS nil kalau
/// belum ada fix atau fix-nya dibuang (akurasi jelek / lompatan mustahil).
nonisolated struct TripSample: Sendable {
    /// Detik sejak rekaman mulai (kolom elapsed_s).
    let t: Double
    var rpm: Double?
    var speed: Double?
    var battery: Double?
    var coolant: Double?
    var intake: Double?
    var throttle: Double?
    var injection: Double?
    var odometer: Double?
    var lat: Double?
    var lon: Double?
    var gpsSpeed: Double?
    var altitude: Double?
    var accuracy: Double?
    var gpsAge: Double?
    var gpsTimestamp: String?
    var verticalAccuracy: Double?
    var speedAccuracy: Double?
    var course: Double?
    var courseAccuracy: Double?
    var ecuAge: Double?
    var bleState: String?
    var motionAge: Double?
    var motionCount: Double?
    var motionSpan: Double?
    var motionPeak: Double?
    var motionRMS: Double?
    var verticalPeak: Double?
    var verticalRMS: Double?
    var roll: Double?
    var pitch: Double?
    var yaw: Double?
    var rotationRate: Double?
    var pressure: Double?
    var relativeAltitude: Double?
    var barometerAge: Double?
    var barometerTimestamp: String?
    var phoneBattery: Double?
    var phoneBatteryState: String?
    var placement: PhonePlacement = .unknown
    var motionStatus: String?
    var barometerStatus: String?
    var gpsStatus: String?
    var acceleration: Double?
    var distanceKm: Double = 0
    /// Timestamp fix membedakan sampel baru walau motor diam; CSV lama
    /// memakai perubahan koordinat karena timestamp sensor belum tersedia.
    var gpsFresh = false

    var hasECU: Bool { rpm != nil && speed != nil }
    var hasGPS: Bool { lat != nil && lon != nil }
}

nonisolated struct ChartPoint: Identifiable, Sendable {
    let t: Double
    let v: Double
    var segment = 0
    var id: Double { t }
}

/// Titik rute di peta. `level` = kelas kecepatan 0…(levels-1) relatif ke
/// kecepatan tertinggi trip (dipakai buat warna segmen).
nonisolated struct RoutePoint: Sendable {
    let t: Double
    let lat: Double
    let lon: Double
    let speed: Double
    let level: Int
    var segment = 0
}

/// Potongan rute berkecepatan (kelas) sama — satu MapPolyline per segmen.
nonisolated struct RouteSegment: Identifiable, Sendable {
    let id: Int
    let level: Int
    let points: [RoutePoint]
}

nonisolated struct TripStop: Identifiable, Sendable {
    let start: Double
    let duration: Double
    let lat: Double?
    let lon: Double?
    var id: Double { start }
}

nonisolated struct ScatterPoint: Identifiable, Sendable {
    let id: Int
    let speed: Double
    let rpm: Double
    let throttle: Double
}

nonisolated struct HistogramBin: Identifiable, Sendable {
    let lower: Double
    let upper: Double
    /// Detik yang dihabiskan di rentang ini.
    let seconds: Double
    var id: Double { lower }
}

/// Mode berkendara per detik, dari kecepatan + bukaan gas + perubahan
/// kecepatan.
nonisolated enum RidingMode: String, CaseIterable, Identifiable, Sendable {
    case idle, accelerating, cruising, coasting

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: return "Idle / berhenti"
        case .accelerating: return "Akselerasi"
        case .cruising: return "Cruising"
        case .coasting: return "Coasting (gas tutup)"
        }
    }
}

nonisolated struct TripAnalysis: Sendable {
    static let speedLevels = 8

    // MARK: Data
    var samples: [TripSample] = []
    /// Baris CSV yang terbaca (tanpa header).
    var rawRows = 0
    /// Baris di awal rekaman sebelum ECU mengirim data (masih connect/auth).
    var rowsBeforeECU = 0
    /// Baris setelah kunci kontak OFF (tegangan aki ~0 V) — nilai ECU di
    /// baris ini tidak valid dan diabaikan.
    var rowsAfterKeyOff = 0
    /// Titik GPS yang dibuang (akurasi > 30 m atau lompatan mustahil).
    var gpsRejected = 0
    var hasPhoneColumns = false
    var hasQualityColumns = false
    var recordedSeconds = 0.0
    var ecuValidSeconds = 0.0
    var gpsValidSeconds = 0.0
    var motionValidSeconds = 0.0
    var bleUnavailableSeconds = 0.0
    var recordingGapSeconds = 0.0
    var gaps: [TripDataGap] = []
    var events: [TripEvent] = []
    var phoneBatteryStart: Double?
    var phoneBatteryEnd: Double?
    var chargingSeconds = 0.0
    var maxMotionPeak: Double?
    var altitudeLoss: Double?
    var elevationSource = "GPS"
    var elevationProfile: [TripElevationPoint] = []
    var accelerationSeries: [ChartPoint] = []
    var motionPeakSeries: [ChartPoint] = []
    var verticalRMSSeries: [ChartPoint] = []
    var phoneBatterySeries: [ChartPoint] = []
    var relativeAltitudeSeries: [ChartPoint] = []
    var pressureSeries: [ChartPoint] = []
    var rollSeries: [ChartPoint] = []
    var pitchSeries: [ChartPoint] = []
    var yawSeries: [ChartPoint] = []
    var rotationSeries: [ChartPoint] = []
    var gradeSeries: [ChartPoint] = []
    var maxGrade: Double?
    var minGrade: Double?

    // MARK: Ringkasan
    var startTime: Double = 0
    var endTime: Double = 0
    var duration: Double { max(0, endTime - startTime) }
    var movingSeconds: Double = 0
    var stoppedSeconds: Double = 0

    var maxRPM: Double?
    var maxSpeed: Double?
    var maxSpeedTime: Double?
    /// Rata-rata kecepatan selama bergerak (speed > 0).
    var avgMovingSpeed: Double?
    var coolantStart: Double?
    var coolantEnd: Double?
    var coolantMax: Double?
    var intakeAvg: Double?
    /// Tegangan aki terendah/rata-rata SELAMA MESIN HIDUP (rpm > 0).
    var batteryMin: Double?
    var batteryAvg: Double?
    var gpsDistanceKm: Double?
    var odometerStart: Double?
    var odometerEnd: Double?
    var odometerDistanceKm: Double? {
        guard let a = odometerStart, let b = odometerEnd, b >= a else { return nil }
        return b - a
    }
    var altitudeMin: Double?
    var altitudeMax: Double?
    /// Total tanjakan (m), dengan ambang histeresis supaya noise GPS tidak
    /// terakumulasi jadi tanjakan palsu.
    var altitudeGain: Double?
    /// Rata-rata selisih speedometer ECU terhadap GPS (%). Positif = ECU
    /// menunjukkan lebih cepat dari kecepatan sebenarnya.
    var speedoErrorPercent: Double?
    var speedoErrorSamples = 0
    /// Estimasi BBM (ml) dari integrasi injection_cc — EKSPERIMENTAL, dengan
    /// asumsi nilai injection_cc = laju aliran cc/detik (lihat `fuelNote`).
    var fuelMl: Double?
    var fuelKmPerLiter: Double? {
        guard let ml = fuelMl, ml > 1, let km = gpsDistanceKm ?? odometerDistanceKm, km >= 0.3 else { return nil }
        return km / (ml / 1000)
    }

    // MARK: Info kendaraan
    var vin: String?
    var modelCode: String?
    var ignOnCount: Double?
    var ecuPowerOnHours: Double?
    var maxFiError: Double = 0
    var maxDTC: Double = 0
    var fiLampOn = false

    // MARK: Seri siap-plot (sudah di-downsample)
    var speedSeries: [ChartPoint] = []
    var gpsSpeedSeries: [ChartPoint] = []
    var rpmSeries: [ChartPoint] = []
    var throttleSeries: [ChartPoint] = []
    var coolantSeries: [ChartPoint] = []
    var intakeSeries: [ChartPoint] = []
    var batterySeries: [ChartPoint] = []
    var altitudeSeries: [ChartPoint] = []

    var route: [RoutePoint] = []
    var routeSegments: [RouteSegment] = []
    /// Kecepatan acuan skala warna rute (km/h).
    var routeSpeedScale: Double = 0
    var stops: [TripStop] = []
    var cvtPoints: [ScatterPoint] = []
    var modeSeconds: [RidingMode: Double] = [:]
    var speedHistogram: [HistogramBin] = []
    var rpmHistogram: [HistogramBin] = []

    var hasECU: Bool { maxRPM != nil }
    var hasRoute: Bool { route.count > 1 }

    // MARK: - Lookup

    /// Sampel terdekat untuk waktu `t` (binary search).
    func sample(at t: Double) -> TripSample? {
        guard !samples.isEmpty else { return nil }
        var lo = 0, hi = samples.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if samples[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(samples[lo - 1].t - t) < abs(samples[lo].t - t) { lo -= 1 }
        return samples[lo]
    }

    /// Indeks titik rute (peta) terdekat untuk waktu `t`.
    func routeIndex(at t: Double) -> Int? {
        guard !route.isEmpty else { return nil }
        var lo = 0, hi = route.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if route[mid].t < t { lo = mid + 1 } else { hi = mid }
        }
        if lo > 0, abs(route[lo - 1].t - t) < abs(route[lo].t - t) { lo -= 1 }
        return lo
    }

    func routePoint(at t: Double) -> RoutePoint? {
        routeIndex(at: t).map { route[$0] }
    }

    /// Titik rute terdekat ke koordinat (buat tap di peta).
    func nearestRoutePoint(lat: Double, lon: Double) -> RoutePoint? {
        let k = cos(lat * .pi / 180)
        return route.min { a, b in
            let da = pow(a.lat - lat, 2) + pow((a.lon - lon) * k, 2)
            let db = pow(b.lat - lat, 2) + pow((b.lon - lon) * k, 2)
            return da < db
        }
    }

    // MARK: - Parse

    static func load(from url: URL) -> TripAnalysis? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> TripAnalysis? {
        var lines = text.split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else { return nil }
        let header = CSVCodec.fields(String(lines.removeFirst()))
        var indices: [String: Int] = [:]
        for (i, key) in header.enumerated() { indices[key] = i }
        func col(_ name: String) -> Int? { indices[name] }
        let iT = col("elapsed_s"), iRPM = col("rpm"), iSpeed = col("speed_kmh"), iBatt = col("battery_v"),
            iCool = col("coolant_c"), iIntake = col("intake_c"), iThr = col("throttle_deg"),
            iFi = col("fiError"), iDTC = col("dtc"), iLamp = col("fiWarningLamp"),
            iInj = col("injection_cc"), iOdo = col("odometer_km"), iPower = col("ecuPowerOnTime_s"),
            iIgn = col("ignOnCount"), iVIN = col("vin"), iModel = col("modelCode"),
            iLat = col("gps_lat"), iLon = col("gps_lon"), iGSpd = col("gps_speed_kmh"),
            iAlt = col("gps_alt_m"), iAcc = col("gps_accuracy_m")
        guard iT != nil else { return nil }

        var a = TripAnalysis()
        a.hasPhoneColumns = col("motion_status") != nil
        a.hasQualityColumns = col("ble_state") != nil
        var seenECU = false
        var lastFix: (lat: Double, lon: Double, t: Double)?
        var lastOdo: Double?
        var lastGPSTimestamp: String?

        for line in lines {
            let f = CSVCodec.fields(String(line))
            func num(_ i: Int?) -> Double? {
                guard let i, i < f.count, !f[i].isEmpty, let v = Double(f[i]), v.isFinite else { return nil }
                return v
            }
            func str(_ i: Int?) -> String? {
                guard let i, i < f.count, !f[i].isEmpty else { return nil }
                return String(f[i])
            }
            func n(_ key: String) -> Double? { num(col(key)) }
            func text(_ key: String) -> String? { str(col(key)) }
            func freshECU(_ key: String) -> Bool {
                guard a.hasQualityColumns else { return true }
                guard text("ble_state") == "streaming", let age = n("ecu_\(key)_age_s") else { return false }
                return age >= 0 && age <= 5
            }
            guard let t = num(iT), t >= 0, t > (a.samples.last?.t ?? -1) else { continue }
            a.rawRows += 1
            var s = TripSample(t: t)
            s.bleState = text("ble_state")
            s.ecuAge = n("ecu_rpm_age_s")
            s.gpsAge = n("gps_age_s")
            s.gpsTimestamp = text("gps_timestamp_iso")
            s.verticalAccuracy = n("gps_vertical_accuracy_m")
            s.speedAccuracy = n("gps_speed_accuracy_mps")
            s.course = n("gps_course_deg")
            s.courseAccuracy = n("gps_course_accuracy_deg")
            s.gpsStatus = text("gps_status")
            s.placement = PhonePlacement(rawValue: text("phone_placement") ?? "") ?? .unknown
            s.motionStatus = text("motion_status")
            s.barometerStatus = text("barometer_status")
            s.motionAge = n("motion_age_s")
            s.motionCount = n("motion_samples")
            s.motionSpan = n("motion_span_s")
            if s.motionStatus == "active", let age = s.motionAge, (0...2).contains(age), (s.motionCount ?? 0) > 0 {
                s.motionPeak = n("motion_peak_mps2")
                s.motionRMS = n("motion_rms_mps2")
                s.verticalPeak = n("motion_vertical_peak_mps2")
                s.verticalRMS = n("motion_vertical_rms_mps2")
                s.roll = n("roll_deg"); s.pitch = n("pitch_deg"); s.yaw = n("yaw_deg")
                if let x = n("gyro_x_radps"), let y = n("gyro_y_radps"), let z = n("gyro_z_radps") {
                    s.rotationRate = sqrt(x * x + y * y + z * z)
                }
            }
            s.barometerAge = n("barometer_age_s")
            s.barometerTimestamp = text("barometer_timestamp_iso")
            if s.barometerStatus == "active", let age = s.barometerAge, (0...5).contains(age) {
                s.pressure = n("phone_pressure_kpa")
                s.relativeAltitude = n("phone_relative_alt_m")
            }
            if let battery = n("phone_battery_pct"), (0...100).contains(battery) { s.phoneBattery = battery }
            s.phoneBatteryState = text("phone_battery_state")

            // --- ECU ---
            let battery = freshECU("battery") ? num(iBatt) : nil
            let rpm = freshECU("rpm") ? num(iRPM) : nil
            let speed = freshECU("speed") ? num(iSpeed) : nil
            if rpm != nil || speed != nil { seenECU = true }
            // Kunci OFF: ECU masih "mengirim" nilai terakhir tapi tegangan
            // sudah jatuh ke ~0 V (0,077 = 1 step raw) dan odometer jadi 0.
            let keyOff = battery.map { $0 < 5 } ?? false
            if !seenECU {
                a.rowsBeforeECU += 1
            } else if keyOff {
                a.rowsAfterKeyOff += 1
            } else if rpm != nil || speed != nil {
                s.rpm = rpm
                s.speed = speed
                s.battery = battery
                s.coolant = freshECU("coolant") ? num(iCool) : nil
                s.intake = freshECU("intake") ? num(iIntake) : nil
                s.throttle = freshECU("throttle") ? num(iThr) : nil
                s.injection = freshECU("injection") ? num(iInj) : nil
                // Odometer 0 atau mundur = nilai tidak valid.
                if freshECU("odometer"), let o = num(iOdo), o > 0, o >= (lastOdo ?? 0) {
                    s.odometer = o
                    lastOdo = o
                }
                if freshECU("fiError"), let v = num(iFi) { a.maxFiError = max(a.maxFiError, v) }
                if freshECU("dtc"), let v = num(iDTC) { a.maxDTC = max(a.maxDTC, v) }
                if freshECU("fiWarningLamp"), let v = num(iLamp), v > 0 { a.fiLampOn = true }
            }
            if a.vin == nil { a.vin = str(iVIN) }
            if a.modelCode == nil { a.modelCode = str(iModel) }
            if let v = num(iIgn), v > 0 { a.ignOnCount = v }
            if let v = num(iPower), v > 0 { a.ecuPowerOnHours = v / 3600 }

            // --- GPS ---
            if let lat = num(iLat), let lon = num(iLon), (-90...90).contains(lat), (-180...180).contains(lon) {
                let acc = num(iAcc)
                var ok = (acc ?? 0) >= 0 && (acc ?? 0) <= 30
                if a.hasQualityColumns {
                    ok = ok && s.gpsStatus == "active" && s.gpsAge.map { (0...5).contains($0) } == true
                        && acc.map { (0...30).contains($0) } == true
                }
                if ok, let p = lastFix, t > p.t {
                    // Lompatan > 70 m/s (252 km/h) = glitch GPS.
                    let d = haversine(p.lat, p.lon, lat, lon)
                    if d / (t - p.t) > 70 { ok = false }
                }
                if ok {
                    s.lat = lat
                    s.lon = lon
                    if let speed = num(iGSpd), speed >= 0 { s.gpsSpeed = speed }
                    if !a.hasQualityColumns || s.verticalAccuracy.map({ (0...20).contains($0) }) == true {
                        s.altitude = num(iAlt)
                    }
                    s.accuracy = acc
                    if let timestamp = s.gpsTimestamp {
                        s.gpsFresh = timestamp != lastGPSTimestamp
                        lastGPSTimestamp = timestamp
                    } else {
                        s.gpsFresh = lastFix.map { $0.lat != lat || $0.lon != lon } ?? true
                    }
                    lastFix = (lat, lon, t)
                } else {
                    a.gpsRejected += 1
                }
            }
            a.samples.append(s)
        }
        guard !a.samples.isEmpty else { return nil }
        a.samples.sort { $0.t < $1.t }
        a.computeStats()
        a.buildPhoneAnalytics()
        a.buildSeries()
        a.buildRoute()
        a.buildAnalytics()
        return a
    }

    // MARK: - Statistik

    /// Lama satu sampel "berlaku" — jarak ke sampel berikutnya, dibatasi 1 d
    /// supaya jeda (motor terputus) tidak dihitung sebagai waktu berkendara.
    private func dt(_ i: Int) -> Double {
        guard i + 1 < samples.count else { return 1 }
        return min(1, max(0, samples[i + 1].t - samples[i].t))
    }

    private mutating func computeStats() {
        startTime = samples.first?.t ?? 0
        endTime = samples.last?.t ?? 0

        var movingSpeedSum = 0.0, movingTime = 0.0
        var intakeSum = 0.0, intakeN = 0
        var battSum = 0.0, battN = 0
        var fuel = 0.0, fuelN = 0
        for (i, s) in samples.enumerated() {
            let d = dt(i)
            if let v = s.rpm { maxRPM = max(maxRPM ?? v, v) }
            if let v = s.speed ?? s.gpsSpeed {
                if v > (maxSpeed ?? -1) { maxSpeed = v; maxSpeedTime = s.t }
                if v > 0 {
                    movingSpeedSum += v * d; movingTime += d
                    movingSeconds += d
                } else {
                    stoppedSeconds += d
                }
            }
            if let v = s.coolant {
                if coolantStart == nil { coolantStart = v }
                coolantEnd = v
                coolantMax = max(coolantMax ?? v, v)
            }
            if let v = s.intake { intakeSum += v; intakeN += 1 }
            if let v = s.battery, let r = s.rpm, r > 0 {
                batteryMin = min(batteryMin ?? v, v)
                battSum += v; battN += 1
            }
            if let v = s.odometer {
                if odometerStart == nil { odometerStart = v }
                odometerEnd = v
            }
            if let v = s.injection { fuel += v * d; fuelN += 1 }
        }
        if movingTime > 0 { avgMovingSpeed = movingSpeedSum / movingTime }
        if intakeN > 0 { intakeAvg = intakeSum / Double(intakeN) }
        if battN > 0 { batteryAvg = battSum / Double(battN) }
        if fuelN > 0 { fuelMl = fuel }

        // Jarak GPS: hanya titik yang benar-benar update.
        var dist = 0.0
        var prev: TripSample?
        for s in samples where s.hasGPS && s.gpsFresh {
            if let p = prev, s.t - p.t <= 5, let la = p.lat, let lo = p.lon, let lb = s.lat, let lob = s.lon {
                dist += Self.haversine(la, lo, lb, lob)
            }
            prev = s
        }
        if samples.filter(\.hasGPS).count > 1 { gpsDistanceKm = dist / 1000 }
        let alts = samples.compactMap(\.altitude)
        if !alts.isEmpty {
            altitudeMin = alts.min()
            altitudeMax = alts.max()
        }

        // Selisih speedometer: hanya saat GPS segar, akurat, dan melaju
        // stabil (≥15 km/h) — di kecepatan rendah pembulatan 1 km/h ECU &
        // lag GPS membuat persentasenya tidak bermakna.
        var errSum = 0.0, errN = 0
        for s in samples {
            guard s.gpsFresh, let g = s.gpsSpeed, let e = s.speed, g >= 15, e >= 15,
                  (s.accuracy ?? 99) <= 5 else { continue }
            if hasQualityColumns && ((s.speedAccuracy ?? 99) > 1 || (s.gpsAge ?? 99) > 2) { continue }
            errSum += (e - g) / g * 100
            errN += 1
        }
        speedoErrorSamples = errN
        if errN >= 5 { speedoErrorPercent = errSum / Double(errN) }
    }

    // MARK: - Seri chart

    /// Maks titik per seri — cukup halus buat layar HP, ringan buat Swift
    /// Charts walau rekaman 6 jam.
    static let maxChartPoints = 600

    private func series(_ value: (TripSample) -> Double?) -> [ChartPoint] {
        var groups: [[ChartPoint]] = [], current: [ChartPoint] = []
        for s in samples {
            guard let v = value(s) else {
                if !current.isEmpty { groups.append(current); current = [] }
                continue
            }
            if let last = current.last, s.t - last.t > 5 { groups.append(current); current = [] }
            current.append(ChartPoint(t: s.t, v: v))
        }
        if !current.isEmpty { groups.append(current) }
        // Banyak ruas pendek juga harus dibatasi; jangan membuat ribuan
        // mark saat GPS/motion hilang-muncul setiap detik. Ruas yang dipilih
        // tetap punya ID terpisah sehingga tidak tersambung melintasi gap.
        let maxGroups = Self.maxChartPoints / 2
        let indices = groups.count > maxGroups
            ? (0..<maxGroups).map { $0 * (groups.count - 1) / (maxGroups - 1) }
            : Array(groups.indices)
        let base = indices.reduce(0) { $0 + min(2, groups[$1].count) }
        let weights = indices.reduce(0) { $0 + max(0, groups[$1].count - 2) }
        let remaining = Self.maxChartPoints - base
        return indices.flatMap { i in
            let points = groups[i]
            let extra = weights > 0 ? remaining * max(0, points.count - 2) / weights : 0
            let budget = min(2, points.count) + extra
            return Self.downsample(points, to: budget).map { point in
                var p = point; p.segment = i; return p
            }
        }
    }

    /// Rata-rata per ember waktu, tapi kalau ember berisi puncak/lembah yang
    /// menonjol, nilai ekstrem itu yang dipakai — supaya kecepatan maks dsb.
    /// tidak "hilang" dari chart saat di-downsample.
    static func downsample(_ pts: [ChartPoint], to n: Int) -> [ChartPoint] {
        guard pts.count > n, n > 1 else { return pts }
        let size = Double(pts.count) / Double(n)
        var out: [ChartPoint] = []
        out.reserveCapacity(n)
        for bucketIndex in 0..<n {
            let lo = Int(Double(bucketIndex) * size)
            let hi = min(pts.count, Int(Double(bucketIndex + 1) * size))
            let bucket = pts[lo..<max(hi, lo + 1)]
            let mean = bucket.reduce(0) { $0 + $1.v } / Double(bucket.count)
            let mx = bucket.max { $0.v < $1.v }!, mn = bucket.min { $0.v < $1.v }!
            let pick = (mx.v - mean) >= (mean - mn.v) ? mx : mn
            let t = bucket[bucket.startIndex + bucket.count / 2].t
            out.append(ChartPoint(t: t, v: abs(pick.v - mean) > 0.15 * max(abs(mean), 1) ? pick.v : mean, segment: pick.segment))
        }
        return out
    }

    private mutating func buildSeries() {
        speedSeries = series(\.speed)
        gpsSpeedSeries = series { $0.gpsFresh ? $0.gpsSpeed : nil }
        rpmSeries = series(\.rpm)
        throttleSeries = series(\.throttle)
        coolantSeries = series(\.coolant)
        intakeSeries = series(\.intake)
        batterySeries = series(\.battery)
        altitudeSeries = series { $0.gpsFresh ? $0.altitude : nil }
        accelerationSeries = series(\.acceleration)
        motionPeakSeries = series(\.motionPeak)
        verticalRMSSeries = series(\.verticalRMS)
        phoneBatterySeries = series(\.phoneBattery)
        relativeAltitudeSeries = series(\.relativeAltitude)
        pressureSeries = series(\.pressure)
        rollSeries = series(\.roll); pitchSeries = series(\.pitch); yawSeries = series(\.yaw)
        rotationSeries = series(\.rotationRate)
    }

    // MARK: - Rute

    static let maxRoutePoints = 1500

    private mutating func buildRoute() {
        // Titik GPS segar saja (baris "basi" = koordinat duplikat).
        let fixes = samples.filter { $0.hasGPS && $0.gpsFresh }
        guard fixes.count > 1 else { return }
        // Kecepatan untuk pewarnaan: ECU kalau ada, fallback GPS; dihaluskan
        // rata-rata 3 titik supaya warna tidak kedip-kedip.
        let raw = fixes.map { $0.speed ?? $0.gpsSpeed ?? 0 }
        let smooth = raw.indices.map { i -> Double in
            let w = raw[max(0, i - 1)...min(raw.count - 1, i + 1)]
            return w.reduce(0, +) / Double(w.count)
        }
        routeSpeedScale = max(20, (smooth.max() ?? 0).rounded(.up))
        let stride = max(1, Int((Double(fixes.count) / Double(Self.maxRoutePoints)).rounded(.up)))
        var sourceSegments = [0]
        var selected = Set(Swift.stride(from: 0, to: fixes.count, by: stride))
        selected.insert(fixes.count - 1)
        for i in 1..<fixes.count {
            let gap = fixes[i].t - fixes[i - 1].t > 5
            sourceSegments.append(sourceSegments[i - 1] + (gap ? 1 : 0))
            if gap { selected.insert(i - 1); selected.insert(i) }
        }
        // Jeda ditentukan SEBELUM downsampling, bukan dari selisih waktu
        // titik hasil stride (yang bisa jauh terpisah pada rekaman panjang).
        let pts = selected.sorted().map { point(fixes[$0], smooth[$0], segment: sourceSegments[$0]) }
        route = pts

        var segs: [RouteSegment] = []
        var cur: [RoutePoint] = [pts[0]]
        for p in pts.dropFirst() {
            if p.segment != cur.last!.segment {
                if cur.count > 1 { segs.append(RouteSegment(id: segs.count, level: cur[0].level, points: cur)) }
                cur = [p]; continue
            }
            cur.append(p)
            if p.level != cur[0].level {
                segs.append(RouteSegment(id: segs.count, level: cur[0].level, points: cur))
                cur = [p]
            }
        }
        if cur.count > 1 { segs.append(RouteSegment(id: segs.count, level: cur[0].level, points: cur)) }
        routeSegments = segs
    }

    private func point(_ s: TripSample, _ speed: Double, segment: Int = 0) -> RoutePoint {
        let norm = min(1, max(0, speed / routeSpeedScale))
        let level = min(Self.speedLevels - 1, Int(norm * Double(Self.speedLevels)))
        return RoutePoint(t: s.t, lat: s.lat!, lon: s.lon!, speed: speed, level: level, segment: segment)
    }

    // MARK: - Analisis berkendara

    private mutating func buildAnalytics() {
        // Titik berhenti ≥ 5 detik (speed ECU 0, fallback GPS < 2 km/h).
        var stopStart: Int?
        func closeStop(_ end: Int) {
            guard let st = stopStart else { return }
            let dur = samples[end].t - samples[st].t
            if dur >= 5 {
                let pos = samples[st...end].first { $0.hasGPS }
                stops.append(TripStop(start: samples[st].t, duration: dur, lat: pos?.lat, lon: pos?.lon))
            }
            stopStart = nil
        }
        for (i, s) in samples.enumerated() {
            if i > 0 && s.t - samples[i - 1].t > 2 { closeStop(i - 1) }
            let v = s.speed ?? s.gpsSpeed.map { $0 < 2 ? 0 : $0 }
            if v == 0 {
                if stopStart == nil { stopStart = i }
            } else {
                closeStop(i)
            }
        }
        if stopStart != nil { closeStop(samples.count - 1) }

        // Mode berkendara.
        var modes: [RidingMode: Double] = [:]
        for (i, s) in samples.enumerated() {
            guard let v = s.speed, let r = s.rpm, r > 0 else { continue }
            let prev = i > 0 ? samples[i - 1].speed : nil
            let accel = prev.map { v - $0 } ?? 0
            let thr = s.throttle ?? 0
            let mode: RidingMode
            if v == 0 {
                mode = .idle
            } else if thr < 1 {
                mode = .coasting
            } else if accel >= 1 {
                mode = .accelerating
            } else {
                mode = .cruising
            }
            modes[mode, default: 0] += dt(i)
        }
        modeSeconds = modes

        // Kurva CVT: RPM vs kecepatan saat melaju.
        var cvt: [ScatterPoint] = []
        let moving = samples.filter { ($0.speed ?? 0) > 0 && ($0.rpm ?? 0) > 0 }
        let step = max(1, moving.count / 1500)
        for i in Swift.stride(from: 0, to: moving.count, by: step) {
            let s = moving[i]
            cvt.append(ScatterPoint(id: i, speed: s.speed!, rpm: s.rpm!, throttle: s.throttle ?? 0))
        }
        cvtPoints = cvt

        // Histogram waktu per rentang kecepatan (10 km/h) & RPM (1000 rpm).
        speedHistogram = histogram(width: 10) { ($0.speed ?? 0) > 0 ? $0.speed : nil }
        rpmHistogram = histogram(width: 1000) { ($0.rpm ?? 0) > 0 ? $0.rpm : nil }
    }

    private func histogram(width: Double, _ value: (TripSample) -> Double?) -> [HistogramBin] {
        var buckets: [Int: Double] = [:]
        for (i, s) in samples.enumerated() {
            guard let v = value(s) else { continue }
            buckets[Int(v / width), default: 0] += dt(i)
        }
        guard let maxKey = buckets.keys.max() else { return [] }
        return (0...maxKey).map { k in
            HistogramBin(lower: Double(k) * width, upper: Double(k + 1) * width, seconds: buckets[k] ?? 0)
        }
    }

    /// Rute tanpa `meters` pertama & terakhir (maks 20% panjang rute per
    /// ujung, supaya rute pendek tidak habis terpotong) — buat kartu sosmed,
    /// supaya titik start/finish (sering = rumah/kantor) tidak ketahuan.
    static func trimmedForPrivacy(_ route: [RoutePoint], meters: Double) -> [RoutePoint] {
        guard route.count > 2 else { return route }
        var cum = [0.0]
        for i in 1..<route.count {
            cum.append(cum[i - 1] + haversine(route[i - 1].lat, route[i - 1].lon, route[i].lat, route[i].lon))
        }
        let total = cum.last ?? 0
        let cut = min(meters, total * 0.2)
        guard cut > 0 else { return route }
        let kept = route.indices.filter { cum[$0] >= cut && cum[$0] <= total - cut }
        guard let lo = kept.first, let hi = kept.last, hi > lo else { return route }
        return Array(route[lo...hi])
    }

    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let dLat = (lat2 - lat1) * .pi / 180
        let dLon = (lon2 - lon1) * .pi / 180
        let a = sin(dLat / 2) * sin(dLat / 2)
            + cos(lat1 * .pi / 180) * cos(lat2 * .pi / 180) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}
