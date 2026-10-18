import Foundation

struct JellyfinItem: Decodable, Sendable {
    struct MediaSource: Decodable, Sendable {
        struct Stream: Decodable, Sendable {
            let index: Int?
            let type: String?
            let language: String?
            let displayTitle: String?
            let codec: String?
            let profile: String?
            let videoRangeType: String?
            let width: Int?
            let height: Int?
            enum CodingKeys: String, CodingKey {
                case index = "Index", type = "Type", language = "Language", displayTitle = "DisplayTitle"
                case codec = "Codec", profile = "Profile", videoRangeType = "VideoRangeType"
                case width = "Width", height = "Height"
            }
        }
        let id: String?
        let name: String?
        let container: String?
        let bitrate: Int?
        let mediaStreams: [Stream]?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", container = "Container", bitrate = "Bitrate"
            case mediaStreams = "MediaStreams"
        }
    }
    struct ImageTags: Decodable, Sendable {
        let primary: String?
        enum CodingKeys: String, CodingKey { case primary = "Primary" }
    }
    struct UserData: Decodable, Sendable {
        let played: Bool?
        let isFavorite: Bool?
        let playbackPositionTicks: Int64?
        let lastPlayedDate: String?
        enum CodingKeys: String, CodingKey {
            case played = "Played"
            case isFavorite = "IsFavorite"
            case playbackPositionTicks = "PlaybackPositionTicks"
            case lastPlayedDate = "LastPlayedDate"
        }
    }

    let id: String
    let name: String
    let type: String
    let isFolder: Bool?
    let mediaType: String?
    let seriesName: String?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let productionYear: Int?
    let communityRating: Double?
    let runTimeTicks: Int64?
    let userData: UserData?
    let overview: String?
    let imageTags: ImageTags?
    let path: String?
    let container: String?
    let mediaSources: [MediaSource]?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type"
        case isFolder = "IsFolder", mediaType = "MediaType"
        case seriesName = "SeriesName"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case productionYear = "ProductionYear"
        case communityRating = "CommunityRating"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case overview = "Overview"
        case imageTags = "ImageTags"
        case path = "Path", container = "Container", mediaSources = "MediaSources"
    }

    var identity: MediaIdentity {
        if type == "Episode", let seriesName {
            return .episode(series: seriesName, season: parentIndexNumber ?? 0,
                            number: indexNumber ?? 0, name: name)
        }
        return .movie(year: productionYear)
    }

    var fileExtension: String {
        let raw = mediaSources?.first?.container ?? container ?? (path as NSString?)?.pathExtension ?? ""
        let value = raw.lowercased()
        return value.range(of: "^[a-z0-9]{1,8}$", options: .regularExpression) == nil ? "mp4" : value
    }

    var remoteStateDate: Date? {
        guard let value = userData?.lastPlayedDate else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

enum JellyfinClient {
    private struct User: Decodable { let id: String; enum CodingKeys: String, CodingKey { case id = "Id" } }
    private struct Authentication: Decodable {
        let accessToken: String
        enum CodingKeys: String, CodingKey { case accessToken = "AccessToken" }
    }
    private struct Page: Decodable {
        let items: [JellyfinItem]
        let totalRecordCount: Int
        enum CodingKeys: String, CodingKey {
            case items = "Items"
            case totalRecordCount = "TotalRecordCount"
        }
    }

    static func currentUserID(baseAddress: String, token: String) async throws -> String {
        let request = try makeRequest(baseAddress: baseAddress, path: "Users/Me", token: token)
        return try JSONDecoder().decode(User.self, from: await fetch(request)).id
    }

    static func authenticate(baseAddress: String, username: String, password: String) async throws -> String {
        guard let base = URL(string: baseAddress), !username.isEmpty else { throw JellyfinError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deviceID = UserDefaults.standard.string(forKey: "lucent.jellyfinDeviceID") ?? UUID().uuidString
        UserDefaults.standard.set(deviceID, forKey: "lucent.jellyfinDeviceID")
        request.setValue("MediaBrowser Client=\"Lucent\", Device=\"Apple\", DeviceId=\"\(deviceID)\", Version=\"0.1.0\"",
                         forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        return try JSONDecoder().decode(Authentication.self, from: await fetch(request)).accessToken
    }

    static func scan(source: JellyfinSource, token: String) async throws -> [JellyfinItem] {
        var all: [JellyfinItem] = []
        repeat {
            var request = try makeRequest(baseAddress: source.baseAddress, path: "Items", token: token)
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "UserId", value: source.userID),
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: "Movie,Episode,Video"),
                URLQueryItem(name: "Fields", value: "Path,MediaSources"),
                URLQueryItem(name: "StartIndex", value: String(all.count)),
                URLQueryItem(name: "Limit", value: "200")
            ]
            request.url = components.url
            let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
            guard !page.items.isEmpty || all.count >= page.totalRecordCount else { throw JellyfinError.invalidResponse }
            all.append(contentsOf: page.items)
            if all.count > 50_000 { throw JellyfinError.tooManyItems }
            if all.count >= page.totalRecordCount { break }
        } while true
        return all
    }

    static func streamURL(source: JellyfinSource, itemID: String, mediaSourceID: String? = nil) -> URL? {
        guard let base = URL(string: source.baseAddress) else { return nil }
        let url = base.appendingPathComponent("Videos").appendingPathComponent(itemID).appendingPathComponent("stream")
        var components = URLComponents(url: url,
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "static", value: "true")]
        if let mediaSourceID {
            components?.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID))
        }
        return components?.url
    }

    static func versions(source: JellyfinSource, token: String, itemID: String) async throws -> [JellyfinItem.MediaSource] {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items/\(itemID)", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "Fields", value: "MediaSources")]
        request.url = components.url
        return try JSONDecoder().decode(JellyfinItem.self, from: await fetch(request)).mediaSources ?? []
    }

    static func readRange(source: JellyfinSource, token: String, itemID: String,
                          offset: UInt64, length: Int,
                          mediaSourceID: String? = nil) throws -> SMBScanner.RangeResult {
        guard let url = streamURL(source: source, itemID: itemID,
                                  mediaSourceID: mediaSourceID) else { throw JellyfinError.invalidResponse }
        return try HTTPRangeReader.read(url: url, headers: ["X-Emby-Token": token],
                                        offset: offset, length: length)
    }

    static func downloadRequest(source: JellyfinSource, token: String, itemID: String) -> URLRequest? {
        guard let url = streamURL(source: source, itemID: itemID) else { return nil }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        return request
    }

    static func posterRequest(source: JellyfinSource, token: String, itemID: String) -> URLRequest? {
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

    static func updateUserData(source: JellyfinSource, token: String, itemID: String,
                               position: Double? = nil, played: Bool? = nil,
                               favorite: Bool? = nil) async throws {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "UserItems/\(itemID)/UserData", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "userId", value: source.userID)]
        request.url = components.url
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

    private static func makeRequest(baseAddress: String, path: String, token: String) throws -> URLRequest {
        guard let base = URL(string: baseAddress) else { throw JellyfinError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 20
        return request
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw JellyfinError.requestFailed }
        return data
    }
}

private enum JellyfinError: LocalizedError {
    case requestFailed, invalidResponse, tooManyItems
    var errorDescription: String? {
        switch self {
        case .requestFailed: "Jellyfin 请求失败，请检查地址和访问令牌。"
        case .invalidResponse: "Jellyfin 返回了无法识别的数据。"
        case .tooManyItems: "媒体库超过 50,000 项，请缩小扫描范围。"
        }
    }
}
