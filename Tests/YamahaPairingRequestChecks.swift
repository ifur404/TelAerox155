import Foundation

/// Server dan radio palsu; tidak ada request jaringan atau pembacaan rahasia pengguna.
@MainActor
private final class FakeYamaha {
    var paths: [String] = []
    var status = 200
    var pairingStatus = 200
    var wrongDevice = false
    var malformed = false
    var invalidKey = false
    var failNetwork = false

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        precondition(request.httpMethod == "GET")
        precondition(request.url?.host == "glocal-eu.yamaha-motorcycle-connect.com")
        precondition(request.value(forHTTPHeaderField: "jwtKey") == "synthetic-session-token")
        precondition(request.value(forHTTPHeaderField: "header_appli_id") == "0000")
        precondition(request.value(forHTTPHeaderField: "Authorization") == nil)
        precondition(request.url?.query == nil && request.httpBody == nil)
        let path = request.url!.path
        paths.append(path)
        if failNetwork { throw URLError(.notConnectedToInternet) }
        let body: Data
        let code: Int
        if path == "/model_info/12345678901234" {
            body = Data(#"{"vehicleInfo":{"vinCd":"SYNTHETICVIN123456"}}"#.utf8)
            code = status
        } else {
            precondition(path == "/pairing_info/SYNTHETICVIN123456")
            body = try JSONSerialization.data(withJSONObject: [
                "ccuId": wrongDevice ? "00000000000000" : "12345678901234",
                "passKey": invalidKey ? "bad" : "567890"])
            code = pairingStatus
        }
        return (malformed ? Data("invalid-json".utf8) : body,
                HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!)
    }
}

@main struct YamahaPairingRequestChecks {
    @MainActor static func main() async throws {
        let root = CommandLine.arguments.count > 1
            ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
            : FileManager.default.temporaryDirectory.appendingPathComponent("yamaha-pairing-proof-\(UUID().uuidString)")
        // Setiap run butuh direktori baru; jangan menimpa hasil atau file pengguna.
        guard !FileManager.default.fileExists(atPath: root.path) else {
            print("Gunakan direktori output baru yang belum ada.")
            exit(2)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var passed = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label)
            passed += 1
            print("PASS: \(label)")
        }
        func exists(_ folder: URL) -> Bool {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent("secrets.local.json").path)
        }
        func ack(_ flag: UInt8 = 1) -> [UInt8] {
            var raw: [UInt8] = [0x5A, 1, 1, 0x7F, 1, flag, 0]
            raw.append(Checksum.compute(raw))
            return raw
        }
        let jwtRequest = try GigyaJWTRequest.make(sessionToken: "synthetic token/+",
            sessionSecret: Data("synthetic-session-secret".utf8).base64EncodedString(),
            timestamp: 1_700_000_000, nonce: "synthetic nonce+test")
        let jwtBody = String(decoding: jwtRequest.httpBody!, as: UTF8.self)
        check(jwtRequest.httpMethod == "POST" && jwtRequest.url == GigyaJWTRequest.endpoint
            && jwtBody.contains("expiration=1800") && jwtBody.contains("sig=nXTqWUnWaKpC_L94VukPBXlgwH0%3D"),
            "Signature getJWT cocok dengan vektor HMAC independen, termasuk encoding karakter khusus")
        let jwt = try GigyaJWTRequest.token(from: Data(#"{"errorCode":0,"id_token":"synthetic-session-token"}"#.utf8), statusCode: 200)
        check(jwt == "synthetic-session-token", "id_token respons Gigya menjadi jwtKey Yamaha")
        do {
            _ = try GigyaJWTRequest.make(sessionToken: "", sessionSecret: "", timestamp: 0, nonce: "test")
            preconditionFailure("Sesi kosong tidak boleh menjadi request signed")
        } catch YamahaPairingError.loginRequired { check(true, "getJWT memerlukan sesi pengguna") }
        do {
            _ = try GigyaJWTRequest.token(from: Data(#"{"errorCode":403005,"id_token":"untrusted"}"#.utf8), statusCode: 200)
            preconditionFailure("HTTP 200 Gigya dengan errorCode harus ditolak")
        } catch YamahaPairingError.loginRequired { check(true, "Error aplikasi Gigya tidak dianggap sukses HTTP 200") }
        let selectedECU = UUID()
        let server = FakeYamaha()
        let api = YamahaPairingAPI(send: server.send)
        let credentials = try await api.credentials(ccuid: "12345678901234", fourDigits: "1234",
                                                     jwtToken: "synthetic-session-token")
        check(server.paths == ["/model_info/12345678901234", "/pairing_info/SYNTHETICVIN123456"],
              "4 digit: urutan GET, header sesi, dan VIN dari respons benar")
        check(credentials.ccuid == "12345678901234" && credentials.passKey == "567890",
              "Kredensial dibaca dari respons Yamaha, bukan dihitung dari empat digit")
        let manualFolder = root.appendingPathComponent("manual-success")
        let manual = try PairingConfirmation(credentials: credentials, peripheralID: selectedECU, directory: manualFolder)
        check(!exists(manualFolder), "Respons cloud saja belum membuat secrets.local.json")
        let authFrame = try AuthFrame.build(credentials, counter: 0)
        check(authFrame.count == 60 && authFrame[0] == 0xAA && Checksum.verify(authFrame),
              "Kredensial dapat membentuk frame auth BLE yang valid")
        let accepted = try manual.receiveAuthReply(ack(), from: selectedECU)
        let saved = try PairingFile.load(from: manualFolder)
        check(accepted && exists(manualFolder) && saved?.peripheralID == selectedECU && saved?.bonded == true,
              "ACK diterima dari ECU terpilih: secrets.local.json benar-benar dibuat")
        let compatible = try JSONDecoder().decode(Credentials.self,
            from: Data(contentsOf: manualFolder.appendingPathComponent("secrets.local.json")))
        check(compatible.ccuid == credentials.ccuid && compatible.passKey == credentials.passKey
                && compatible.phoneUUID == credentials.phoneUUID,
              "File hasil dapat dibaca client untuk koneksi berikutnya")
        let duplicate = try manual.receiveAuthReply(ack(), from: selectedECU)
        check(!duplicate, "ACK duplikat tidak menyimpan ulang")

        let qrFolder = root.appendingPathComponent("qr-success")
        let qrCredentials = try PairingDecoder.decode("4290C8715A1D502936B43687", matching: "12345678901234")
        let qr = try PairingConfirmation(credentials: qrCredentials, peripheralID: selectedECU, directory: qrFolder)
        check(!exists(qrFolder), "QR cocok belum membuat file sebelum auth")
        let qrAccepted = try qr.receiveAuthReply(ack(), from: selectedECU)
        check(qrAccepted && exists(qrFolder), "QR + ECU terpilih + ACK berhasil menghasilkan file")

        for (label, raw, id) in [
            ("auth ditolak", ack(0), selectedECU),
            ("ACK dari ECU lain", ack(), UUID()),
            ("frame terpotong", Array(ack().prefix(4)), selectedECU),
            ("checksum rusak", Array(ack().dropLast()) + [0], selectedECU),
            ("frame bukan auth", [UInt8](repeating: 0, count: 8), selectedECU)
        ] {
            let folder = root.appendingPathComponent(UUID().uuidString)
            let pending = try PairingConfirmation(credentials: credentials, peripheralID: selectedECU, directory: folder)
            let result = try pending.receiveAuthReply(raw, from: id)
            check(!result && !exists(folder), "Tidak ada file: \(label)")
        }
        let cancelledFolder = root.appendingPathComponent("cancelled")
        let cancelled = try PairingConfirmation(credentials: credentials, peripheralID: selectedECU, directory: cancelledFolder)
        cancelled.cancel()
        let late = try cancelled.receiveAuthReply(ack(), from: selectedECU)
        check(!late && !exists(cancelledFolder), "Cancel/timeout: ACK terlambat tidak membuat file")
        let oldData = try Data(contentsOf: manualFolder.appendingPathComponent("secrets.local.json"))
        let replacement = try PairingConfirmation(credentials: credentials, peripheralID: selectedECU, directory: manualFolder)
        _ = try replacement.receiveAuthReply(ack(0), from: selectedECU)
        let afterData = try Data(contentsOf: manualFolder.appendingPathComponent("secrets.local.json"))
        check(oldData == afterData, "Auth pairing baru ditolak: file lama tetap utuh")
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data("synthetic".utf8).write(to: blocked)
        let cannotSave = try PairingConfirmation(credentials: credentials, peripheralID: selectedECU, directory: blocked)
        do {
            _ = try cannotSave.receiveAuthReply(ack(), from: selectedECU)
            preconditionFailure("Kegagalan penyimpanan harus dilaporkan")
        } catch PairingError.storage {
            check(!cannotSave.isPending, "Kegagalan menulis file tidak dianggap pairing berhasil")
        }

        for (status, expected) in [(401, YamahaPairingError.loginRequired), (403, .loginRequired),
                                    (404, .notFound), (429, .rateLimited), (500, .serviceUnavailable),
                                    (302, .serviceUnavailable)] {
            let bad = FakeYamaha(); bad.status = status
            do {
                _ = try await YamahaPairingAPI(send: bad.send).credentials(ccuid: "12345678901234", fourDigits: "1234", jwtToken: "synthetic-session-token")
                preconditionFailure("HTTP gagal diterima")
            } catch let error as YamahaPairingError {
                check(error == expected && bad.paths.count == 1, "HTTP \(status): berhenti sebelum request passKey")
            }
        }
        let scenarios: [(String, String, String, (FakeYamaha) -> Void, YamahaPairingError)] = [
            ("kode rangka salah", "9999", "synthetic-session-token", { _ in }, .codeMismatch),
            ("kode kurang panjang", "123", "synthetic-session-token", { _ in }, .invalidCode),
            ("belum login", "1234", "", { _ in }, .loginRequired),
            ("CCUID respons berbeda", "1234", "synthetic-session-token", { $0.wrongDevice = true }, .deviceMismatch),
            ("JSON respons rusak", "1234", "synthetic-session-token", { $0.malformed = true }, .invalidResponse),
            ("jaringan putus", "1234", "synthetic-session-token", { $0.failNetwork = true }, .network),
            ("sesi habis pada request kedua", "1234", "synthetic-session-token", { $0.pairingStatus = 401 }, .loginRequired)
        ]
        for (name, code, token, setup, expected) in scenarios {
            let bad = FakeYamaha(); setup(bad)
            do {
                _ = try await YamahaPairingAPI(send: bad.send).credentials(ccuid: "12345678901234", fourDigits: code, jwtToken: token)
                preconditionFailure("Skenario gagal diterima")
            } catch let error as YamahaPairingError {
                check(error == expected, "Ditolak: \(name)")
                if expected == .invalidCode || token.isEmpty { precondition(bad.paths.isEmpty) }
                if expected == .codeMismatch { precondition(bad.paths.count == 1) }
            }
        }
        print("\(passed) checks passed. SYNTHETIC data / mocked Yamaha and BLE, no live account or motorcycle.")
        print("Synthetic generated files: \(root.path)")
    }
}
