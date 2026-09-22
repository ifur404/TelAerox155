import Foundation

/// Kredensial motor — SATU-SATUNYA hal yang perlu ditulis ke CCU.
/// Diperoleh sekali dari capture app resmi (lihat secrets.local.json).
nonisolated public struct Credentials: Codable, Equatable {
    public let ccuid: String       // 14 char ASCII
    public let passKey: String     // 6 char ASCII
    public let phoneUUID: String   // 32 hex char (UUID tanpa tanda hubung)
    public var bonded: Bool        // true = pakai flag 0 (sudah pairing)

    public init(ccuid: String, passKey: String, phoneUUID: String, bonded: Bool = true) {
        self.ccuid = ccuid
        self.passKey = passKey
        self.phoneUUID = phoneUUID
        self.bonded = bonded
    }
}

nonisolated public enum AuthError: Error, Equatable {
    case badCCUIDLength(Int)      // harus 14
    case badPassKeyLength(Int)    // harus 6
    case badPhoneUUIDLength(Int)  // harus 32
    case nonASCII
}

/// Pembangun frame autentikasi 0xAA (60 byte).
///
/// Layout (dari APK v/a.java, dikonfirmasi capture):
/// [0]=0xAA [1]=0x01 [2..3]=0x7F00 (LE) [4]=0x35
/// [5..18]=ccuid [19..24]=passKey [25..56]=phoneUUID
/// [57]=bondingFlag (0=bonded, 1=first) [58]=counter [59]=checksum
nonisolated public enum AuthFrame {

    public static let length = 60

    public static func build(_ cred: Credentials, counter: UInt8 = 0) throws -> [UInt8] {
        return try build(ccuid: cred.ccuid, passKey: cred.passKey,
                         phoneUUID: cred.phoneUUID, bonded: cred.bonded, counter: counter)
    }

    public static func build(ccuid: String, passKey: String, phoneUUID: String,
                             bonded: Bool, counter: UInt8 = 0) throws -> [UInt8] {
        guard let ccuidB = ccuid.data(using: .ascii).map([UInt8].init),
              let passB = passKey.data(using: .ascii).map([UInt8].init),
              let uuidB = phoneUUID.data(using: .ascii).map([UInt8].init) else {
            throw AuthError.nonASCII
        }
        guard ccuidB.count == 14 else { throw AuthError.badCCUIDLength(ccuidB.count) }
        guard passB.count == 6 else { throw AuthError.badPassKeyLength(passB.count) }
        guard uuidB.count == 32 else { throw AuthError.badPhoneUUIDLength(uuidB.count) }

        var b = [UInt8](repeating: 0, count: length)
        b[0] = 0xAA
        b[1] = 0x01
        b[2] = 0x7F; b[3] = 0x00   // header LE
        b[4] = 0x35
        b.replaceSubrange(5..<19, with: ccuidB)
        b.replaceSubrange(19..<25, with: passB)
        b.replaceSubrange(25..<57, with: uuidB)
        b[57] = bonded ? 0 : 1
        b[58] = counter
        b[59] = Checksum.compute(b[0..<59])
        return b
    }
}

/// Hasil parse balasan StartProcessing 0x5A (8 byte).
nonisolated public struct StartProcessing {
    public let raw: [UInt8]
    public var flag: UInt8 { raw.count > 5 ? raw[5] : 0 }
    public var accepted: Bool { flag == 1 }

    /// Parse + verifikasi. Nil bila panjang/checksum salah atau bukan 0x5A.
    public init?(_ raw: [UInt8]) {
        guard raw.count == 8, raw[0] == 0x5A, Checksum.verify(raw) else { return nil }
        self.raw = raw
    }
}
