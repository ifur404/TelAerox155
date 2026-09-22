import Foundation

// nonisolated: dipakai dari closure Timer @Sendable dan callback CoreBluetooth
// di YConnectClient — lihat catatan yang sama di ClientState/KeepAlivePolicy.
// Proyek ini pakai SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, jadi tanpa ini
// class & method static di bawah ikut ter-infer MainActor-isolated.

/// Arah/tipe satu baris log diagnostik.
nonisolated public enum LogDirection: String {
    case tx = "TX"       // byte yang ditulis ke CCU (auth / keep-alive 0xA6)
    case rx = "RX"       // notifikasi mentah dari CCU (sebelum decode)
    case info = "INFO"   // narasi tahap koneksi (scan/connect/auth/disconnect)
    case scan = "SCAN"   // hasil discovery BLE
}

/// Buffer log diagnostik untuk satu sesi app (bukan per-koneksi) — supaya kalau
/// "connect sukses tapi timeout beberapa detik kemudian" kejadian, riwayat
/// LENGKAP (termasuk percobaan reconnect sebelumnya) masih ada buat dianalisa,
/// bukan cuma sesi yang sedang berjalan.
///
/// Thread-safe (dipanggil dari mana pun YConnectClient jalan — di app ini itu
/// main queue karena CBCentralManager dibuat dengan queue: nil, tapi dibuat
/// aman kalau nanti berubah).
nonisolated public final class DiagnosticLog: @unchecked Sendable {
    private var lines: [String] = []
    private let startTime = Date()
    private let maxLines: Int
    private let lock = NSLock()

    public init(maxLines: Int = 20_000) {
        self.maxLines = maxLines
    }

    public func log(_ direction: LogDirection, _ message: String) {
        lock.lock()
        let t = Date().timeIntervalSince(startTime)
        lines.append(String(format: "[%9.3fs] [%@] %@", t, direction.rawValue, message))
        if lines.count > maxLines {
            lines.removeFirst(lines.count - maxLines)
        }
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    /// Seluruh log sebagai teks siap salin/simpan.
    public func text() -> String {
        lock.lock(); defer { lock.unlock() }
        var header = "TelAerox155 — log diagnostik BLE\n"
        header += "Dibuat: \(ISO8601DateFormatter().string(from: Date()))\n"
        header += "Kredensial (ccuid/passKey/phoneUUID) DISENSOR — aman dibagikan.\n"
        header += String(repeating: "-", count: 60) + "\n"
        return header + lines.joined(separator: "\n") + "\n"
    }

    public func clear() {
        lock.lock()
        lines.removeAll()
        lock.unlock()
    }

    // MARK: - Helper format

    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
