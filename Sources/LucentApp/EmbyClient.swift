import Foundation

enum EmbyClient {
    private struct User: Decodable {
        let id: String
        enum CodingKeys: String, CodingKey { case id = "Id" }
    }
    private struct Authentication: Decodable {
        let accessToken: String
        let user: User
        enum CodingKeys: String, CodingKey { case accessToken = "AccessToken", user = "User" }
    }
    private struct Page: Decodable {
        let items: [JellyfinItem]
        let totalRecordCount: Int
        enum CodingKeys: String, CodingKey {
            case items = "Items", totalRecordCount = "TotalRecordCount"
        }
    }

    static func validateUser(baseAddress: String, token: String, userID: String) async throws {
        let user = try JSONDecoder().decode(User.self, from: await fetch(makeRequest(baseAddress: baseAddress,
                                                                                      path: "Users/\(userID)", token: token)))
        guard user.id.caseInsensitiveCompare(userID) == .orderedSame else { throw EmbyError.invalidResponse }
    }

    static func authenticate(baseAddress: String, username: String, password: String) async throws -> (token: String, userID: String) {
        guard !username.isEmpty else { throw EmbyError.invalidResponse }
        var request = try makeRequest(baseAddress: baseAddress, path: "Users/AuthenticateByName", token: "")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let result = try JSONDecoder().decode(Authentication.self, from: await fetch(request))
        return (result.accessToken, result.user.id)
    }

    static func scan(source: EmbySource, token: String) async throws -> [JellyfinItem] {
        var all: [JellyfinItem] = []
        repeat {
            var request = try makeRequest(baseAddress: source.baseAddress,
                                          path: "Users/\(source.userID)/Items", token: token)
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video"),
                URLQueryItem(name: "Fields", value: "Path,MediaSources,Overview"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "StartIndex", value: String(all.count)),
                URLQueryItem(name: "Limit", value: "200")
            ]
            request.url = components.url
            let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
            guard !page.items.isEmpty || all.count >= page.totalRecordCount else { throw EmbyError.invalidResponse }
            all.append(contentsOf: page.items)
            if all.count > 50_000 { throw EmbyError.tooManyItems }
            if all.count >= page.totalRecordCount { break }
        } while true
        return all
    }

    static func readRange(source: EmbySource, token: String, itemID: String,
                          offset: UInt64, length: Int,
                          mediaSourceID: String? = nil) throws -> SMBScanner.RangeResult {
        guard let url = streamURL(source: source, itemID: itemID,
                                  mediaSourceID: mediaSourceID) else { throw EmbyError.invalidResponse }
        return try HTTPRangeReader.read(url: url, headers: ["X-Emby-Token": token],
                                        offset: offset, length: length)
    }

    static func downloadRequest(source: EmbySource, token: String, itemID: String) -> URLRequest? {
        guard let url = streamURL(source: source, itemID: itemID) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    static func posterRequest(source: EmbySource, token: String, itemID: String) -> URLRequest? {
        guard let base = URL(string: source.baseAddress) else { return nil }
        let url = base.appendingPathComponent("Items").appendingPathComponent(itemID)
            .appendingPathComponent("Images").appendingPathComponent("Primary")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "500")]
        guard let finalURL = components?.url else { return nil }
        var request = URLRequest(url: finalURL)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    static func updateUserData(source: EmbySource, token: String, itemID: String,
                               position: Double? = nil, played: Bool? = nil,
                               favorite: Bool? = nil) async throws {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items/\(itemID)/UserData", token: token)
        let current = try await fetch(request)
        var fields = (try JSONSerialization.jsonObject(with: current)) as? [String: Any] ?? [:]
        if let position { fields["PlaybackPositionTicks"] = Int64(max(0, position) * 10_000_000) }
        if let played { fields["Played"] = played }
        if let favorite { fields["IsFavorite"] = favorite }
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: fields)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        _ = try await fetch(request)
    }

    static func versions(source: EmbySource, token: String, itemID: String) async throws -> [JellyfinItem.MediaSource] {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items/\(itemID)", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "Fields", value: "MediaSources")]
        request.url = components.url
        return try JSONDecoder().decode(JellyfinItem.self, from: await fetch(request)).mediaSources ?? []
    }

    private static func streamURL(source: EmbySource, itemID: String,
                                  mediaSourceID: String? = nil) -> URL? {
        guard let base = URL(string: source.baseAddress) else { return nil }
        let url = base.appendingPathComponent("Videos").appendingPathComponent(itemID)
            .appendingPathComponent("stream")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "static", value: "true")]
        if let mediaSourceID {
            components?.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID))
        }
        return components?.url
    }

    private static func makeRequest(baseAddress: String, path: String, token: String) throws -> URLRequest {
        guard let base = URL(string: baseAddress) else { throw EmbyError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.timeoutInterval = 20
        if !token.isEmpty { request.setValue(token, forHTTPHeaderField: "X-Emby-Token") }
        let deviceID = UserDefaults.standard.string(forKey: "lucent.embyDeviceID") ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: "lucent.embyDeviceID")
        request.setValue("Emby Client=\"Lucent\", Device=\"Apple\", DeviceId=\"\(deviceID)\", Version=\"0.1.0\"",
                         forHTTPHeaderField: "X-Emby-Authorization")
        return request
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw EmbyError.requestFailed }
        return data
    }
}

private enum EmbyError: LocalizedError {
    case requestFailed, invalidResponse, tooManyItems
    var errorDescription: String? {
        switch self {
        case .requestFailed: "Emby 请求失败，请检查地址和访问令牌。"
        case .invalidResponse: "Emby 返回了无法识别的数据。"
        case .tooManyItems: "媒体库超过 50,000 项，请缩小扫描范围。"
        }
    }
}
