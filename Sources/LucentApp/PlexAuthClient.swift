import Foundation

struct PlexPIN: Decodable {
    let id: Int
    let code: String
    let authToken: String?
}

enum PlexAuthClient {
    static func createPIN() async throws -> PlexPIN {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("strong=false&X-Plex-Product=Lucent&X-Plex-Client-Identifier=\(clientID)".utf8)
        return try await fetch(request)
    }

    static func waitForToken(pin: PlexPIN) async throws -> String {
        for _ in 0..<90 {
            try Task.checkCancellation()
            var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/pins/\(pin.id)")!)
            request.timeoutInterval = 20
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(clientID, forHTTPHeaderField: "X-Plex-Client-Identifier")
            request.setValue("Lucent", forHTTPHeaderField: "X-Plex-Product")
            let current: PlexPIN = try await fetch(request)
            if let token = current.authToken, !token.isEmpty { return token }
            try await Task.sleep(for: .seconds(2))
        }
        throw PlexAuthError.expired
    }

    private static var clientID: String {
        if let existing = UserDefaults.standard.string(forKey: "lucent.plexClientID") { return existing }
        let value = UUID().uuidString
        UserDefaults.standard.set(value, forKey: "lucent.plexClientID")
        return value
    }

    private static func fetch(_ request: URLRequest) async throws -> PlexPIN {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw PlexAuthError.requestFailed }
        return try JSONDecoder().decode(PlexPIN.self, from: data)
    }
}

private enum PlexAuthError: LocalizedError {
    case requestFailed, expired
    var errorDescription: String? {
        switch self {
        case .requestFailed: "Plex 授权请求失败。"
        case .expired: "Plex 授权码已过期，请重新获取。"
        }
    }
}
