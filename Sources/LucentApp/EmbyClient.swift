import Foundation

enum EmbyClient {
    static func featuredItemTypes(for view: JellyfinItem) -> String {
        switch view.collectionType?.lowercased() {
        case "movies": "Movie"
        case "tvshows": "Series"
        default: "Movie,Series,Video"
        }
    }
    enum BrowseSort: String, CaseIterable, Identifiable {
        case name = "SortName", added = "DateCreated", release = "PremiereDate"
        case year = "ProductionYear", imdb = "CommunityRating", critics = "CriticRating"
        case played = "DatePlayed", latestEpisodeAdded = "DateLastMediaAdded"
        case latestEpisodeReleased = "DateLastMediaPublished", playCount = "PlayCount"
        case random = "Random", rating = "OfficialRating"
        case boxOffice = "Revenue", resolution = "Resolution"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .name: "名称"
            case .added: "添加日期"
            case .release: "发行日期"
            case .year: "年份"
            case .imdb: "IMDb评分"
            case .critics: "影评人评分"
            case .played: "播放日期"
            case .latestEpisodeAdded: "最后一集添加日期"
            case .latestEpisodeReleased: "最后一集发行日期"
            case .playCount: "播放次数"
            case .random: "随机"
            case .rating: "分级"
            case .boxOffice: "票房"
            case .resolution: "分辨率"
            }
        }
        static var seriesOptions: [Self] {
            [.name, .added, .release, .year, .imdb, .critics, .played,
             .latestEpisodeAdded, .latestEpisodeReleased, .playCount, .random, .rating]
        }
        static var movieOptions: [Self] {
            [.name, .added, .release, .played, .year, .imdb, .critics,
             .playCount, .boxOffice, .random, .rating, .resolution]
        }
        static var mixedOptions: [Self] {
            [.name, .added, .release, .imdb, .critics, .playCount, .random]
        }
    }
    enum BrowseFacet { case genre(String), studio(String) }
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
    private struct PlaybackInfo: Decodable {
        struct Source: Decodable {
            let id: String?
            let transcodingURL: String?
            let supportsTranscoding: Bool?
            enum CodingKeys: String, CodingKey {
                case id = "Id", transcodingURL = "TranscodingUrl"
                case supportsTranscoding = "SupportsTranscoding"
            }
        }
        let mediaSources: [Source]?
        let playSessionID: String?
        enum CodingKeys: String, CodingKey {
            case mediaSources = "MediaSources", playSessionID = "PlaySessionId"
        }
    }

    static func validateUser(baseAddress: String, token: String, userID: String) async throws {
        let user = try JSONDecoder().decode(User.self, from: await fetch(makeRequest(baseAddress: baseAddress,
                                                                                      path: "Users/\(userID)", token: token)))
        guard user.id.caseInsensitiveCompare(userID) == .orderedSame else { throw EmbyError.invalidResponse }
    }

    static func browse(source: EmbySource, token: String, parentID: String?,
                       startIndex: Int = 0, limit: Int = 100,
                       itemType: String? = nil, sort: BrowseSort = .name,
                       ascending: Bool = true, facet: BrowseFacet? = nil) async throws -> BrowsePage {
        let path = parentID == nil ? "Users/\(source.userID)/Views" : "Users/\(source.userID)/Items"
        var request = try makeRequest(baseAddress: source.baseAddress, path: path, token: token)
        if let parentID {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "ParentId", value: parentID),
                URLQueryItem(name: "Recursive", value: "false"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: "Overview,MediaSources,MediaStreams,DateCreated,Genres,Studios"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: sort.rawValue),
                URLQueryItem(name: "SortOrder", value: ascending ? "Ascending" : "Descending")
            ]
            if let itemType {
                components.queryItems?.removeAll { $0.name == "Recursive" }
                components.queryItems?.append(URLQueryItem(name: "Recursive", value: "true"))
                components.queryItems?.append(URLQueryItem(name: "IncludeItemTypes", value: itemType))
            }
            switch facet {
            case .genre(let id): components.queryItems?.append(URLQueryItem(name: "GenreIds", value: id))
            case .studio(let id): components.queryItems?.append(URLQueryItem(name: "StudioIds", value: id))
            case nil: break
            }
            request.url = components.url
        }
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return BrowsePage(items: page.items, totalCount: page.totalRecordCount)
    }

    static func categories(source: EmbySource, token: String, parentID: String,
                           kind: String, itemType: String = "Series",
                           startIndex: Int = 0, limit: Int = 100) async throws -> BrowsePage {
        var request = try makeRequest(baseAddress: source.baseAddress, path: kind, token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "UserId", value: source.userID),
            URLQueryItem(name: "ParentId", value: parentID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: itemType),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "StartIndex", value: String(startIndex)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        request.url = components.url
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

    static func transcodingURL(source: EmbySource, token: String, itemID: String,
                               mediaSourceID: String?, bitrate: Int) async throws -> URL {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Items/\(itemID)/PlaybackInfo", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "UserId": source.userID,
            "EnableDirectPlay": false,
            "EnableDirectStream": false,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": false,
            "AllowAudioStreamCopy": false,
            "MaxStreamingBitrate": bitrate
        ]
        if let mediaSourceID { body["MediaSourceId"] = mediaSourceID }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: await fetch(request))
        guard let selected = info.mediaSources?.first(where: { $0.id == mediaSourceID })
            ?? info.mediaSources?.first else { throw EmbyError.invalidResponse }
        guard selected.supportsTranscoding != false else {
            throw EmbyError.invalidTranscode("服务器未开放该媒体的转码权限")
        }
        if let value = selected.transcodingURL, !value.isEmpty,
           let url = playbackURL(value, baseAddress: source.baseAddress, token: token) {
            try await verifyHLSPlaylist(at: url)
            return url
        }
        guard selected.supportsTranscoding == true else {
            throw EmbyError.invalidTranscode("服务器未提供转码地址")
        }
        guard let base = URL(string: source.baseAddress) else { throw EmbyError.invalidResponse }
        var components = URLComponents(url: base.appendingPathComponent("Videos")
            .appendingPathComponent(itemID).appendingPathComponent("master.m3u8"),
            resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "Static", value: "false"),
            URLQueryItem(name: "MaxStreamingBitrate", value: String(bitrate)),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "AllowVideoStreamCopy", value: "false"),
            URLQueryItem(name: "AllowAudioStreamCopy", value: "false")
        ]
        if let id = selected.id ?? mediaSourceID {
            components?.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: id))
        }
        if let id = info.playSessionID {
            components?.queryItems?.append(URLQueryItem(name: "PlaySessionId", value: id))
        }
        guard let url = components?.url else { throw EmbyError.invalidResponse }
        try await verifyHLSPlaylist(at: url)
        return url
    }

    private static func verifyHLSPlaylist(at url: URL) async throws {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw EmbyError.invalidResponse }
        guard (200..<300).contains(response.statusCode) else {
            let redirected = response.url?.host != url.host ? "（已跳转至外部存储）" : ""
            throw EmbyError.invalidTranscode("HTTP \(response.statusCode)\(redirected)")
        }
        var prefix: [UInt8] = []
        for try await byte in bytes {
            prefix.append(byte)
            if prefix.count == 64 { break }
        }
        let marker = String(decoding: prefix, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard marker.hasPrefix("#EXTM3U") else {
            let type = response.value(forHTTPHeaderField: "Content-Type")?.components(separatedBy: ";").first ?? "未知格式"
            throw EmbyError.invalidTranscode("服务器返回了 \(type)，不是 HLS 清单")
        }
    }

    private static func playbackURL(_ value: String, baseAddress: String, token: String) -> URL? {
        guard let base = URL(string: baseAddress) else { return nil }
        let url: URL?
        if let absolute = URL(string: value), absolute.scheme != nil {
            url = absolute
        } else {
            let path = value.hasPrefix("/") ? String(value.dropFirst()) : value
            let prefix = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            url = URL(string: prefix + "/" + path)
        }
        guard let url, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }
        if components.queryItems?.contains(where: { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }) != true {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api_key", value: token)]
        }
        return components.url
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

enum ServerDetailClient {
    static func item(baseAddress: String, userID: String, itemID: String,
                     token: String) async throws -> JellyfinItem {
        guard let base = URL(string: baseAddress) else { throw EmbyError.invalidResponse }
        var components = URLComponents(url: base.appendingPathComponent("Users")
            .appendingPathComponent(userID).appendingPathComponent("Items")
            .appendingPathComponent(itemID), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "Fields", value: "People,Genres,Overview,MediaSources"),
                                 URLQueryItem(name: "EnableUserData", value: "true")]
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EmbyError.requestFailed }
        return try JSONDecoder().decode(JellyfinItem.self, from: data)
    }
}

enum ServerEpisodeClient {
    struct SeriesPage: Sendable {
        let series: JellyfinItem
        let episodes: [JellyfinItem]
    }
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
              let seriesID = (json["SeriesId"] as? String) ??
                ((json["Type"] as? String) == "Series" ? itemID : nil), !seriesID.isEmpty else { return [] }

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

    static func seriesPage(baseAddress: String, userID: String, itemID: String,
                           token: String) async throws -> SeriesPage? {
        guard let base = URL(string: baseAddress) else { throw EmbyError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent("Users")
            .appendingPathComponent(userID).appendingPathComponent("Items")
            .appendingPathComponent(itemID))
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EmbyError.requestFailed }
        let selected = try JSONDecoder().decode(JellyfinItem.self, from: data)
        guard let seriesID = selected.seriesId ?? (selected.type == "Series" ? selected.id : nil) else { return nil }
        var seriesURL = URLComponents(url: base.appendingPathComponent("Users").appendingPathComponent(userID)
            .appendingPathComponent("Items").appendingPathComponent(seriesID),
            resolvingAgainstBaseURL: false)!
        seriesURL.queryItems = [URLQueryItem(name: "Fields", value: "People,Genres,Overview"),
                                URLQueryItem(name: "EnableUserData", value: "true")]
        request.url = seriesURL.url
        let (seriesData, seriesResponse) = try await URLSession.shared.data(for: request)
        guard (seriesResponse as? HTTPURLResponse)?.statusCode == 200 else { throw EmbyError.requestFailed }
        let series = try JSONDecoder().decode(JellyfinItem.self, from: seriesData)
        let episodes = try await episodes(baseAddress: baseAddress, userID: userID,
                                          itemID: itemID, token: token)
        return SeriesPage(series: series, episodes: episodes)
    }
}

private enum EmbyError: LocalizedError {
    case requestFailed, invalidResponse, invalidTranscode(String)
    var errorDescription: String? {
        switch self {
        case .requestFailed: "Emby 请求失败，请检查地址和访问令牌。"
        case .invalidResponse: "Emby 返回了无法识别的数据。"
        case .invalidTranscode(let detail): "Emby 转码流不可用：\(detail)。"
        }
    }
}
