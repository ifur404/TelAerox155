import Foundation

/// Pembacaan nilai numerik dari buffer byte.
///
/// PENTING soal endianness (dikonfirmasi dari capture Aerox-155.pklg):
/// - Payload telemetri (frame 0x55 dst) = **BIG-ENDIAN**.
///   Bukti: odometer `00 06 b9 f3` BE = 440819 ÷10 = 44.081,9 km (masuk akal);
///   LE = 408.898.918 km (mustahil).
/// - Header auth (0xAA byte[2..3]) & panjang L2CAP = little-endian — tapi itu
///   ditangani terpisah, bukan lewat pembaca ini.
nonisolated enum BinaryReader {

    static func u8(_ b: [UInt8], _ o: Int) -> UInt8? {
        guard o >= 0, o < b.count else { return nil }
        return b[o]
    }

    static func s8(_ b: [UInt8], _ o: Int) -> Int? {
        guard let v = u8(b, o) else { return nil }
        return v >= 128 ? Int(v) - 256 : Int(v)
    }

    static func u16be(_ b: [UInt8], _ o: Int) -> Int? {
        guard o >= 0, o + 1 < b.count else { return nil }
        return (Int(b[o]) << 8) | Int(b[o + 1])
    }

    static func s16be(_ b: [UInt8], _ o: Int) -> Int? {
        guard let v = u16be(b, o) else { return nil }
        return v >= 0x8000 ? v - 0x10000 : v
    }

    static func u32be(_ b: [UInt8], _ o: Int) -> UInt32? {
        guard o >= 0, o + 3 < b.count else { return nil }
        return (UInt32(b[o]) << 24) | (UInt32(b[o + 1]) << 16)
             | (UInt32(b[o + 2]) << 8) | UInt32(b[o + 3])
    }

    static func s32be(_ b: [UInt8], _ o: Int) -> Int? {
        guard let v = u32be(b, o) else { return nil }
        return v >= 0x8000_0000 ? Int(v) - 0x1_0000_0000 : Int(v)
    }
}
