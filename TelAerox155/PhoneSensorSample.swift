import Foundation

nonisolated enum PhonePlacement: String, CaseIterable, Identifiable, Sendable {
    case unknown, mounted, pocket
    var id: String { rawValue }
    var title: String {
        switch self {
        case .unknown: return "Belum ditentukan"
        case .mounted: return "Holder / terpasang kokoh"
        case .pocket: return "Saku / tas"
        }
    }
}

/// Semua satuan fisik dinyatakan eksplisit; sumbu mengikuti perangkat,
/// bukan sumbu motor. Roll/pitch/yaw adalah orientasi HP, bukan lean motor.
nonisolated struct MotionReading: Sendable {
    let uptime: Double
    let ax, ay, az: Double                 // m/s², gravitasi sudah dipisahkan
    let gx, gy, gz: Double                 // vektor gravitasi, g
    let rx, ry, rz: Double                 // rad/s
    let roll, pitch, yaw: Double           // derajat, referensi arbitrer + vertikal
    let qw, qx, qy, qz: Double             // quaternion orientasi

    var magnitude: Double { sqrt(ax * ax + ay * ay + az * az) }
    var vertical: Double {
        let length = sqrt(gx * gx + gy * gy + gz * gz)
        guard length > 0 else { return 0 }
        return -(ax * gx + ay * gy + az * gz) / length
    }
}

/// Agregasi tanpa menyimpan seluruh buffer 50 Hz, sehingga RAM konstan.
/// Jeda callback >0,2 d memulai jendela baru agar data sebelum suspend tidak
/// tercampur dengan data setelah app aktif kembali.
nonisolated struct MotionAccumulator {
    private(set) var count = 0
    private(set) var firstUptime: Double?
    private(set) var last: MotionReading?
    private var sumX = 0.0, sumY = 0.0, sumZ = 0.0
    private var sumSquares = 0.0, verticalSquares = 0.0
    private var peak = 0.0, verticalPeak = 0.0

    mutating func append(_ r: MotionReading) {
        guard [r.uptime, r.ax, r.ay, r.az, r.gx, r.gy, r.gz,
               r.rx, r.ry, r.rz, r.roll, r.pitch, r.yaw, r.qw, r.qx, r.qy, r.qz].allSatisfy(\.isFinite) else { return }
        if let last, r.uptime <= last.uptime { return }
        if let firstUptime, r.uptime - firstUptime > 2 {
            self = MotionAccumulator()
        } else if let last, r.uptime - last.uptime > 0.2 {
            self = MotionAccumulator()
        }
        if firstUptime == nil { firstUptime = r.uptime }
        last = r
        count += 1
        sumX += r.ax; sumY += r.ay; sumZ += r.az
        let magnitude = r.magnitude
        let vertical = r.vertical
        sumSquares += magnitude * magnitude
        verticalSquares += vertical * vertical
        peak = max(peak, magnitude)
        verticalPeak = max(verticalPeak, abs(vertical))
    }

    mutating func take(at uptime: Double) -> MotionSummary? {
        defer { self = MotionAccumulator() }
        guard let last, let firstUptime, count > 0,
              uptime >= last.uptime, uptime - last.uptime <= 2 else { return nil }
        let n = Double(count)
        return MotionSummary(last: last, count: count, span: last.uptime - firstUptime,
                             age: uptime - last.uptime, meanX: sumX / n, meanY: sumY / n,
                             meanZ: sumZ / n, peak: peak, rms: sqrt(sumSquares / n),
                             verticalPeak: verticalPeak, verticalRMS: sqrt(verticalSquares / n))
    }
}

nonisolated struct MotionSummary: Sendable {
    let last: MotionReading
    let count: Int
    let span, age, meanX, meanY, meanZ, peak, rms, verticalPeak, verticalRMS: Double
}

nonisolated struct PhoneSensorSample: Sendable {
    var motion: MotionSummary?
    var motionStatus = "unavailable"
    var pressureKPa: Double?
    var relativeAltitude: Double?
    var barometerAge: Double?
    var barometerTimestamp: Date?
    var barometerUptime: Double?
    var barometerStatus = "unavailable"
    var batteryPercent: Double?
    var batteryState = "unknown"
    var lowPower: Bool?
    var thermalState = "unknown"
    var placement: PhonePlacement = .unknown
}
