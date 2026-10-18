import Foundation
import CryptoKit
import Security

enum CloudTokenRefresher {
    struct Authorization: Sendable {
        let url: URL
        let verifier: String
        let clientID: String
    }
    struct BaiduDeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: String
        let expiresIn: Int
        let interval: Int
        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code"
            case verificationURL = "verification_url"
            case expiresIn = "expires_in", interval
        }
    }
    struct Open115Authorization: Sendable {
        let uid: String
        let qrCode: String
        let verifier: String
    }
    struct Token: Decodable, Sendable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        init(accessToken: String, expiresIn: Int, refreshToken: String? = nil) {
            self.accessToken = accessToken
            self.expiresIn = expiresIn
            self.refreshToken = refreshToken
        }
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
            case refreshToken = "refresh_token"
        }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            accessToken = try values.decode(String.self, forKey: .accessToken)
            refreshToken = try values.decodeIfPresent(String.self, forKey: .refreshToken)
            if let number = try? values.decode(Int.self, forKey: .expiresIn) {
                expiresIn = number
            } else {
                expiresIn = Int(try values.decode(String.self, forKey: .expiresIn)) ?? 0
            }
        }
    }

    static func refresh(provider: CloudProvider, clientID: String,
                        refreshToken: String, clientSecret: String? = nil) async throws -> Token {
        guard !refreshToken.isEmpty else { throw TokenError.missingCredentials }
        if provider == .pan115 {
            var request = URLRequest(url: URL(string: "https://passportapi.115.com/open/refreshToken")!)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            var form = URLComponents()
            form.queryItems = [URLQueryItem(name: "refresh_token", value: refreshToken)]
            request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
            return try await tokenResponse(request)
        }
        if provider == .guangyaPan {
            var request = URLRequest(url: URL(string: "https://account.guangyapan.com/v1/auth/token")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("401", forHTTPHeaderField: "x-action")
            let deviceID = GuangyaClient.deviceID()
            request.setValue("aMe-8VSlkrbQXpUR", forHTTPHeaderField: "x-client-id")
            request.setValue("0.0.1", forHTTPHeaderField: "x-client-version")
            request.setValue(deviceID, forHTTPHeaderField: "x-device-id")
            request.setValue("PC-Chrome", forHTTPHeaderField: "x-device-name")
            request.setValue("wdi10.\(deviceID)\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())",
                             forHTTPHeaderField: "x-device-sign")
            request.setValue("https://www.guangyapan.com", forHTTPHeaderField: "Origin")
            request.setValue("https://www.guangyapan.com/", forHTTPHeaderField: "Referer")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "client_id": "aMe-8VSlkrbQXpUR", "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ])
            return try await tokenResponse(request)
        }
        guard !clientID.isEmpty else { throw TokenError.missingCredentials }
        if provider == .baiduPan {
            guard let clientSecret, !clientSecret.isEmpty else { throw TokenError.missingCredentials }
            var components = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/token")!
            components.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"),
                                     URLQueryItem(name: "refresh_token", value: refreshToken),
                                     URLQueryItem(name: "client_id", value: clientID),
                                     URLQueryItem(name: "client_secret", value: clientSecret)]
            return try await tokenResponse(URLRequest(url: components.url!))
        }
        if provider == .pan123 {
            var request = URLRequest(url: URL(string: "https://open-api.123pan.com/api/v1/access_token")!)
            request.httpMethod = "POST"
            request.timeoutInterval = 20
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: [
                "clientID": clientID, "clientSecret": refreshToken
            ])
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (json["code"] as? NSNumber)?.intValue == 0,
                  let value = json["data"] as? [String: Any],
                  let access = value["accessToken"] as? String,
                  let expiry = value["expiredAt"] as? String,
                  let date = ISO8601DateFormatter().date(from: expiry) else {
                throw TokenError.refreshFailed
            }
            return Token(accessToken: access,
                         expiresIn: max(1, Int(date.timeIntervalSinceNow)),
                         refreshToken: refreshToken)
        }
        let endpoint: URL
        switch provider {
        case .dropbox: endpoint = URL(string: "https://api.dropboxapi.com/oauth2/token")!
        case .googleDrive: endpoint = URL(string: "https://oauth2.googleapis.com/token")!
        case .pan115, .pan123, .baiduPan, .guangyaPan:
            throw TokenError.refreshFailed
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                           URLQueryItem(name: "refresh_token", value: refreshToken),
                           URLQueryItem(name: "grant_type", value: "refresh_token")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 200, data.count < 1_000_000 else { throw TokenError.refreshFailed }
        let token = try JSONDecoder().decode(Token.self, from: data)
        guard !token.accessToken.isEmpty, token.expiresIn > 0 else { throw TokenError.refreshFailed }
        return token
    }

    static func beginBaidu(clientID: String) async throws -> BaiduDeviceCode {
        guard !clientID.isEmpty else { throw TokenError.missingCredentials }
        var components = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/device/code")!
        components.queryItems = [URLQueryItem(name: "response_type", value: "device_code"),
                                 URLQueryItem(name: "client_id", value: clientID),
                                 URLQueryItem(name: "scope", value: "basic,netdisk")]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TokenError.refreshFailed }
        return try JSONDecoder().decode(BaiduDeviceCode.self, from: data)
    }

    static func exchangeBaidu(clientID: String, clientSecret: String,
                              deviceCode: String) async throws -> Token? {
        var components = URLComponents(string: "https://openapi.baidu.com/oauth/2.0/token")!
        components.queryItems = [URLQueryItem(name: "grant_type", value: "device_token"),
                                 URLQueryItem(name: "code", value: deviceCode),
                                 URLQueryItem(name: "client_id", value: clientID),
                                 URLQueryItem(name: "client_secret", value: clientSecret)]
        let (data, response) = try await URLSession.shared.data(from: components.url!)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? String,
           error == "authorization_pending" || error == "slow_down" { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TokenError.refreshFailed }
        return try JSONDecoder().decode(Token.self, from: data)
    }

    static func begin115(clientID: String) async throws -> Open115Authorization {
        guard !clientID.isEmpty else { throw TokenError.missingCredentials }
        var random = [UInt8](repeating: 0, count: 48)
        guard random.withUnsafeMutableBytes({ SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) })
                == errSecSuccess else { throw TokenError.refreshFailed }
        let verifier = Data(random).base64EncodedString()
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
        var request = URLRequest(url: URL(string: "https://passportapi.115.com/open/authDeviceCode")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                           URLQueryItem(name: "code_challenge", value: challenge),
                           URLQueryItem(name: "code_challenge_method", value: "sha256")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = json["data"] as? [String: Any],
              let uid = (body["uid"] as? String) ?? (body["uid"] as? NSNumber)?.stringValue,
              let qrCode = body["qrcode"] as? String else { throw TokenError.refreshFailed }
        return Open115Authorization(uid: uid, qrCode: qrCode, verifier: verifier)
    }

    static func exchange115(_ authorization: Open115Authorization) async throws -> Token {
        var request = URLRequest(url: URL(string: "https://passportapi.115.com/open/deviceCodeToToken")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "uid", value: authorization.uid),
                           URLQueryItem(name: "code_verifier", value: authorization.verifier)]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        return try await tokenResponse(request)
    }

    private static func tokenResponse(_ request: URLRequest) async throws -> Token {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw TokenError.refreshFailed }
        let token: Token
        if let direct = try? JSONDecoder().decode(Token.self, from: data) {
            token = direct
        } else {
            struct Envelope: Decodable { let data: Token }
            token = try JSONDecoder().decode(Envelope.self, from: data).data
        }
        guard !token.accessToken.isEmpty, token.expiresIn > 0 else { throw TokenError.refreshFailed }
        return token
    }

    static func beginDropbox(clientID: String) throws -> Authorization {
        guard !clientID.isEmpty else { throw TokenError.missingCredentials }
        var random = [UInt8](repeating: 0, count: 48)
        let status = random.withUnsafeMutableBytes { bytes in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, bytes.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw TokenError.refreshFailed
        }
        let verifier = Data(random).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let digest = SHA256.hash(data: Data(verifier.utf8))
        let challenge = Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        url.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                          URLQueryItem(name: "response_type", value: "code"),
                          URLQueryItem(name: "token_access_type", value: "offline"),
                          URLQueryItem(name: "code_challenge", value: challenge),
                          URLQueryItem(name: "code_challenge_method", value: "S256")]
        guard let finalURL = url.url else { throw TokenError.refreshFailed }
        return Authorization(url: finalURL, verifier: verifier, clientID: clientID)
    }

    static func exchangeDropbox(clientID: String, code: String,
                                verifier: String) async throws -> Token {
        guard !clientID.isEmpty, !code.isEmpty, !verifier.isEmpty else {
            throw TokenError.missingCredentials
        }
        var request = URLRequest(url: URL(string: "https://api.dropboxapi.com/oauth2/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = [URLQueryItem(name: "client_id", value: clientID),
                           URLQueryItem(name: "code", value: code),
                           URLQueryItem(name: "code_verifier", value: verifier),
                           URLQueryItem(name: "grant_type", value: "authorization_code")]
        request.httpBody = Data((form.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 1_000_000 else { throw TokenError.refreshFailed }
        let token = try JSONDecoder().decode(Token.self, from: data)
        guard !token.accessToken.isEmpty, token.refreshToken != nil else {
            throw TokenError.refreshFailed
        }
        return token
    }
}

private enum TokenError: LocalizedError {
    case missingCredentials, refreshFailed
    var errorDescription: String? {
        switch self {
        case .missingCredentials: "请填写云盘应用 ID 和刷新令牌。"
        case .refreshFailed: "云盘授权已过期，请重新连接。"
        }
    }
}
