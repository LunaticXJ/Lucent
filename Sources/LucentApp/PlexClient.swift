import Foundation

struct PlexItem: Decodable, Sendable {
    struct MediaEntry: Decodable, Sendable {
        struct Part: Decodable, Sendable {
            struct Stream: Decodable, Sendable {
                let id: Int?
                let streamType: Int?
                let displayTitle: String?
                let language: String?
                let codec: String?
                let videoProfile: String?
                private enum CodingKeys: String, CodingKey {
                    case id, streamType, displayTitle, language, codec, videoProfile
                }
                init(from decoder: Decoder) throws {
                    let values = try decoder.container(keyedBy: CodingKeys.self)
                    id = (try? values.decode(Int.self, forKey: .id))
                        ?? (try? values.decode(String.self, forKey: .id)).flatMap(Int.init)
                    streamType = (try? values.decode(Int.self, forKey: .streamType))
                        ?? (try? values.decode(String.self, forKey: .streamType)).flatMap(Int.init)
                    displayTitle = try values.decodeIfPresent(String.self, forKey: .displayTitle)
                    language = try values.decodeIfPresent(String.self, forKey: .language)
                    codec = try values.decodeIfPresent(String.self, forKey: .codec)
                    videoProfile = try values.decodeIfPresent(String.self, forKey: .videoProfile)
                }
            }
            let id: Int?
            let key: String
            let streams: [Stream]?
            private enum CodingKeys: String, CodingKey {
                case id, key
                case streams = "Stream"
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = (try? values.decode(Int.self, forKey: .id))
                    ?? (try? values.decode(String.self, forKey: .id)).flatMap(Int.init)
                key = try values.decode(String.self, forKey: .key)
                streams = try values.decodeIfPresent([Stream].self, forKey: .streams)
            }
        }
        let videoResolution: String?
        let videoCodec: String?
        let audioCodec: String?
        let bitrate: Int?
        let Part: [Part]?
    }

    let ratingKey: String
    let title: String
    let type: String
    let grandparentTitle: String?
    let parentIndex: Int?
    let index: Int?
    let year: Int?
    let duration: Double?
    let viewOffset: Double?
    let viewCount: Int?
    let lastViewedAt: TimeInterval?
    let Media: [MediaEntry]?
    let summary: String?
    let thumb: String?

    var partKey: String? { Media?.first?.Part?.first?.key }
    var identity: MediaIdentity {
        if type == "episode" {
            return .episode(series: grandparentTitle ?? "剧集", season: parentIndex ?? 0,
                            number: index ?? 0, name: title)
        }
        return .movie(year: year)
    }
}

enum PlexClient {
    private struct Account: Decodable { let username: String? }
    private struct Section: Decodable { let key: String; let type: String }
    private struct SectionContainer: Decodable { let Directory: [Section]? }
    private struct SectionResponse: Decodable { let MediaContainer: SectionContainer }
    private struct ItemContainer: Decodable {
        let Metadata: [PlexItem]?
        let totalSize: Int?
    }
    private struct ItemResponse: Decodable { let MediaContainer: ItemContainer }

    static func validate(baseAddress: String, token: String) async throws {
        _ = try await sections(baseAddress: baseAddress, token: token)
    }

    static func accountName(token: String) async throws -> String? {
        var request = URLRequest(url: URL(string: "https://plex.tv/api/v2/user")!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers(token: token) { request.setValue(value, forHTTPHeaderField: name) }
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw PlexError.invalidResponse
        }
        return try JSONDecoder().decode(Account.self, from: data).username
    }

    static func mediaCounts(source: PlexSource, token: String) async throws -> (movies: Int, series: Int) {
        let libraries = try await sections(baseAddress: source.baseAddress, token: token)
        var movies = 0
        var series = 0
        for library in libraries where library.type == "movie" || library.type == "show" {
            var request = try makeRequest(baseAddress: source.baseAddress,
                                          path: "library/sections/\(library.key)/all", token: token)
            request.setValue("0", forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue("1", forHTTPHeaderField: "X-Plex-Container-Size")
            let count = try JSONDecoder().decode(ItemResponse.self, from: await fetch(request))
                .MediaContainer.totalSize ?? 0
            if library.type == "movie" { movies += count }
            else { series += count }
        }
        return (movies, series)
    }

    static func versions(source: PlexSource, token: String,
                         ratingKey: String) async throws -> [PlexItem.MediaEntry] {
        let request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "library/metadata/\(ratingKey)", token: token)
        return try JSONDecoder().decode(ItemResponse.self, from: await fetch(request))
            .MediaContainer.Metadata?.first?.Media ?? []
    }

    static func cachedItem(source: PlexSource, token: String, ratingKey: String) async throws -> PlexItem? {
        var request = try makeRequest(baseAddress: source.baseAddress, path: "library/metadata/\(ratingKey)", token: token)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw PlexError.requestFailed }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200 else { throw PlexError.requestFailed }
        let values = try JSONDecoder().decode(ItemResponse.self, from: data).MediaContainer.Metadata ?? []
        guard values.count <= 1, values.allSatisfy({ $0.ratingKey == ratingKey }) else { throw PlexError.invalidResponse }
        return values.first
    }

    static func item(source: PlexSource, token: String, ratingKey: String) async throws -> PlexItem? {
        let request = try makeRequest(baseAddress: source.baseAddress,
                                      path: "library/metadata/\(ratingKey)", token: token)
        return try JSONDecoder().decode(ItemResponse.self, from: await fetch(request))
            .MediaContainer.Metadata?.first
    }

    static func selectStreams(source: PlexSource, token: String, partID: Int,
                              audioID: Int?, subtitleID: Int?) async throws {
        guard let base = URL(string: source.baseAddress) else { throw PlexError.invalidResponse }
        let endpoint = base.appendingPathComponent("library/parts/\(partID)")
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var query: [URLQueryItem] = [URLQueryItem(name: "X-Plex-Token", value: token),
                                     URLQueryItem(name: "allParts", value: "1")]
        if let audioID { query.append(URLQueryItem(name: "audioStreamID", value: String(audioID))) }
        if let subtitleID { query.append(URLQueryItem(name: "subtitleStreamID", value: String(subtitleID))) }
        components.queryItems = query
        guard let url = components.url else { throw PlexError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw PlexError.invalidResponse }
    }

    static func scan(source: PlexSource, token: String) async throws -> [PlexItem] {
        let libraries = try await sections(baseAddress: source.baseAddress, token: token)
        var all: [PlexItem] = []
        for library in libraries where library.type == "movie" || library.type == "show" {
            var start = 0
            let endpoint = "library/sections/\(library.key)/\(library.type == "show" ? "allLeaves" : "all")"
            while true {
                var request = try makeRequest(baseAddress: source.baseAddress, path: endpoint, token: token)
                request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start")
                request.setValue("200", forHTTPHeaderField: "X-Plex-Container-Size")
                let page = try JSONDecoder().decode(ItemResponse.self, from: await fetch(request)).MediaContainer
                let items = page.Metadata ?? []
                all.append(contentsOf: items.filter { $0.partKey != nil })
                start += items.count
                if all.count > 50_000 { throw PlexError.tooManyItems }
                if items.isEmpty || start >= (page.totalSize ?? start) { break }
            }
        }
        return all
    }

    static func browsePage(source: PlexSource, token: String,
                           start: Int = 0, limit: Int = 40) async throws -> [PlexItem] {
        let libraries = try await sections(baseAddress: source.baseAddress, token: token)
        var result: [PlexItem] = []
        for library in libraries where library.type == "movie" || library.type == "show" {
            let endpoint = "library/sections/\(library.key)/\(library.type == "show" ? "allLeaves" : "all")"
            var request = try makeRequest(baseAddress: source.baseAddress, path: endpoint, token: token)
            request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(limit), forHTTPHeaderField: "X-Plex-Container-Size")
            let page = try JSONDecoder().decode(ItemResponse.self, from: await fetch(request)).MediaContainer
            result.append(contentsOf: (page.Metadata ?? []).filter { $0.partKey != nil })
        }
        return result
    }

    /// Catalog browsing keeps shows as shows; allLeaves is only for file-level scans.
    static func catalogPage(source: PlexSource, token: String, parentKey: String? = nil,
                            start: Int = 0, limit: Int = 60) async throws -> [PlexItem] {
        let endpoints: [String]
        if let parentKey { endpoints = ["library/metadata/\(parentKey)/children"] }
        else {
            endpoints = try await sections(baseAddress: source.baseAddress, token: token)
                .filter { $0.type == "movie" || $0.type == "show" }
                .map { "library/sections/\($0.key)/all" }
        }
        var result: [PlexItem] = []
        for endpoint in endpoints {
            try Task.checkCancellation()
            var request = try makeRequest(baseAddress: source.baseAddress, path: endpoint, token: token)
            request.setValue(String(start), forHTTPHeaderField: "X-Plex-Container-Start")
            request.setValue(String(limit), forHTTPHeaderField: "X-Plex-Container-Size")
            let page = try JSONDecoder().decode(ItemResponse.self, from: await fetch(request)).MediaContainer
            result += page.Metadata ?? []
        }
        return result
    }

    static func search(source: PlexSource, token: String, term: String) async throws -> [PlexItem] {
        var request = try makeRequest(baseAddress: source.baseAddress, path: "hubs/search", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "query", value: term),
                                 URLQueryItem(name: "limit", value: "30")]
        request.url = components.url
        struct SearchHub: Decodable { let Metadata: [PlexItem]? }
        struct SearchContainer: Decodable { let Hub: [SearchHub]? }
        struct SearchResponse: Decodable { let MediaContainer: SearchContainer }
        let hubs = try JSONDecoder().decode(SearchResponse.self, from: await fetch(request)).MediaContainer.Hub ?? []
        var seen = Set<String>()
        return hubs.flatMap { $0.Metadata ?? [] }.filter { item in
            (item.type == "movie" || item.type == "show") &&
            seen.insert(item.ratingKey).inserted
        }
    }

    static func readRange(source: PlexSource, token: String, partKey: String,
                          offset: UInt64, length: Int) throws -> SMBScanner.RangeResult {
        guard let url = partURL(source: source, partKey: partKey) else { throw PlexError.invalidResponse }
        return try HTTPRangeReader.read(url: url, headers: headers(token: token),
                                        offset: offset, length: length)
    }

    static func downloadRequest(source: PlexSource, token: String, partKey: String) -> URLRequest? {
        guard let url = partURL(source: source, partKey: partKey) else { return nil }
        var request = URLRequest(url: url)
        for (name, value) in headers(token: token) { request.setValue(value, forHTTPHeaderField: name) }
        return request
    }

    static func posterRequest(source: PlexSource, token: String, thumb: String) -> URLRequest? {
        guard let base = URL(string: source.baseAddress),
              let url = URL(string: thumb, relativeTo: base)?.absoluteURL,
              url.scheme == "https" || (url.scheme == base.scheme && url.host == base.host) else { return nil }
        var request = URLRequest(url: url)
        if url.host == base.host {
            for (name, value) in headers(token: token) { request.setValue(value, forHTTPHeaderField: name) }
        }
        return request
    }

    static func markPlayed(source: PlexSource, token: String, ratingKey: String, played: Bool) async throws {
        let path = played ? ":/scrobble" : ":/unscrobble"
        var request = try makeRequest(baseAddress: source.baseAddress, path: path, token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                                 URLQueryItem(name: "key", value: ratingKey)]
        request.allowsCellularAccess = NetworkUsagePolicy.allowsSync
        request.url = components.url
        request.httpMethod = "PUT"
        _ = try await fetch(request)
    }

    static func reportProgress(source: PlexSource, token: String, ratingKey: String,
                               position: Double, duration: Double?, stopped: Bool) async throws {
        var request = try makeRequest(baseAddress: source.baseAddress, path: ":/timeline", token: token)
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "ratingKey", value: ratingKey),
            URLQueryItem(name: "state", value: stopped ? "stopped" : "playing"),
            URLQueryItem(name: "time", value: String(Int(max(0, position) * 1000))),
            URLQueryItem(name: "duration", value: String(Int(max(0, duration ?? 0) * 1000)))
        ]
        request.allowsCellularAccess = NetworkUsagePolicy.allowsSync
        request.url = components.url
        request.httpMethod = "POST"
        _ = try await fetch(request)
    }

    private static func sections(baseAddress: String, token: String) async throws -> [Section] {
        let request = try makeRequest(baseAddress: baseAddress, path: "library/sections", token: token)
        let response = try JSONDecoder().decode(SectionResponse.self, from: await fetch(request))
        return response.MediaContainer.Directory ?? []
    }

    private static func partURL(source: PlexSource, partKey: String) -> URL? {
        guard let base = URL(string: source.baseAddress),
              let url = URL(string: partKey, relativeTo: base)?.absoluteURL,
              url.scheme == base.scheme, url.host == base.host else { return nil }
        return url
    }

    private static func makeRequest(baseAddress: String, path: String, token: String) throws -> URLRequest {
        guard let base = URL(string: baseAddress) else { throw PlexError.invalidResponse }
        var request = URLRequest(url: base.appendingPathComponent(path))
        for (name, value) in headers(token: token) { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        return request
    }

    private static func headers(token: String) -> [String: String] {
        let key = "lucent.plex.clientIdentifier"
        let identifier: String
        if let saved = UserDefaults.standard.string(forKey: key) { identifier = saved }
        else {
            identifier = UUID().uuidString
            UserDefaults.standard.set(identifier, forKey: key)
        }
        return ["X-Plex-Token": token,
                "X-Plex-Client-Identifier": identifier,
                "X-Plex-Product": "Lucent",
                "X-Plex-Version": "0.1"]
    }

    private static func fetch(_ request: URLRequest) async throws -> Data {
        var request = request
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw PlexError.requestFailed }
        return data
    }
}

private enum PlexError: LocalizedError {
    case requestFailed, invalidResponse, tooManyItems
    var errorDescription: String? {
        switch self {
        case .requestFailed: "Plex 请求失败，请检查服务器和访问令牌。"
        case .invalidResponse: "Plex 返回了无法识别的数据。"
        case .tooManyItems: "媒体库超过 50,000 项，请缩小扫描范围。"
        }
    }
}
