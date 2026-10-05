import Foundation

@main struct PairingChecks {
    static func main() throws {
        // Data buatan saja; tidak membaca QR atau kredensial pengguna.
        let credentials = try PairingDecoder.decode("4290C8715A1D502936B43687")
        precondition(credentials.ccuid == "12345678901234")
        precondition(credentials.passKey == "567890")
        precondition(!credentials.bonded)
        try PairingDecoder.validate(credentials)
        for bad in ["", "short", String(repeating: "a", count: 25), String(repeating: "é", count: 12)] {
            do {
                _ = try PairingDecoder.decode(bad)
                preconditionFailure("Payload tidak valid diterima")
            } catch PairingError.invalidQR {}
        }
        let data = try JSONEncoder().encode(credentials)
        let restored = try JSONDecoder().decode(Credentials.self, from: data)
        precondition(restored == credentials)
        let invalid = Credentials(ccuid: credentials.ccuid, passKey: credentials.passKey,
                                  phoneUUID: String(repeating: "z", count: 32))
        do {
            try PairingDecoder.validate(invalid)
            preconditionFailure("UUID tidak valid diterima")
        } catch PairingError.invalidCredentials {}
        do {
            _ = try PairingDecoder.decode("4290C8715A1D502936B43687", matching: "00000000000000")
            preconditionFailure("QR motor berbeda diterima")
        } catch PairingError.wrongMotorcycle {}
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let before = try PairingFile.load(from: directory)
        precondition(before == nil, "Decode tidak boleh membuat file pairing")
        let motor = PairedMotorcycle(credentials: credentials, peripheralID: UUID())
        try PairingFile.saveAccepted(motor, in: directory)
        let saved = try PairingFile.load(from: directory)
        precondition(saved == motor && saved?.bonded == true)
        let file = directory.appendingPathComponent("secrets.local.json")
        let compatible = try JSONDecoder().decode(Credentials.self, from: Data(contentsOf: file))
        precondition(compatible == motor.credentials, "File harus kompatibel dengan format kredensial lama")
        do {
            try PairingFile.saveAccepted(PairedMotorcycle(credentials: invalid, peripheralID: UUID()), in: directory)
            preconditionFailure("Kredensial invalid tersimpan")
        } catch PairingError.invalidCredentials {}
        let unchanged = try PairingFile.load(from: directory)
        precondition(unchanged == motor, "Kegagalan tidak boleh mengganti pairing lama")
        try PairingFile.remove(from: directory)
        let removed = try PairingFile.load(from: directory)
        precondition(removed == nil)
        try PairingFile.remove(from: directory)
        print("Pairing decoder, CCU matching, private file round-trip and removal checks passed")
    }
}
