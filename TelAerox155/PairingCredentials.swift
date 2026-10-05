import Foundation

/// Decoder mengikuti handler QR CCU APK; belum tervalidasi dengan semua stiker.
nonisolated enum PairingDecoder {
    static func decode(_ payload: String) throws -> Credentials {
        let chars = Array(payload.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        guard chars.count == 24, chars.allSatisfy({ $0 >= 33 && $0 <= 126 }) else {
            throw PairingError.invalidQR
        }
        let positions = [8,15,21,1,13,18,7,23,3,14,11,2,17,20,9,22,24,6,16,4,10,19,5,12]
        let decoded = positions.map { chars[$0 - 1] }
        let credential = Credentials(
            ccuid: String(decoding: decoded.prefix(14), as: UTF8.self),
            passKey: String(decoding: decoded[14..<20], as: UTF8.self),
            phoneUUID: UUID().uuidString.replacingOccurrences(of: "-", with: ""), bonded: false)
        try validate(credential)
        return credential
    }

    static func decode(_ payload: String, matching ccuid: String) throws -> Credentials {
        let credentials = try decode(payload)
        guard credentials.ccuid == ccuid else { throw PairingError.wrongMotorcycle }
        return credentials
    }

    static func validate(_ credential: Credentials) throws {
        guard credential.ccuid.utf8.count == 14,
              credential.passKey.utf8.count == 6,
              credential.phoneUUID.utf8.count == 32,
              credential.ccuid.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              credential.passKey.utf8.allSatisfy({ $0 >= 33 && $0 <= 126 }),
              credential.phoneUUID.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            throw PairingError.invalidCredentials
        }
    }
}

nonisolated enum PairingError: LocalizedError {
    case invalidQR, invalidCredentials, storage, wrongMotorcycle
    var errorDescription: String? {
        switch self {
        case .invalidQR: return "QR tidak sesuai format CCU 24 karakter yang didukung."
        case .invalidCredentials: return "Format kredensial tidak valid."
        case .storage: return "Data pairing tidak dapat disimpan atau dibaca. Buka kunci iPhone dan coba lagi."
        case .wrongMotorcycle: return "QR tidak cocok dengan motor Bluetooth yang dipilih. Pilih motor atau QR yang sesuai."
        }
    }
}

/// File dibuat hanya setelah CCU menerima auth, bukan saat input QR selesai.
/// Disimpan di Application Support agar tidak terlihat lewat Files/sharing rekaman.
struct PairedMotorcycle: Codable, Equatable {
    let ccuid: String
    let passKey: String
    let phoneUUID: String
    let bonded: Bool
    let peripheralID: UUID
    let pairedAt: Date

    init(credentials: Credentials, peripheralID: UUID) {
        ccuid = credentials.ccuid
        passKey = credentials.passKey
        phoneUUID = credentials.phoneUUID
        bonded = true
        self.peripheralID = peripheralID
        pairedAt = Date()
    }
    var credentials: Credentials {
        Credentials(ccuid: ccuid, passKey: passKey, phoneUUID: phoneUUID, bonded: bonded)
    }
}

enum PairingFile {
    static func directory() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Pairing", isDirectory: true)
    }
    static func load(from directory: URL? = nil) throws -> PairedMotorcycle? {
        let folder = try directory ?? self.directory()
        let url = folder.appendingPathComponent("secrets.local.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let motor = try JSONDecoder().decode(PairedMotorcycle.self, from: Data(contentsOf: url))
            try PairingDecoder.validate(motor.credentials)
            return motor
        } catch { throw PairingError.storage }
    }
    static func saveAccepted(_ motor: PairedMotorcycle, in directory: URL? = nil) throws {
        try PairingDecoder.validate(motor.credentials)
        do {
            var folder = try directory ?? self.directory()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try folder.setResourceValues(values)
            let data = try JSONEncoder().encode(motor)
            let url = folder.appendingPathComponent("secrets.local.json")
            #if os(iOS)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            #else
            try data.write(to: url, options: .atomic)
            #endif
        } catch { throw PairingError.storage }
    }
    static func remove(from directory: URL? = nil) throws {
        let folder = try directory ?? self.directory()
        let url = folder.appendingPathComponent("secrets.local.json")
        if FileManager.default.fileExists(atPath: url.path) {
            do { try FileManager.default.removeItem(at: url) }
            catch { throw PairingError.storage }
        }
    }
}
