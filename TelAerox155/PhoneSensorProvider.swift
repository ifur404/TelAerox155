import Foundation
import CoreMotion
#if canImport(UIKit)
import UIKit
#endif

/// Sensor lokal mengikuti rekaman CSV. Tidak berinteraksi dengan BLE motor.
@MainActor
final class PhoneSensorProvider {
    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private var accumulator = MotionAccumulator()
    private var pressure: Double?
    private var altitude: Double?
    private var barometerUptime: Double?
    private var barometerDate: Date?
    private var active = false
    private var generation = UUID()
    private var motionStatus = "unavailable"
    private var barometerStatus = "unavailable"

    func start() {
        guard !active else { return }
        active = true
        generation = UUID()
        let session = generation
        accumulator = MotionAccumulator()
        pressure = nil; altitude = nil; barometerUptime = nil; barometerDate = nil
        #if os(iOS)
        motionStatus = motion.isDeviceMotionAvailable ? "waiting" : "unavailable"
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 50.0
            // Queue main menjamin akses serial ke accumulator tanpa hop per
            // sampel; timestamp sensor tetap dipakai untuk mendeteksi jeda.
            motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.active, self.generation == session else { return }
                    guard let data, error == nil else {
                        self.motionStatus = "error"
                        self.accumulator = MotionAccumulator()
                        return
                    }
                    let a = data.userAcceleration, g = data.gravity, r = data.rotationRate
                    let q = data.attitude.quaternion
                    let degrees = 180.0 / Double.pi
                    self.accumulator.append(MotionReading(
                        uptime: data.timestamp, ax: a.x * 9.80665, ay: a.y * 9.80665, az: a.z * 9.80665,
                        gx: g.x, gy: g.y, gz: g.z, rx: r.x, ry: r.y, rz: r.z,
                        roll: data.attitude.roll * degrees, pitch: data.attitude.pitch * degrees,
                        yaw: data.attitude.yaw * degrees, qw: q.w, qx: q.x, qy: q.y, qz: q.z))
                    self.motionStatus = "active"
                }
            }
        }
        barometerStatus = CMAltimeter.isRelativeAltitudeAvailable() ? "waiting" : "unavailable"
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: .main) { [weak self] data, error in
                MainActor.assumeIsolated {
                    guard let self, self.active, self.generation == session else { return }
                    guard let data, error == nil else {
                        self.barometerStatus = "error"
                        self.pressure = nil; self.altitude = nil; self.barometerUptime = nil; self.barometerDate = nil
                        return
                    }
                    self.pressure = data.pressure.doubleValue
                    self.altitude = data.relativeAltitude.doubleValue
                    self.barometerUptime = data.timestamp
                    // Konversi sekali saat diterima, agar fix barometer yang
                    // diulang tidak berubah timestamp karena jitter clock.
                    self.barometerDate = Date().addingTimeInterval(data.timestamp - ProcessInfo.processInfo.systemUptime)
                    self.barometerStatus = "active"
                }
            }
        }
        #if canImport(UIKit)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
        #endif
    }

    func stop() {
        guard active else { return }
        active = false
        generation = UUID()
        #if os(iOS)
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        #endif
        accumulator = MotionAccumulator()
        pressure = nil; altitude = nil; barometerUptime = nil; barometerDate = nil
        // Battery monitoring juga dipakai keep-alive Yamaha; jangan dimatikan
        // saat rekaman selesai selama koneksi motor mungkin masih berjalan.
    }

    func sample(placement: PhonePlacement) -> PhoneSensorSample {
        let uptime = ProcessInfo.processInfo.systemUptime
        var result = PhoneSensorSample()
        result.placement = placement
        result.motion = accumulator.take(at: uptime)
        result.motionStatus = result.motion == nil && motionStatus == "active" ? "stale" : motionStatus
        result.barometerStatus = barometerStatus
        if let time = barometerUptime {
            let age = uptime - time
            result.barometerAge = max(0, age)
            result.barometerTimestamp = barometerDate
            result.barometerUptime = time
            if age >= 0 && age <= 5 {
                result.pressureKPa = pressure
                result.relativeAltitude = altitude
            } else {
                result.barometerStatus = "stale"
            }
        }
        #if os(iOS)
        switch CMAltimeter.authorizationStatus() {
        case .denied, .restricted:
            result.barometerStatus = "denied"
        default: break
        }
        #if canImport(UIKit)
        let device = UIDevice.current
        if device.batteryLevel >= 0 { result.batteryPercent = Double(device.batteryLevel) * 100 }
        switch device.batteryState {
        case .charging: result.batteryState = "charging"
        case .full: result.batteryState = "full"
        case .unplugged: result.batteryState = "unplugged"
        default: break
        }
        result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: result.thermalState = "nominal"
        case .fair: result.thermalState = "fair"
        case .serious: result.thermalState = "serious"
        case .critical: result.thermalState = "critical"
        @unknown default: break
        }
        #endif
        #endif
        return result
    }
}
