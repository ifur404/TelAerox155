import Foundation

/// Checksum protokol Y-Connect / SCCU1.
///
/// Terbukti terhadap capture asli (Aerox-155.pklg): berlaku 100% di SEMUA frame
/// RX setelah frame utuh (StartProcessing, 0x55, 0x56, 0x59, 0x5B) dan TX
/// (auth 0xAA, poll 0xA6).
///
/// Formula: `checksum = (256 - (sum(bytes[0..<n-1]) & 0xFF)) & 0xFF`, disimpan di
/// byte terakhir frame.
public enum Checksum {

    /// Hitung checksum dari deretan byte (tanpa byte checksum itu sendiri).
    public static func compute<S: Sequence>(_ bytes: S) -> UInt8 where S.Element == UInt8 {
        let sum = bytes.reduce(0) { ($0 &+ Int($1)) }
        return UInt8((256 - (sum & 0xFF)) & 0xFF)
    }

    /// Verifikasi frame utuh: byte terakhir harus == checksum dari byte sebelumnya.
    public static func verify(_ frame: [UInt8]) -> Bool {
        guard frame.count >= 2 else { return false }
        return compute(frame[0..<(frame.count - 1)]) == frame[frame.count - 1]
    }
}
