import Foundation

/// Gerbang penyimpanan yang sama dipakai aplikasi dan tes: harus ada balasan
/// auth valid dari peripheral terpilih. Kandidat tidak disimpan saat dibuat.
@MainActor
final class PairingConfirmation {
    private(set) var credentials: Credentials
    let peripheralID: UUID
    private let directory: URL?
    private(set) var isPending = true

    init(credentials: Credentials, peripheralID: UUID, directory: URL? = nil) throws {
        try PairingDecoder.validate(credentials)
        self.credentials = credentials
        self.peripheralID = peripheralID
        self.directory = directory
    }
    func cancel() { isPending = false }

    @discardableResult
    func receiveAuthReply(_ raw: [UInt8], from id: UUID) throws -> Bool {
        guard isPending, id == peripheralID, raw.first == 0x5A,
              let reply = StartProcessing(raw), reply.accepted else { return false }
        // Setelah gagal menulis, jangan menerima ACK terlambat sebagai retry baru.
        isPending = false
        try PairingFile.saveAccepted(PairedMotorcycle(credentials: credentials, peripheralID: id), in: directory)
        return true
    }
}
