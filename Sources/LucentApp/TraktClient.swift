import Foundation

enum TraktClient {
    struct DeviceCode: Decodable, Sendable {
        let deviceCode: String
        let userCode: String
        let verificationURL: URL
        let expiresIn: Int
        let interval: Int

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code"
            case verificationURL = "verification_url", expiresIn = "expires_in", interval
        }
    }

    struct Watched: Hashable, Codable, Sendable {
        let tmdbID: Int
        let season: Int?
        let episode: Int?
    }

    struct Progress: Sendable {
        let item: Watched
        let percentage: Double
    }

    struct Rated: Sendable {
        let item: Watched
        let rating: Int
    }

    private struct Token: Decodable {
        let accessToken: String
        let refreshToken: String
        let expiresIn: Int
        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in"
        }
    }

    private struct IDs: Decodable { let tmdb: Int? }
    private struct Title: Decodable { let ids: IDs }
    private struct Episode: Decodable { let season: Int; let number: Int }
    private struct WatchedMovie: Decodable { let movie: Title }
    private struct WatchedShow: Decodable {
        struct Season: Decodable { let number: Int; let episodes: [Episode] }
        let show: Title
        let seasons: [Season]
    }
    private struct Playback: Decodable {
        let progress: Double
        let movie: Title?
        let show: Title?
        let episode: Episode?
    }
    private struct RatedMovie: Decodable { let rating: Int; let movie: Title }
    private struct RatedEpisode: Decodable {
        let rating: Int
        let show: Title
        let episode: Episode
    }

    static func beginDeviceAuthorization(clientID: String) async throws -> DeviceCode {
        let data = try await call("/oauth/device/code", clientID: clientID,
                                  body: ["client_id": clientID])
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    static func completeDeviceAuthorization(code: DeviceCode, clientID: String,
                                            clientSecret: String) async throws {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        var interval = max(5, code.interval)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .seconds(interval))
            let (data, status) = try await rawCall("/oauth/device/token", clientID: clientID,
                body: ["code": code.deviceCode, "client_id": clientID, "client_secret": clientSecret],
                accessToken: nil)
            switch status {
            case 200:
                try store(try JSONDecoder().decode(Token.self, from: data))
                return
            case 400: continue
            case 429: interval += 5
            case 404, 409, 410, 418: throw TraktError.authorizationFailed(status)
            default: throw TraktError.http(status)
            }
        }
        throw TraktError.expired
    }

    static func disconnect() throws {
        try KeychainPasswordStore.setTraktSecret("", account: "access")
        try KeychainPasswordStore.setTraktSecret("", account: "refresh")
        UserDefaults.standard.removeObject(forKey: "lucent.trakt.expiration")
    }

    static var connected: Bool {
        guard let token = try? KeychainPasswordStore.traktSecret("refresh") else { return false }
        return !token.isEmpty
    }

    static func watched(clientID: String, clientSecret: String) async throws -> Set<Watched> {
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        let movieData = try await call("/sync/watched/movies", clientID: clientID, accessToken: access)
        let showData = try await call("/sync/watched/shows", clientID: clientID, accessToken: access)
        let movies = try JSONDecoder().decode([WatchedMovie].self, from: movieData)
        let shows = try JSONDecoder().decode([WatchedShow].self, from: showData)
        var result = Set(movies.compactMap { $0.movie.ids.tmdb.map { Watched(tmdbID: $0, season: nil, episode: nil) } })
        for show in shows {
            guard let id = show.show.ids.tmdb else { continue }
            for season in show.seasons {
                for episode in season.episodes {
                    result.insert(Watched(tmdbID: id, season: season.number, episode: episode.number))
                }
            }
        }
        return result
    }

    static func playback(clientID: String, clientSecret: String) async throws -> [Progress] {
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        let data = try await call("/sync/playback", clientID: clientID, accessToken: access)
        let entries = try JSONDecoder().decode([Playback].self, from: data)
        return entries.compactMap { entry in
            if let id = entry.movie?.ids.tmdb {
                return Progress(item: Watched(tmdbID: id, season: nil, episode: nil), percentage: entry.progress)
            }
            if let id = entry.show?.ids.tmdb, let episode = entry.episode {
                return Progress(item: Watched(tmdbID: id, season: episode.season, episode: episode.number),
                                percentage: entry.progress)
            }
            return nil
        }
    }

    static func ratings(clientID: String, clientSecret: String) async throws -> [Rated] {
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        var result: [Rated] = []
        for page in 1...100 {
            let data = try await call("/sync/ratings/movies?limit=100&page=\(page)",
                                      clientID: clientID, accessToken: access)
            let entries = try JSONDecoder().decode([RatedMovie].self, from: data)
            result += entries.compactMap { entry in
                guard let id = entry.movie.ids.tmdb, (1...10).contains(entry.rating) else { return nil }
                return Rated(item: Watched(tmdbID: id, season: nil, episode: nil), rating: entry.rating)
            }
            if entries.count < 100 { break }
        }
        for page in 1...100 {
            let data = try await call("/sync/ratings/episodes?limit=100&page=\(page)",
                                      clientID: clientID, accessToken: access)
            let entries = try JSONDecoder().decode([RatedEpisode].self, from: data)
            result += entries.compactMap { entry in
                guard let id = entry.show.ids.tmdb, (1...10).contains(entry.rating) else { return nil }
                return Rated(item: Watched(tmdbID: id, season: entry.episode.season,
                                           episode: entry.episode.number), rating: entry.rating)
            }
            if entries.count < 100 { break }
        }
        return result
    }

    static func addRatings(_ ratings: [Rated], clientID: String,
                           clientSecret: String) async throws {
        guard !ratings.isEmpty else { return }
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        for batch in stride(from: 0, to: ratings.count, by: 50) {
            let slice = ratings[batch..<min(batch + 50, ratings.count)]
            let movies: [[String: Any]] = slice.filter { $0.item.season == nil }.map {
                ["ids": ["tmdb": $0.item.tmdbID], "rating": $0.rating]
            }
            let shows: [[String: Any]] = Dictionary(grouping: slice.filter { $0.item.season != nil },
                                                     by: { $0.item.tmdbID }).map { pair in
                let (id, episodes) = pair
                let seasons: [[String: Any]] = Dictionary(grouping: episodes,
                                                           by: { $0.item.season ?? 0 }).map { seasonPair in
                    let (number, entries) = seasonPair
                    return ["number": number,
                            "episodes": entries.map { ["number": $0.item.episode ?? 0,
                                                        "rating": $0.rating] }]
                }
                return ["ids": ["tmdb": id], "seasons": seasons]
            }
            _ = try await call("/sync/ratings", clientID: clientID,
                               body: ["movies": movies, "shows": shows], accessToken: access)
        }
    }

    static func removeRatings(_ items: [Watched], clientID: String,
                              clientSecret: String) async throws {
        guard !items.isEmpty else { return }
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        for batch in stride(from: 0, to: items.count, by: 50) {
            let slice = Array(items[batch..<min(batch + 50, items.count)])
            _ = try await call("/sync/ratings/remove", clientID: clientID,
                               body: historyBody(slice), accessToken: access)
        }
    }

    static func addWatched(_ items: [Watched], clientID: String, clientSecret: String) async throws {
        guard !items.isEmpty else { return }
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        for batch in stride(from: 0, to: items.count, by: 50) {
            let slice = Array(items[batch..<min(batch + 50, items.count)])
            _ = try await call("/sync/history", clientID: clientID,
                               body: historyBody(slice), accessToken: access)
        }
    }

    static func removeWatched(_ items: [Watched], clientID: String, clientSecret: String) async throws {
        guard !items.isEmpty else { return }
        let access = try await validAccessToken(clientID: clientID, clientSecret: clientSecret)
        for batch in stride(from: 0, to: items.count, by: 50) {
            let slice = Array(items[batch..<min(batch + 50, items.count)])
            _ = try await call("/sync/history/remove", clientID: clientID,
                               body: historyBody(slice), accessToken: access)
        }
    }

    private static func historyBody(_ items: [Watched]) -> [String: Any] {
        let movies: [[String: Any]] = items.filter { $0.season == nil }.map {
            ["ids": ["tmdb": $0.tmdbID]]
        }
        let shows: [[String: Any]] = Dictionary(grouping: items.filter { $0.season != nil }, by: \.tmdbID)
            .map { pair in
                let (id, episodes) = pair
                let seasons: [[String: Any]] = Dictionary(grouping: episodes, by: { $0.season ?? 0 })
                    .map { seasonPair in
                        let (number, entries) = seasonPair
                        return ["number": number, "episodes": entries.map { ["number": $0.episode ?? 0] }]
                    }
                return ["ids": ["tmdb": id], "seasons": seasons]
            }
        return ["movies": movies, "shows": shows]
    }

    private static func validAccessToken(clientID: String, clientSecret: String) async throws -> String {
        if let access = try KeychainPasswordStore.traktSecret("access"),
           UserDefaults.standard.double(forKey: "lucent.trakt.expiration") > Date().timeIntervalSince1970 + 60 {
            return access
        }
        guard let refresh = try KeychainPasswordStore.traktSecret("refresh") else {
            throw TraktError.notConnected
        }
        let data = try await call("/oauth/token", clientID: clientID,
            body: ["refresh_token": refresh, "client_id": clientID,
                   "client_secret": clientSecret, "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
                   "grant_type": "refresh_token"])
        let token = try JSONDecoder().decode(Token.self, from: data)
        try store(token)
        return token.accessToken
    }

    private static func store(_ token: Token) throws {
        try KeychainPasswordStore.setTraktSecret(token.accessToken, account: "access")
        try KeychainPasswordStore.setTraktSecret(token.refreshToken, account: "refresh")
        UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(token.expiresIn)).timeIntervalSince1970,
                                  forKey: "lucent.trakt.expiration")
    }

    private static func call(_ path: String, clientID: String, body: [String: Any]? = nil,
                             accessToken: String? = nil) async throws -> Data {
        let (data, status) = try await rawCall(path, clientID: clientID, body: body, accessToken: accessToken)
        guard (200..<300).contains(status) else { throw TraktError.http(status) }
        return data
    }

    private static func rawCall(_ path: String, clientID: String, body: [String: Any]?,
                                accessToken: String?) async throws -> (Data, Int) {
        var request = URLRequest(url: URL(string: "https://api.trakt.tv\(path)")!)
        request.timeoutInterval = 30
        request.setValue("2", forHTTPHeaderField: "trakt-api-version")
        request.setValue(clientID, forHTTPHeaderField: "trakt-api-key")
        request.setValue("Lucent/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let accessToken { request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw TraktError.invalidResponse }
        return (data, response.statusCode)
    }
}

private enum TraktError: LocalizedError {
    case notConnected, invalidResponse, expired, authorizationFailed(Int), http(Int)
    var errorDescription: String? {
        switch self {
        case .notConnected: "Trakt 尚未连接。"
        case .invalidResponse: "Trakt 返回了无效响应。"
        case .expired: "Trakt 授权码已过期。"
        case .authorizationFailed(let code): "Trakt 授权失败（\(code)）。"
        case .http(let code): "Trakt 请求失败（HTTP \(code)）。"
        }
    }
}
