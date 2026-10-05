import Foundation

// nonisolated: dipakai dari closure Timer @Sendable dan callback CoreBluetooth
// di YConnectClient — lihat catatan yang sama di ClientState/KeepAlivePolicy.
// Proyek ini pakai SWIFT_DEFAULT_ACTOR_ISOLATION=MainActor, jadi tanpa ini
// tipe & method static di bawah ikut ter-infer MainActor-isolated.

/// Arah/tipe satu baris log diagnostik.
nonisolated public enum LogDirection: String {
    case tx = "TX"       // byte yang ditulis ke CCU (auth / keep-alive 0xA6)
    case rx = "RX"       // notifikasi mentah dari CCU (sebelum decode)
    case info = "INFO"   // narasi tahap koneksi (scan/connect/auth/disconnect)
    case scan = "SCAN"   // hasil discovery BLE
}

/// Helper format byte untuk rekaman BLE mentah. Tidak menyimpan buffer log.
nonisolated public enum BLELogFormat {
    public static func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
