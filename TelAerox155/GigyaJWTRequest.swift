import Foundation
import CryptoKit

/// Request token memakai sesi pengguna yang sah, bukan passKey motor.
/// Canonical signing dicocokkan dengan SigUtils SDK resmi SAP; belum uji live.
nonisolated enum GigyaJWTRequest {
    static let endpoint = URL(string: "https://accounts.eu1.gigya.com/accounts.getJWT")!
    // Public site identifier dari APK, bukan secret akun pengguna.
    static let siteKey = "4_gD4kduJqmH-Nu-0Wl_NqDw"

    static func make(sessionToken: String, sessionSecret: String, timestamp: Int,
                     nonce: String) throws -> URLRequest {
        guard !sessionToken.isEmpty, !nonce.isEmpty,
              let key = Data(base64Encoded: sessionSecret), !key.isEmpty else {
            throw YamahaPairingError.loginRequired
        }
        var params = ["apiKey": siteKey, "expiration": "1800", "format": "json",
                      "httpStatusCodes": "false", "nonce": nonce, "oauth_token": sessionToken,
                      "sdk": "Android_7.4.0", "targetEnv": "mobile", "timestamp": String(timestamp)]
        let unsigned = form(params)
        let canonical = "POST&" + encode(endpoint.absoluteString) + "&" + encode(unsigned)
        let signature = HMAC<Insecure.SHA1>.authenticationCode(for: Data(canonical.utf8),
                                                             using: SymmetricKey(data: key))
        params["sig"] = Data(signature).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue(siteKey, forHTTPHeaderField: "apikey")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(form(params).utf8)
        return request
    }

    static func token(from data: Data, statusCode: Int) throws -> String {
        struct Response: Decodable { let errorCode: Int; let id_token: String? }
        guard statusCode == 200, data.count <= 1_048_576,
              let response = try? JSONDecoder().decode(Response.self, from: data) else {
            throw YamahaPairingError.invalidResponse
        }
        guard response.errorCode == 0, let token = response.id_token,
              !token.isEmpty, !token.contains(where: { $0.isWhitespace }) else {
            throw YamahaPairingError.loginRequired
        }
        return token
    }

    private static func form(_ params: [String: String]) -> String {
        params.keys.sorted().map { "\($0)=\(encode(params[$0]!))" }.joined(separator: "&")
    }
    private static func encode(_ value: String) -> String {
        value.utf8.map { byte in
            if (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                || [45, 46, 95, 126].contains(byte) {
                return String(UnicodeScalar(byte))
            }
            return String(format: "%%%02X", byte)
        }.joined()
    }
}
