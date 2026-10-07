import Foundation

/// Filter tampilan Home saja. Data mentah dan ritme komunikasi BLE tidak berubah.
nonisolated struct HomeTelemetry {
    let snapshot: TelemetrySnapshot
    let isStreaming: Bool
    let now: Date

    func value(_ key: String) -> Double? {
        guard isStreaming, let value = snapshot.value(key), value.isFinite,
              let received = snapshot.receivedAt[key] else { return nil }
        let age = now.timeIntervalSince(received)
        // Counter kendaraan bukan sensor streaming (sama seperti ekspor CSV).
        let counter = key == "ecuPowerOnTime" || key == "ignOnCount"
        guard age >= -1, counter || age <= 5 else { return nil }
        return value
    }

    var missingPrimaryData: Bool { value("rpm") == nil || value("speed") == nil }

    var diagnosticValues: [Double] {
        ["fiError", "dtc", "fiWarningLamp"].compactMap { key in
            guard let value = value(key), value >= 0 else { return nil }
            return value
        }
    }

    var hasDiagnosticWarning: Bool { diagnosticValues.contains { $0 > 0 } }
    var hasCompleteDiagnostics: Bool { diagnosticValues.count == 3 }
}
