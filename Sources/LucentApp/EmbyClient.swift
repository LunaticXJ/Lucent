import Foundation
import OSLog

enum SubtitleDeliveryError: LocalizedError {
    case invalidAddress, unsupportedFormat, http(Int), tooLarge, empty, parse, network(Int)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "字幕地址无效"
        case .unsupportedFormat: "字幕格式不支持"
        case .http(let code): "字幕服务器返回 HTTP \(code)"
        case .tooLarge: "字幕文件超过 8 MB 上限"
        case .empty: "字幕服务器返回空文件"
        case .parse: "响应内容无法解析为字幕"
        case .network(let code): "字幕网络请求失败（\(code)）"
        }
    }
}

enum EmbyClient {
    private static let subtitleLog = Logger(subsystem: "com.lucent.app", category: "SubtitleDelivery")

    static func logSubtitleFailure(_ error: Error, stage: String) {
        // Only fixed stage names and numeric error codes; never URL, token or body.
        if let error = error as? SubtitleDeliveryError {
            subtitleLog.error("\(stage, privacy: .public): \(error.localizedDescription, privacy: .public)")
        } else {
            subtitleLog.error("\(stage, privacy: .public): error code \((error as NSError).code, privacy: .public)")
        }
    }
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
        case played = "DatePlayed", latestEpisodeAdded = "DateLastContentAdded"
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
    enum BrowseFacet: Hashable, Sendable { case genre(String), studio(String) }
    struct BrowsePage: Sendable {
        let items: [JellyfinItem]
        let totalCount: Int
    }
    private struct User: Decodable {
        let id: String
        let name: String?
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
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
            let mediaStreams: [SubtitleDelivery]?
            enum CodingKeys: String, CodingKey {
                case id = "Id", transcodingURL = "TranscodingUrl"
                case supportsTranscoding = "SupportsTranscoding"
                case mediaStreams = "MediaStreams"
            }
        }
        let mediaSources: [Source]?
        let playSessionID: String?
        enum CodingKeys: String, CodingKey {
            case mediaSources = "MediaSources", playSessionID = "PlaySessionId"
        }
    }

    struct SubtitleDelivery: Decodable, Sendable {
        let index: Int?
        let type: String?
        let displayTitle: String?
        let language: String?
        let deliveryMethod: String?
        let deliveryURL: String?
        let isExternal: Bool?
        enum CodingKeys: String, CodingKey {
            case index = "Index", type = "Type", displayTitle = "DisplayTitle"
            case language = "Language", deliveryMethod = "DeliveryMethod"
            case deliveryURL = "DeliveryUrl", isExternal = "IsExternal"
        }
    }

    /// Ask for subtitle delivery only; this never starts a transcode or replaces video.
    static func subtitleDeliveries(source: EmbySource, token: String, itemID: String,
                                   mediaSourceID: String) async throws -> [SubtitleDelivery] {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                     path: "Items/\(itemID)/PlaybackInfo", token: token)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "UserId": source.userID, "MediaSourceId": mediaSourceID,
            "IsPlayback": false, "EnableDirectPlay": true,
            "EnableDirectStream": true, "EnableTranscoding": false,
            "DeviceProfile": [
                "DirectPlayProfiles": [["Type": "Video"]],
                "SubtitleProfiles": ["srt", "vtt", "ass", "ssa"].map {
                    ["Format": $0, "Method": "External"]
                }
            ]
        ])
        let info = try JSONDecoder().decode(PlaybackInfo.self, from: await fetch(request))
        // Never use a different version's stream indices.
        return info.mediaSources?.first(where: { $0.id == mediaSourceID })?.mediaStreams?.filter {
            let ext = URL(string: $0.deliveryURL ?? "")?.pathExtension.lowercased() ?? ""
            return $0.type == "Subtitle" && $0.deliveryMethod == "External"
                && $0.index != nil && ["srt", "vtt", "ass", "ssa"].contains(ext)
        } ?? []
    }

    static func subtitleCues(delivery: SubtitleDelivery, baseAddress: String,
                             token: String) async throws -> [SubtitleCue] {
        guard let base = URL(string: baseAddress.hasSuffix("/") ? baseAddress : baseAddress + "/"),
              let value = delivery.deliveryURL,
              let url = URL(string: value, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw SubtitleDeliveryError.invalidAddress
        }
        let ext = url.pathExtension.lowercased()
        guard ["srt", "vtt", "ass", "ssa"].contains(ext) else { throw SubtitleDeliveryError.unsupportedFormat }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        // Server credentials belong only to the server, not third-party delivery URLs.
        if url.host == base.host && url.scheme == base.scheme && url.port == base.port {
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        }
        let session = URLSession(configuration: .ephemeral,
                                 delegate: SubtitleRedirectPolicy(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        subtitleLog.notice("Download started; stream=\(delivery.index ?? -1, privacy: .public)")
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw SubtitleDeliveryError.network((error as NSError).code)
        }
        guard let http = response as? HTTPURLResponse else { throw SubtitleDeliveryError.invalidAddress }
        subtitleLog.notice("Response HTTP=\(http.statusCode, privacy: .public); length=\(response.expectedContentLength, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else { throw SubtitleDeliveryError.http(http.statusCode) }
        guard response.expectedContentLength <= 8_000_000 else { throw SubtitleDeliveryError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 8_000_000 else { throw SubtitleDeliveryError.tooLarge }
            data.append(byte)
        }
        guard !data.isEmpty else { throw SubtitleDeliveryError.empty }
        let cues = SubtitleParser.parse(data, fileExtension: ext)
        subtitleLog.notice("Parsed bytes=\(data.count, privacy: .public); cues=\(cues.count, privacy: .public)")
        guard !cues.isEmpty else { throw SubtitleDeliveryError.parse }
        return cues
    }

    static func validateUser(baseAddress: String, token: String, userID: String) async throws -> String? {
        let user = try JSONDecoder().decode(User.self, from: await fetch(makeRequest(baseAddress: baseAddress,
                                                                                      path: "Users/\(userID)", token: token)))
        guard user.id.caseInsensitiveCompare(userID) == .orderedSame else { throw EmbyError.invalidResponse }
        return user.name
    }

    static func browse(source: EmbySource, token: String, parentID: String?,
                       startIndex: Int = 0, limit: Int = 100,
                       itemType: String? = nil, sort: BrowseSort = .name,
                       ascending: Bool = true, facet: BrowseFacet? = nil,
                       includeMediaDetails: Bool = true, foldersOnly: Bool = false) async throws -> BrowsePage {
        let request = try browseRequest(source: source, token: token, parentID: parentID,
            startIndex: startIndex, limit: limit, itemType: itemType, sort: sort,
            ascending: ascending, facet: facet, includeMediaDetails: includeMediaDetails, foldersOnly: foldersOnly)
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return BrowsePage(items: page.items, totalCount: page.totalRecordCount)
    }

    static func browseRequest(source: EmbySource, token: String, parentID: String?,
                       startIndex: Int = 0, limit: Int = 100,
                       itemType: String? = nil, sort: BrowseSort = .name,
                       ascending: Bool = true, facet: BrowseFacet? = nil,
                       includeMediaDetails: Bool = true, foldersOnly: Bool = false) throws -> URLRequest {
        let path = parentID == nil && itemType == nil ? "Users/\(source.userID)/Views" : "Users/\(source.userID)/Items"
        var request = try makeRequest(baseAddress: source.baseAddress, path: path, token: token)
        if parentID != nil || itemType != nil {
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "Recursive", value: "false"),
                URLQueryItem(name: "StartIndex", value: String(startIndex)),
                URLQueryItem(name: "Limit", value: String(limit)),
                URLQueryItem(name: "Fields", value: includeMediaDetails ? "Overview,MediaSources,MediaStreams,DateCreated,Genres,Studios,ProductionYear" : "DateCreated,ProductionYear"),
                URLQueryItem(name: "EnableUserData", value: "true"),
                URLQueryItem(name: "SortBy", value: sort.rawValue),
                URLQueryItem(name: "SortOrder", value: ascending ? "Ascending" : "Descending")
            ]
            if let parentID { components.queryItems?.append(.init(name: "ParentId", value: parentID)) }
            if let itemType {
                components.queryItems?.removeAll { $0.name == "Recursive" }
                components.queryItems?.append(URLQueryItem(name: "Recursive", value: "true"))
                components.queryItems?.append(URLQueryItem(name: "IncludeItemTypes", value: itemType))
            }
            if foldersOnly {
                components.queryItems?.append(URLQueryItem(name: "IsFolder", value: "true"))
                components.queryItems?.append(URLQueryItem(name: "ExcludeItemTypes", value: "Series"))
            }
            switch facet {
            case .genre(let id): components.queryItems?.append(URLQueryItem(name: "GenreIds", value: id))
            case .studio(let id): components.queryItems?.append(URLQueryItem(name: "StudioIds", value: id))
            case nil: break
            }
            request.url = components.url
        }
        return request
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

    static func latest(source: EmbySource, token: String, limit: Int = 40) async throws -> [JellyfinItem] {
        var request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "Users/\(source.userID)/Items/Latest", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "Fields", value: "Overview,ProviderIds,PreferredMetadataLanguage,Genres,CommunityRating,ProductionYear")
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

    static func mediaCounts(source: EmbySource, token: String) async throws -> (movies: Int, series: Int) {
        func count(_ type: String) async throws -> Int {
            var request = try makeRequest(baseAddress: source.baseAddress,
                                          path: "Users/\(source.userID)/Items", token: token)
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "Recursive", value: "true"),
                URLQueryItem(name: "IncludeItemTypes", value: type),
                URLQueryItem(name: "Limit", value: "1")
            ]
            request.url = components.url
            return try JSONDecoder().decode(Page.self, from: await fetch(request)).totalRecordCount
        }
        async let movies = count("Movie")
        async let series = count("Series")
        return try await (movies, series)
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
            URLQueryItem(name: "SortBy", value: itemTypes == "Series" ? "DateLastContentAdded,DateCreated" : "DateCreated"),
            URLQueryItem(name: "SortOrder", value: itemTypes == "Series" ? "Descending,Descending" : "Descending"),
            URLQueryItem(name: "EnableUserData", value: "true"),
            URLQueryItem(name: "Fields", value: "CommunityRating,ProductionYear")
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
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Limit", value: String(limit)),
            URLQueryItem(name: "EnableUserData", value: "true")
        ]
        request.url = components.url
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        let titles = page.items.filter { $0.type == "Movie" || $0.type == "Series" }
        return BrowsePage(items: titles, totalCount: titles.count)
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

    static func authenticate(baseAddress: String, username: String, password: String) async throws -> (token: String, userID: String, username: String) {
        guard !username.isEmpty else { throw EmbyError.invalidResponse }
        var request = try makeRequest(baseAddress: baseAddress, path: "Users/AuthenticateByName", token: "")
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])
        let result = try JSONDecoder().decode(Authentication.self, from: await fetch(request))
        return (result.accessToken, result.user.id, result.user.name ?? username)
    }

    static func readRange(source: EmbySource, token: String, itemID: String,
                          offset: UInt64, length: Int,
                          mediaSourceID: String? = nil) throws -> SMBScanner.RangeResult {
        guard let url = streamURL(source: source, itemID: itemID,
                                  mediaSourceID: mediaSourceID) else { throw EmbyError.invalidResponse }
        return try HTTPRangeReader.read(url: url, headers: ["X-Emby-Token": token],
                                        offset: offset, length: length)
    }

    /// Give AetherEngine the same authenticated direct-file URL shape used by
    /// Sodalite. Its demuxer then owns the source connection and redirects.
    static func directPlaybackURL(source: EmbySource, token: String, itemID: String,
                                  mediaSourceID: String?, container: String) -> URL? {
        guard let base = URL(string: source.baseAddress) else { return nil }
        let ext = container.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !ext.isEmpty, ext.allSatisfy({ $0.isASCII && $0.isLetter || $0.isNumber }) else { return nil }
        let url = base.appendingPathComponent("Videos").appendingPathComponent(itemID)
            .appendingPathComponent("stream.\(ext)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "api_key", value: token),
                                  URLQueryItem(name: "Static", value: "true")]
        if let mediaSourceID {
            components?.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID))
        }
        return components?.url
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
        request.allowsCellularAccess = NetworkUsagePolicy.allowsSync
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
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw EmbyError.requestFailed }
        return data
    }
}

enum ServerDetailClient {
    static func logoRequest(baseAddress: String, token: String, itemID: String) -> URLRequest? {
        guard let base = URL(string: baseAddress) else { return nil }
        var components = URLComponents(url: base.appendingPathComponent("Items")
            .appendingPathComponent(itemID).appendingPathComponent("Images/Logo"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "maxWidth", value: "780")]
        guard let url = components?.url else { return nil }
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 10
        return request
    }

    static func item(baseAddress: String, userID: String, itemID: String,
                     token: String, fields: String = "People,Genres,Overview,MediaSources,ProviderIds") async throws -> JellyfinItem {
        guard let base = URL(string: baseAddress) else { throw EmbyError.invalidResponse }
        var components = URLComponents(url: base.appendingPathComponent("Users")
            .appendingPathComponent(userID).appendingPathComponent("Items")
            .appendingPathComponent(itemID), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "Fields", value: fields),
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

        return try await episodesForSeries(base: base, userID: userID, seriesID: seriesID, token: token)
    }

    private static func episodesForSeries(base: URL, userID: String, seriesID: String,
                                          token: String) async throws -> [JellyfinItem] {
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
        var selectedURL = URLComponents(url: base.appendingPathComponent("Users")
            .appendingPathComponent(userID).appendingPathComponent("Items")
            .appendingPathComponent(itemID), resolvingAgainstBaseURL: false)!
        selectedURL.queryItems = [URLQueryItem(name: "Fields", value: "People,Genres,Overview,ProviderIds"),
                                  URLQueryItem(name: "EnableUserData", value: "true")]
        var request = URLRequest(url: selectedURL.url!)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw EmbyError.requestFailed }
        let selected = try JSONDecoder().decode(JellyfinItem.self, from: data)
        guard let seriesID = selected.seriesId ?? (selected.type == "Series" ? selected.id : nil) else { return nil }
        async let episodeResult = episodesForSeries(base: base, userID: userID,
                                                    seriesID: seriesID, token: token)
        let series: JellyfinItem
        if selected.type == "Series" {
            series = selected
        } else {
            var seriesURL = URLComponents(url: base.appendingPathComponent("Users").appendingPathComponent(userID)
                .appendingPathComponent("Items").appendingPathComponent(seriesID),
                resolvingAgainstBaseURL: false)!
            seriesURL.queryItems = [URLQueryItem(name: "Fields", value: "People,Genres,Overview,ProviderIds"),
                                    URLQueryItem(name: "EnableUserData", value: "true")]
            request.url = seriesURL.url
            let (seriesData, seriesResponse) = try await URLSession.shared.data(for: request)
            guard (seriesResponse as? HTTPURLResponse)?.statusCode == 200 else { throw EmbyError.requestFailed }
            series = try JSONDecoder().decode(JellyfinItem.self, from: seriesData)
        }
        let episodes = try await episodeResult
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

/// Subtitle delivery may redirect to storage. Never forward server authentication
/// across origins, including through a later redirect back to the original host.
private final class SubtitleRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url,
              ["http", "https"].contains(to.scheme?.lowercased() ?? "") else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if from.host != to.host || from.scheme != to.scheme || from.port != to.port {
            for header in ["X-Emby-Token", "X-Emby-Authorization", "Authorization", "Cookie"] {
                redirected.setValue(nil, forHTTPHeaderField: header)
            }
        }
        completionHandler(redirected)
    }
}
