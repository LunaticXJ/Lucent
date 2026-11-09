import Foundation

struct JellyfinItem: Codable, Sendable {
    struct MediaSource: Codable, Sendable {
        struct Stream: Codable, Sendable {
            let index: Int?
            let type: String?
            let language: String?
            let displayTitle: String?
            let codec: String?
            let codecTag: String?
            let profile: String?
            let videoRangeType: String?
            let width: Int?
            let height: Int?
            let bitRate: Int?
            let channels: Int?
            let sampleRate: Int?
            let channelLayout: String?
            let isDefault: Bool?
            let isExternal: Bool?
            let averageFrameRate: Double?
            let aspectRatio: String?
            let level: Double?
            let pixelFormat: String?
            let colorSpace: String?
            let colorTransfer: String?
            let colorPrimaries: String?
            enum CodingKeys: String, CodingKey {
                case index = "Index", type = "Type", language = "Language", displayTitle = "DisplayTitle"
                case codec = "Codec", codecTag = "CodecTag", profile = "Profile", videoRangeType = "VideoRangeType"
                case width = "Width", height = "Height"
                case bitRate = "BitRate", channels = "Channels", sampleRate = "SampleRate"
                case channelLayout = "ChannelLayout", isDefault = "IsDefault", isExternal = "IsExternal"
                case averageFrameRate = "AverageFrameRate", aspectRatio = "AspectRatio", level = "Level"
                case pixelFormat = "PixelFormat", colorSpace = "ColorSpace"
                case colorTransfer = "ColorTransfer", colorPrimaries = "ColorPrimaries"
            }
        }
        let id: String?
        let name: String?
        var path: String? = nil
        let container: String?
        let bitrate: Int?
        let size: Int64?
        let mediaStreams: [Stream]?
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", container = "Container", bitrate = "Bitrate", size = "Size"
            case mediaStreams = "MediaStreams", path = "Path"
        }
    }
    struct ImageTags: Codable, Sendable {
        let primary: String?
        enum CodingKeys: String, CodingKey { case primary = "Primary" }
    }
    struct Person: Codable, Sendable, Identifiable {
        let id: String?
        let name: String
        let role: String?
        let primaryImageTag: String?
        var stableID: String { id ?? name }
        enum CodingKeys: String, CodingKey {
            case id = "Id", name = "Name", role = "Role", primaryImageTag = "PrimaryImageTag"
        }
    }
    struct UserData: Codable, Sendable {
        let played: Bool?
        let isFavorite: Bool?
        let playbackPositionTicks: Int64?
        let lastPlayedDate: String?
        let unplayedItemCount: Int?
        enum CodingKeys: String, CodingKey {
            case played = "Played"
            case isFavorite = "IsFavorite"
            case playbackPositionTicks = "PlaybackPositionTicks"
            case lastPlayedDate = "LastPlayedDate"
            case unplayedItemCount = "UnplayedItemCount"
        }
    }

    let id: String
    let name: String
    let type: String
    let isFolder: Bool?
    let mediaType: String?
    let seriesName: String?
    let seriesId: String?
    let genres: [String]?
    let people: [Person]?
    let parentIndexNumber: Int?
    let indexNumber: Int?
    let productionYear: Int?
    let premiereDate: String?
    let status: String?
    let endDate: String?
    let communityRating: Double?
    let runTimeTicks: Int64?
    let userData: UserData?
    let overview: String?
    let imageTags: ImageTags?
    let path: String?
    let container: String?
    let mediaSources: [MediaSource]?
    let collectionType: String?
    let criticRating: Double?
    let officialRating: String?
    let providerIds: [String: String]?
    let preferredMetadataLanguage: String?

    init(id: String,
         name: String,
         type: String,
         isFolder: Bool? = nil,
         mediaType: String? = nil,
         seriesName: String? = nil,
         seriesId: String? = nil,
         genres: [String]? = nil,
         people: [Person]? = nil,
         parentIndexNumber: Int? = nil,
         indexNumber: Int? = nil,
         productionYear: Int? = nil,
         premiereDate: String? = nil,
         status: String? = nil,
         endDate: String? = nil,
         communityRating: Double? = nil,
         runTimeTicks: Int64? = nil,
         userData: UserData? = nil,
         overview: String? = nil,
         imageTags: ImageTags? = nil,
         path: String? = nil,
         container: String? = nil,
         mediaSources: [MediaSource]? = nil,
         collectionType: String? = nil,
         criticRating: Double? = nil,
         officialRating: String? = nil,
         providerIds: [String: String]? = nil,
         preferredMetadataLanguage: String? = nil) {
        self.id = id
        self.name = name
        self.type = type
        self.isFolder = isFolder
        self.mediaType = mediaType
        self.seriesName = seriesName
        self.seriesId = seriesId
        self.genres = genres
        self.people = people
        self.parentIndexNumber = parentIndexNumber
        self.indexNumber = indexNumber
        self.productionYear = productionYear
        self.premiereDate = premiereDate
        self.status = status
        self.endDate = endDate
        self.communityRating = communityRating
        self.runTimeTicks = runTimeTicks
        self.userData = userData
        self.overview = overview
        self.imageTags = imageTags
        self.path = path
        self.container = container
        self.mediaSources = mediaSources
        self.collectionType = collectionType
        self.criticRating = criticRating
        self.officialRating = officialRating
        self.providerIds = providerIds
        self.preferredMetadataLanguage = preferredMetadataLanguage
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type"
        case isFolder = "IsFolder", mediaType = "MediaType"
        case seriesName = "SeriesName"
        case seriesId = "SeriesId", genres = "Genres", people = "People"
        case parentIndexNumber = "ParentIndexNumber"
        case indexNumber = "IndexNumber"
        case productionYear = "ProductionYear"
        case premiereDate = "PremiereDate"
        case status = "Status"
        case endDate = "EndDate"
        case communityRating = "CommunityRating"
        case runTimeTicks = "RunTimeTicks"
        case userData = "UserData"
        case overview = "Overview"
        case imageTags = "ImageTags"
        case path = "Path", container = "Container", mediaSources = "MediaSources"
        case collectionType = "CollectionType", criticRating = "CriticRating"
        case officialRating = "OfficialRating"
        case providerIds = "ProviderIds", preferredMetadataLanguage = "PreferredMetadataLanguage"
    }

    var identity: MediaIdentity {
        if type == "Series" {
            return .episode(series: name, season: 1, number: 0, name: nil)
        }
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
    private struct User: Decodable {
        let id: String
        let name: String?
        enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
    }
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

    static func currentUser(baseAddress: String, token: String) async throws -> (id: String, name: String?) {
        let request = try makeRequest(baseAddress: baseAddress, path: "Users/Me", token: token)
        let user = try JSONDecoder().decode(User.self, from: await fetch(request))
        return (user.id, user.name)
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

    static func browsePage(source: JellyfinSource, token: String,
                           start: Int = 0, limit: Int = 60) async throws -> [JellyfinItem] {
        var request = try makeRequest(baseAddress: source.baseAddress, path: "Items", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "UserId", value: source.userID),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "SortBy", value: "DateCreated"),
            URLQueryItem(name: "SortOrder", value: "Descending"),
            URLQueryItem(name: "StartIndex", value: String(start)),
            URLQueryItem(name: "Limit", value: String(limit))
        ]
        request.url = components.url
        return try JSONDecoder().decode(Page.self, from: await fetch(request)).items
    }

    /// Browse an actual folder, season or series without flattening the entire library.
    static func directory(source: JellyfinSource, token: String, parentID: String?,
                          start: Int = 0, limit: Int = 60) async throws -> (items: [JellyfinItem], total: Int) {
        let request = try directoryRequest(source: source, token: token, parentID: parentID, start: start, limit: limit)
        let page = try JSONDecoder().decode(Page.self, from: await fetch(request))
        return (page.items, page.totalRecordCount)
    }
    static func directoryRequest(source: JellyfinSource, token: String, parentID: String?,
                                 start: Int = 0, limit: Int = 60) throws -> URLRequest {
        var request = try makeRequest(baseAddress: source.baseAddress, path: "Items", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            .init(name: "UserId", value: source.userID),
            .init(name: "Recursive", value: parentID == nil ? "true" : "false"),
            .init(name: "StartIndex", value: String(start)), .init(name: "Limit", value: String(limit)),
            .init(name: "SortBy", value: parentID == nil ? "DateCreated" : "SortName"),
            .init(name: "SortOrder", value: parentID == nil ? "Descending" : "Ascending"),
            .init(name: "EnableUserData", value: "true"),
            .init(name: "Fields", value: "Overview,ProductionYear,CommunityRating")
        ]
        if let parentID { components.queryItems?.append(.init(name: "ParentId", value: parentID)) }
        else { components.queryItems?.append(.init(name: "IncludeItemTypes", value: "Movie,Series")) }
        request.url = components.url
        return request
    }

    static func mediaCounts(source: JellyfinSource, token: String) async throws -> (movies: Int, series: Int) {
        func count(_ type: String) async throws -> Int {
            var request = try makeRequest(baseAddress: source.baseAddress, path: "Items", token: token)
            var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "UserId", value: source.userID),
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

    static func search(source: JellyfinSource, token: String, term: String) async throws -> [JellyfinItem] {
        var request = try makeRequest(baseAddress: source.baseAddress, path: "Items", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "UserId", value: source.userID),
            URLQueryItem(name: "SearchTerm", value: term),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series"),
            URLQueryItem(name: "Limit", value: "50"),
            URLQueryItem(name: "Fields", value: "ProductionYear,CommunityRating")
        ]
        request.url = components.url
        return try JSONDecoder().decode(Page.self, from: await fetch(request)).items
            .filter { $0.type == "Movie" || $0.type == "Series" }
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
        request.allowsCellularAccess = NetworkUsagePolicy.allowsSync
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
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
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

extension JellyfinItem.MediaSource {
    var playbackFeatures: PlaybackMediaFeatures {
        let video = mediaStreams?.first { $0.type?.caseInsensitiveCompare("Video") == .orderedSame }
        let audios = mediaStreams?.filter { $0.type?.caseInsensitiveCompare("Audio") == .orderedSame } ?? []
        let audio = audios.first { $0.isDefault == true } ?? audios.first
        let subtitles = mediaStreams?.filter {
            $0.type?.caseInsensitiveCompare("Subtitle") == .orderedSame &&
                ["ass", "ssa"].contains($0.codec?.lowercased() ?? "")
        } ?? []
        var range = video?.videoRangeType
        if let video, DolbyVisionSupport.isDolbyVision(video) {
            range = DolbyVisionSupport.profile(video).map { "Dolby Vision P\($0)" } ?? "Dolby Vision"
        } else if MediaInfoLabels.known(range) == nil {
            range = MediaInfoLabels.dynamicRange(transfer: video?.colorTransfer, matrix: video?.colorSpace)
        }
        let resolution: String?
        if let width = video?.width, let height = video?.height, width > 0, height > 0 {
            resolution = "\(width)×\(height)"
        } else { resolution = nil }
        return PlaybackMediaFeatures(container: container, videoCodec: video?.codec,
                                     videoCodecTag: video?.codecTag, videoProfile: video?.profile,
                                     videoPixelFormat: video?.pixelFormat,
                                     styledSubtitleStreamIndices: subtitles.compactMap(\.index),
                                     defaultStyledSubtitle: subtitles.contains { $0.isDefault == true },
                                     audioCodec: audio?.codec, dynamicRange: range, resolution: resolution)
    }
}

extension JellyfinItem {
    var displayYear: Int? { [productionYear, premiereDate.flatMap { Int($0.prefix(4)) }].compactMap { $0 }.first { $0 > 0 } }
    var displayYearText: String? { CatalogYearLabel.text(start: displayYear, isSeries: type == "Series", status: status, endDate: endDate) }
}
