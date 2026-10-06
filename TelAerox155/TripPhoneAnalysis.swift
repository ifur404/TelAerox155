import Foundation

nonisolated struct TripDataGap: Identifiable, Sendable {
    enum Kind: String, Sendable {
        case recording, ble, gps, motion
        var title: String {
            switch self {
            case .recording: return "Jeda penulisan rekaman"
            case .ble: return "BLE belum streaming"
            case .gps: return "Lokasi tidak valid / tidak tersedia"
            case .motion: return "Gerakan tidak tersedia"
            }
        }
    }
    let kind: Kind
    let start, end: Double
    var id: String { "\(kind.rawValue)-\(start)" }
    var duration: Double { max(0, end - start) }
}

nonisolated struct TripEvent: Identifiable, Sendable {
    enum Kind: String, CaseIterable, Sendable {
        case acceleration, braking, bump
        var title: String {
            switch self {
            case .acceleration: return "Akselerasi kuat (perkiraan)"
            case .braking: return "Perlambatan kuat (dugaan pengereman)"
            case .bump: return "Guncangan iPhone"
            }
        }
        var icon: String {
            switch self {
            case .acceleration: return "arrow.up.right"
            case .braking: return "arrow.down.right"
            case .bump: return "waveform.path"
            }
        }
    }
    let kind: Kind
    let t, value: Double
    let lat, lon: Double?
    var id: String { "\(kind.rawValue)-\(t)" }
}

nonisolated struct TripElevationPoint: Identifiable, Sendable {
    let t, km, altitude: Double
    let segment: Int
    var id: Double { t }
}

nonisolated extension TripAnalysis {
    var ecuCoverage: Double { recordedSeconds > 0 ? ecuValidSeconds / recordedSeconds * 100 : 0 }
    var gpsCoverage: Double { recordedSeconds > 0 ? gpsValidSeconds / recordedSeconds * 100 : 0 }
    var motionCoverage: Double { recordedSeconds > 0 ? motionValidSeconds / recordedSeconds * 100 : 0 }

    mutating func buildPhoneAnalytics() {
        guard let first = samples.first, let last = samples.last else { return }
        recordedSeconds = last.t - first.t + 1
        var lastEvent: [TripEvent.Kind: Double] = [:]
        var previousFix: TripSample?
        var distance = 0.0
        for i in samples.indices {
            let s = samples[i]
            let span = i + 1 < samples.count ? min(1, samples[i + 1].t - s.t) : 1
            if s.hasECU { ecuValidSeconds += span }
            if s.hasGPS { gpsValidSeconds += span }
            if s.motionPeak != nil { motionValidSeconds += span }
            if hasQualityColumns && s.bleState != "streaming" { bleUnavailableSeconds += span }
            if let battery = s.phoneBattery {
                if phoneBatteryStart == nil { phoneBatteryStart = battery }
                phoneBatteryEnd = battery
            }
            if s.phoneBatteryState == "charging" || s.phoneBatteryState == "full" { chargingSeconds += span }
            if let peak = s.motionPeak { maxMotionPeak = max(maxMotionPeak ?? peak, peak) }
            if i > 0, s.t - samples[i - 1].t > 2 {
                let start = samples[i - 1].t + 1
                recordingGapSeconds += s.t - start
                gaps.append(TripDataGap(kind: .recording, start: start, end: s.t))
            }

            // Percepatan longitudinal dari perubahan kecepatan, sehingga
            // tidak bergantung arah pemasangan HP. Tidak menyatakan tuas rem
            // ditekan; engine braking juga dapat menurunkan kecepatan.
            if i > 0 {
                let p = samples[i - 1]
                let delta = s.t - p.t
                var pair: (Double, Double, Double)?
                if delta > 0 && delta <= 2 {
                    if let v = s.speed, let previous = p.speed,
                       !hasQualityColumns || ((s.ecuAge ?? 99) <= 2 && (p.ecuAge ?? 99) <= 2) {
                        pair = (v, previous, delta)
                    } else if s.gpsFresh && p.gpsFresh,
                              let v = s.gpsSpeed, let previous = p.gpsSpeed,
                              (s.accuracy ?? 99) <= 10, (p.accuracy ?? 99) <= 10,
                              (s.speedAccuracy ?? 99) <= 1, (p.speedAccuracy ?? 99) <= 1,
                              (s.gpsAge ?? 99) <= 2, (p.gpsAge ?? 99) <= 2 {
                        let fixDelta = delta - (s.gpsAge ?? 0) + (p.gpsAge ?? 0)
                        if fixDelta >= 0.5 && fixDelta <= 2 { pair = (v, previous, fixDelta) }
                    }
                }
                if let (v, previous, time) = pair {
                    let acceleration = (v - previous) / 3.6 / time
                    // Lọc glitch, không biến lompatan speed thành event.
                    if abs(acceleration) <= 12 { samples[i].acceleration = acceleration }
                }
            }
            var candidates: [(TripEvent.Kind, Double)] = []
            let previousSpeed = i > 0 ? (samples[i - 1].speed ?? samples[i - 1].gpsSpeed ?? 0) : 0
            if let acceleration = samples[i].acceleration, max(s.speed ?? s.gpsSpeed ?? 0, previousSpeed) >= 10 {
                if acceleration >= 2.5 { candidates.append((.acceleration, acceleration)) }
                if acceleration <= -2.5 { candidates.append((.braking, acceleration)) }
            }
            if let peak = s.verticalPeak, peak >= 8,
               (s.motionCount ?? 0) >= 10, (s.motionSpan ?? 0) >= 0.2,
               (s.motionAge ?? 99) <= 0.2,
               s.placement == .mounted, (s.speed ?? s.gpsSpeed ?? 0) >= 10 {
                candidates.append((.bump, peak))
            }
            for (kind, value) in candidates where s.t - (lastEvent[kind] ?? -100) >= 10 {
                events.append(TripEvent(kind: kind, t: s.t, value: value, lat: s.lat, lon: s.lon))
                lastEvent[kind] = s.t
            }

            if s.hasGPS && s.gpsFresh {
                if let p = previousFix, s.t - p.t <= 5 {
                    distance += Self.haversine(p.lat!, p.lon!, s.lat!, s.lon!)
                }
                previousFix = s
            }
            samples[i].distanceKm = distance / 1000
        }
        if hasQualityColumns { appendGaps(kind: .ble) { $0.bleState != "streaming" } }
        if availableColumns.contains("gps_lat") { appendGaps(kind: .gps) { !$0.hasGPS } }
        if hasPhoneColumns { appendGaps(kind: .motion) { $0.motionPeak == nil } }
        gaps.sort { $0.start < $1.start }
        buildElevation()
    }

    private mutating func appendGaps(kind: TripDataGap.Kind, missing: (TripSample) -> Bool) {
        var start: Double?, end = 0.0
        for (i, s) in samples.enumerated() {
            let next = i + 1 < samples.count ? min(s.t + 1, samples[i + 1].t) : s.t + 1
            if missing(s) {
                if let st = start, s.t - end > 1 {
                    gaps.append(TripDataGap(kind: kind, start: st, end: end)); start = nil
                }
                if start == nil { start = s.t }
                end = next
            } else if let st = start {
                gaps.append(TripDataGap(kind: kind, start: st, end: end)); start = nil
            }
        }
        if let st = start { gaps.append(TripDataGap(kind: kind, start: st, end: end)) }
    }

    private mutating func buildElevation() {
        let barometerCount = Set(samples.compactMap { s in
            s.relativeAltitude == nil ? nil : s.barometerTimestamp
        }).count
        let useBarometer = barometerCount >= 3
        elevationSource = useBarometer ? "Barometer · relatif ke awal rekaman" : "GPS · terhadap permukaan laut"
        var previousTimestamp: String?
        var reference: Double?, previousT: Double?
        var gain = 0.0, loss = 0.0, count = 0, segment = 0
        var windowStart = 0
        var profile: [TripElevationPoint] = []
        var grades: [ChartPoint] = []
        for s in samples {
            let value = useBarometer ? s.relativeAltitude : (s.gpsFresh ? s.altitude : nil)
            guard let altitude = value else { continue }
            let timestamp = useBarometer ? s.barometerTimestamp : s.gpsTimestamp
            if let timestamp, timestamp == previousTimestamp { continue }
            previousTimestamp = timestamp
            if let previousT, s.t - previousT > 5 {
                reference = nil; segment += 1; windowStart = profile.count
            }
            previousT = s.t
            count += 1
            // Ambang simetris mengurangi penjumlahan noise naik/turun.
            let threshold = useBarometer ? 3 : max(5, s.verticalAccuracy ?? 5)
            if let ref = reference {
                let delta = altitude - ref
                if abs(delta) >= threshold {
                    if delta > 0 { gain += delta } else { loss -= delta }
                    reference = altitude
                }
            } else { reference = altitude }
            guard s.hasGPS && s.gpsFresh, (s.accuracy ?? 99) <= 10 else { continue }
            if let previous = profile.last, s.t - previous.t > 5, previous.segment == segment {
                segment += 1; windowStart = profile.count
            }
            let point = TripElevationPoint(t: s.t, km: s.distanceKm, altitude: altitude, segment: segment)
            profile.append(point)
            let index = profile.count - 1
            // Slope dihitung pada ruas ≥100 m, bukan selisih setiap detik.
            while windowStart + 1 < index && point.km - profile[windowStart + 1].km >= 0.1 {
                windowStart += 1
            }
            guard windowStart < index else { continue }
            let anchor = profile[windowStart], meters = (point.km - anchor.km) * 1000
            if meters >= 100 && point.segment == anchor.segment && point.t - anchor.t <= 120 {
                let grade = (point.altitude - anchor.altitude) / meters * 100
                if abs(grade) <= 35 {
                    grades.append(ChartPoint(t: point.t, v: grade, segment: segment))
                    maxGrade = max(maxGrade ?? grade, grade)
                    minGrade = min(minGrade ?? grade, grade)
                }
            }
        }
        if count >= 3 { altitudeGain = gain; altitudeLoss = loss }
        // Maks 600 titik untuk UI; segment dipertahankan saat downsampling.
        let step = max(1, Int(ceil(Double(profile.count) / Double(Self.maxChartPoints))))
        elevationProfile = profile.enumerated().compactMap { i, p in
            i % step == 0 || i == profile.count - 1 ? p : nil
        }
        gradeSeries = Self.downsample(grades, to: Self.maxChartPoints)
    }
}
