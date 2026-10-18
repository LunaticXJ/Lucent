import Foundation

enum EmbyClient {
    struct BrowsePage: Sendable {
        let items: [JellyfinItem]
        let totalCount: Int
    }
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

    static func browse(source: EmbySource, token: String, parentID: String?,
                       startIndex: Int = 0, limit: Int = 100) async throws -> BrowsePage {
        let path = parentID == nil ? "Users/\(source.userID)/Views" : "Users/\(source.userID)/Items"
        var request = try makeRequest(baseAddress: source.baseAddress, path: path, token: token)
        if let parentID {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "Recursive", value: "false"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: "SortName"),
                URLQueryItem(name: "SortOrder", value: "Ascending")
            ]
            request.url = components.url
        }
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return BrowsePage(items: page.items, totalCount: page.totalRecordCount)
    }

    static func latest(source: EmbySource, token: String, limit: Int = 12) async throws -> [JellyfinItem] {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items/Latest", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "Fields", value: "Overview")
        ]
        request.url = components.url
        return try JSONDecoder().decode([JellyfinItem].self, from: await fetch(request))
    }

    static func resume(source: EmbySource, token: String, limit: Int = 12) async throws -> BrowsePage {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "Filters", value: "IsResumable"),
            URLQueryItem(name: "SortBy", value: "DatePlayed"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video"),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
        request.url = components.url
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return BrowsePage(items: page.items, totalCount: page.totalRecordCount)
    }

    static func featured(source: EmbySource, token: String, parentID: String,
                         itemTypes: String, limit: Int = 12) async throws -> BrowsePage {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: itemTypes),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
        request.url = components.url
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return BrowsePage(items: page.items, totalCount: page.totalRecordCount)
    }

    static func search(source: EmbySource, token: String, term: String,
                       limit: Int = 50) async throws -> BrowsePage {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Series,Video"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
        request.url = components.url
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return BrowsePage(items: page.items, totalCount: page.totalRecordCount)
    }

    static func artwork(source: EmbySource, token: String, itemID: String,
                        backdrop: Bool, maxWidth: Int) async throws -> Data {
        let path = "Items/\(itemID)/Images/" + (backdrop ? "Backdrop/0" : "Primary")
        var request = try makeRequest(baseAddress: source.baseAddress, path: path, token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "maxWidth", value: String(maxWidth))]
        request.url = components.url
        return try await fetch(request)
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

enum ServerEpisodeClient {
    private struct Page: Decodable {
        let items: [JellyfinItem]
        let totalRecordCount: Int
        enum CodingKeys: String, CodingKey {
            case items = "Items", totalRecordCount = "TotalRecordCount"
        }
    }

    static func episodes(baseAddress: String, userID: String, itemID: String,
                         token: String) async throws -> [JellyfinItem] {
        guard let base = URL(string: baseAddress) else { throw EmbyError.invalidResponse }
        var detail = URLRequest(url: base.appendingPathComponent("Users")
            .appendingPathComponent(userID).appendingPathComponent("Items")
            .appendingPathComponent(itemID))
        detail.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        detail.timeoutInterval = 20
        let (detailData, detailResponse) = try await URLSession.shared.data(for: detail)
        guard (detailResponse as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: detailData) as? [String: Any],
              let seriesID = json["SeriesId"] as? String, !seriesID.isEmpty else { return [] }

        var episodes: [JellyfinItem] = []
        repeat {
            var components = URLComponents(url: base.appendingPathComponent("Shows")
                .appendingPathComponent(seriesID).appendingPathComponent("Episodes"),
                resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "UserId", value: userID),
                URLQueryItem(name: "StartIndex", value: String(episodes.count)),
                URLQueryItem(name: "Limit", value: "200"),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources"),
                URLQueryItem(name: "EnableUserData", value: "true")
            ]
            var request = URLRequest(url: components.url!)
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EmbyError.requestFailed }
            let page = try JSONDecoder().decode(Page.self, from: data)
            guard !page.items.isEmpty || episodes.count >= page.totalRecordCount else {
                throw EmbyError.invalidResponse
            }
            episodes.append(contentsOf: page.items)
            if episodes.count >= page.totalRecordCount || episodes.count >= 10_000 { break }
        } while true
        return episodes.sorted {
            let lhs = ($0.parentIndexNumber ?? 0, $0.indexNumber ?? 0, $0.name)
            let rhs = ($1.parentIndexNumber ?? 0, $1.indexNumber ?? 0, $1.name)
            return lhs < rhs
        }
    }
}

private enum EmbyError: LocalizedError {
    case requestFailed, invalidResponse
    var errorDescription: String? {
        switch self {
        case .requestFailed: "Emby 请求失败，请检查地址和访问令牌。"
        case .invalidResponse: "Emby 返回了无法识别的数据。"
        }
    }
}
