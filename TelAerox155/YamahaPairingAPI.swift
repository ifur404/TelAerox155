import Foundation

/// Kontrak REST hasil pembacaan APK 1.0.14; belum diuji memakai sesi akun nyata.
/// Token hanya dipakai di memori dan tidak ditulis ke file pairing atau log.
@MainActor
final class YamahaPairingAPI {
    typealias Send = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let send: Send

    init(send: @escaping Send) { self.send = send }

    convenience init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration, delegate: NoPairingRedirects(), delegateQueue: nil)
        self.init { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw YamahaPairingError.invalidResponse }
            return (data, http)
        }
    }

    func credentials(ccuid: String, fourDigits: String, jwtToken: String) async throws -> Credentials {
        guard ccuid.count == 14, ccuid.utf8.allSatisfy(Self.isAlphaNumeric) else {
            throw YamahaPairingError.invalidDevice
        }
        guard fourDigits.utf8.count == 4,
              fourDigits.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw YamahaPairingError.invalidCode
        }
        guard !jwtToken.isEmpty, !jwtToken.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw YamahaPairingError.loginRequired
        }
        let model: ModelInfoResponse = try await get("model_info/\(ccuid)", token: jwtToken)
        let vin = model.vehicleInfo.vinCd
        guard vin.count >= 6, vin.count <= 32, vin.utf8.allSatisfy(Self.isAlphaNumeric) else {
            throw YamahaPairingError.invalidResponse
        }
        guard String(vin.dropLast(2).suffix(4)) == fourDigits else {
            throw YamahaPairingError.codeMismatch
        }
        try Task.checkCancellation()
        let pairing: PairingInfoResponse = try await get("pairing_info/\(vin)", token: jwtToken)
        guard pairing.ccuId == ccuid else { throw YamahaPairingError.deviceMismatch }
        let result = Credentials(ccuid: pairing.ccuId, passKey: pairing.passKey,
            phoneUUID: UUID().uuidString.replacingOccurrences(of: "-", with: ""), bonded: false)
        try PairingDecoder.validate(result)
        return result
    }

    private static func isAlphaNumeric(_ char: UInt8) -> Bool {
        (48...57).contains(char) || (65...90).contains(char) || (97...122).contains(char)
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        // Host tetap; input divalidasi alfanumerik sebelum digunakan sebagai path.
        let url = URL(string: "https://glocal-eu.yamaha-motorcycle-connect.com/\(path)")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.setValue(token, forHTTPHeaderField: "jwtKey")
        request.setValue("0000", forHTTPHeaderField: "header_appli_id")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await send(request)
        } catch is CancellationError { throw CancellationError() }
        catch { throw YamahaPairingError.network }
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: break
        case 401, 403: throw YamahaPairingError.loginRequired
        case 404: throw YamahaPairingError.notFound
        case 429: throw YamahaPairingError.rateLimited
        default: throw YamahaPairingError.serviceUnavailable
        }
        guard data.count <= 1_048_576 else { throw YamahaPairingError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw YamahaPairingError.invalidResponse }
    }

    private struct ModelInfoResponse: Decodable {
        struct VehicleInfo: Decodable { let vinCd: String }
        let vehicleInfo: VehicleInfo
    }
    private struct PairingInfoResponse: Decodable {
        let ccuId: String
        let passKey: String
    }
}

/// Jangan teruskan header sesi ke URL redirect, termasuk host lain.
private final class NoPairingRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum YamahaPairingError: Error, LocalizedError, Equatable {
    case invalidDevice, invalidCode, loginRequired, codeMismatch, deviceMismatch
    case invalidResponse, notFound, rateLimited, serviceUnavailable, network
    var errorDescription: String? {
        switch self {
        case .invalidDevice: return "Identitas ECU BLE tidak valid."
        case .invalidCode: return "Masukkan empat digit nomor rangka."
        case .loginRequired: return "Sesi Yamaha diperlukan atau sudah berakhir."
        case .codeMismatch: return "Empat digit tidak cocok dengan nomor rangka motor terpilih."
        case .deviceMismatch: return "Kredensial respons Yamaha bukan untuk ECU terpilih."
        case .invalidResponse: return "Respons pairing Yamaha tidak sesuai format yang didukung."
        case .notFound: return "Data motor tidak ditemukan di layanan Yamaha."
        case .rateLimited: return "Layanan Yamaha membatasi permintaan. Coba lagi nanti."
        case .serviceUnavailable: return "Layanan pairing Yamaha tidak tersedia."
        case .network: return "Permintaan pairing Yamaha gagal. Periksa koneksi internet."
        }
    }
}
