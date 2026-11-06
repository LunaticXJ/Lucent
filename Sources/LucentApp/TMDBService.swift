import Foundation

struct TMDBSearchResult: Decodable, Identifiable, Sendable {
    let id: Int
    let mediaType: String?
    let title: String?
    let originalTitle: String?
    let originalName: String?
    let name: String?
    let overview: String?
    let posterPath: String?
    let voteAverage: Double?
    let releaseDate: String?
    let firstAirDate: String?

    enum CodingKeys: String, CodingKey {
        case id, title, name, overview
        case mediaType = "media_type"
        case originalTitle = "original_title", originalName = "original_name"
        case posterPath = "poster_path"
        case voteAverage = "vote_average"
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
    }

    var displayTitle: String { title ?? name ?? "未知标题" }
    var year: String? { (releaseDate ?? firstAirDate)?.prefix(4).description }
    var metadata: MediaMetadata {
        MediaMetadata(providerID: id, summary: overview, posterPath: posterPath, rating: voteAverage, catalogKind: recognitionKind)
    }
}

enum TMDBService {
    static var deviceLanguage: String { LocalizationPreferences.current.contentLanguage }
    private static func authorize(_ components: inout URLComponents, credential: String) -> String? {
        var credential = credential.trimmingCharacters(in: .whitespacesAndNewlines)
        if credential.lowercased().hasPrefix("bearer ") { credential = String(credential.dropFirst(7)).trimmingCharacters(in: .whitespacesAndNewlines) }
        if credential.count == 32 && credential.allSatisfy({ $0.isHexDigit }) {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api_key", value: credential)]
            return nil
        }
        if credential.hasPrefix("api_key:") {
            components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "api_key", value: String(credential.dropFirst(8)).trimmingCharacters(in: .whitespacesAndNewlines))]
            return nil
        }
        return "Bearer \(credential)"
    }
    struct DetailArtwork: Codable, Sendable {
        var posterURL: URL?
        var logoURL: URL?
        var localizedTitle: String? = nil
    }
    private struct ArtworkImage: Decodable {
        let file_path: String
        let iso_639_1: String?
        let iso_3166_1: String?
        let width: Int
        let height: Int
        let vote_average: Double?
    }
    private struct Images: Decodable {
        let posters: [ArtworkImage]
        let logos: [ArtworkImage]
    }
    private struct ArtworkResponse: Decodable {
        let title: String?
        let name: String?
        let images: Images
    }

    static func artworkID(remote: JellyfinItem?, metadata: MediaMetadata?) -> Int? {
        if let value = remote?.providerIds?.first(where: { $0.key.lowercased() == "tmdb" })?.value,
           let id = Int(value) { return id }
        return metadata?.providerID
    }

    static func detailArtwork(remote: JellyfinItem?, metadata: MediaMetadata?,
                              title: String, television: Bool, language: String,
                              token: String, displayWidthPixels: Int) async throws -> DetailArtwork {
        let id: Int
        if let matched = artworkID(remote: remote, metadata: metadata) {
            id = matched
        } else {
            let results = try await search(title: title, television: television, token: token)
            let year = remote?.productionYear
            guard let match = results.first(where: { candidate in
                candidate.displayTitle.localizedCaseInsensitiveCompare(title) == .orderedSame &&
                (year.map { candidate.year == String($0) } ?? true)
            }) ?? results.first else {
                return DetailArtwork(posterURL: nil, logoURL: nil)
            }
            id = match.id
        }
        return try await detailArtwork(id: id, television: television,
            language: language, token: token, displayWidthPixels: displayWidthPixels)
    }

    static func detailArtwork(id: Int, television: Bool, language: String, token: String,
                              displayWidthPixels: Int = 1200) async throws -> DetailArtwork {
        let locale = language.replacingOccurrences(of: "_", with: "-")
        let lang = locale.split(separator: "-").first.map(String.init) ?? "zh"
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(television ? "tv" : "movie")/\(id)")!
        components.queryItems = [
            URLQueryItem(name: "append_to_response", value: "images"),
            URLQueryItem(name: "language", value: locale),
            URLQueryItem(name: "region", value: LocalizationPreferences.current.regionCode),
            URLQueryItem(name: "include_image_language", value: "\(locale),\(lang),en,null")
        ]
        let authorization = authorize(&components, credential: token)
        var request = URLRequest(url: components.url!)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw TMDBError.requestFailed }
        let details = try JSONDecoder().decode(ArtworkResponse.self, from: data)
        let images = details.images
        func best(_ candidates: [ArtworkImage]) -> ArtworkImage? {
            candidates.sorted {
                if ($0.iso_639_1 == lang) != ($1.iso_639_1 == lang) { return $0.iso_639_1 == lang }
                if $0.width != $1.width { return $0.width > $1.width }
                return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
            }.first
        }
        func url(_ image: ArtworkImage?, size: String) -> URL? {
            guard let path = image?.file_path, path.hasPrefix("/") else { return nil }
            // The image CDN provides raster versions of SVG logos for native decoders.
            let rasterPath = path.hasSuffix(".svg") ? String(path.dropLast(4)) + ".png" : path
            return URL(string: "https://image.tmdb.org/t/p/\(size)\(rasterPath)")
        }
        // Never crop a backdrop into a poster or substitute another language's title.
        // TMDB marks text-free posters with a null language. A localized
        // poster usually contains its own title and must not sit behind a logo.
        let poster = images.posters.filter { $0.iso_639_1 == nil && $0.height > $0.width }
            .sorted { ($0.vote_average ?? 0) > ($1.vote_average ?? 0) }.first
        // TMDB labels Chinese logos `zh`, with optional region metadata.
        // Follow FlickIsle's region preference and use English only when no
        // matching-language logo exists.
        let usableLogos = images.logos
        let nativeLogos = usableLogos.filter { $0.iso_639_1?.caseInsensitiveCompare(lang) == .orderedSame }
        let logo: ArtworkImage?
        if lang == "zh", !nativeLogos.isEmpty {
            let preferredRegions = locale.uppercased().hasSuffix("-TW") || locale.uppercased().hasSuffix("-HK")
                ? ["TW", "HK"] : ["CN", "SG"]
            logo = nativeLogos.sorted {
                func rank(_ image: ArtworkImage) -> Int {
                    guard let region = image.iso_3166_1?.uppercased() else { return 2 }
                    return preferredRegions.firstIndex(of: region) ?? 3
                }
                if rank($0) != rank($1) { return rank($0) < rank($1) }
                return ($0.vote_average ?? 0) > ($1.vote_average ?? 0)
            }.first
        } else {
            logo = best(nativeLogos) ?? best(usableLogos.filter { $0.iso_639_1 == "en" })
                ?? best(usableLogos.filter { $0.iso_639_1 == nil })
        }
        let posterSize = displayWidthPixels <= 780 ? "w780" : "original"
        let logoSize = displayWidthPixels <= 780 ? "w500" : "w780"
        let localizedTitle = (television ? details.name : details.title)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return DetailArtwork(posterURL: url(poster, size: posterSize),
                             logoURL: url(logo, size: logoSize),
                             localizedTitle: localizedTitle?.isEmpty == false ? localizedTitle : nil)
    }
    private struct CatalogResponse: Decodable {
        struct Genre: Decodable { let id: Int?; let name: String }
        struct Cast: Decodable { let id: Int; let name: String; let character: String?; let profile_path: String? }
        struct Credits: Decodable { let cast: [Cast] }
        let id: Int
        let title: String?
        let name: String?
        let overview: String?
        let poster_path: String?
        let backdrop_path: String?
        let vote_average: Double?
        let release_date: String?
        let first_air_date: String?
        let status: String?
        let last_air_date: String?
        let genres: [Genre]?
        let origin_country: [String]?
        struct Country: Decodable { let iso_3166_1: String }
        let production_countries: [Country]?
        let original_language: String?
        let credits: Credits?
    }

    static func catalog(id: Int, television: Bool, token: String) async throws -> MediaMetadata {
        let localizationKey = LocalizationPreferences.current.contentID
        let data = try await catalogData(path: "\(television ? "tv" : "movie")/\(id)", token: token, credits: true)
        let value = try JSONDecoder().decode(CatalogResponse.self, from: data)
        let date = value.release_date ?? value.first_air_date
        return MediaMetadata(providerID: value.id, summary: value.overview, posterPath: value.poster_path,
            rating: value.vote_average, catalogVersion: 2, catalogKind: television ? .tv : .movie, localizedTitle: value.title ?? value.name,
            year: date.flatMap { Int($0.prefix(4)) }, releaseDate: date,
            genres: value.genres?.map(\.name), genreIDs: value.genres?.compactMap(\.id) ?? [],
            originCountries: value.origin_country ?? value.production_countries?.map(\.iso_3166_1) ?? [],
            originalLanguage: value.original_language, backdropPath: value.backdrop_path,
            cast: value.credits?.cast.prefix(30).map { .init(id: $0.id, name: $0.name, character: $0.character, profilePath: $0.profile_path) },
            localizationKey: localizationKey, seriesStatus: television ? value.status : nil,
            seriesEndDate: television && ["Ended", "Canceled", "Cancelled"].contains(value.status ?? "") ? value.last_air_date : nil)
    }

    static func catalogEpisode(id: Int, season: Int, number: Int, token: String) async throws -> CatalogEpisode {
        struct Episode: Decodable {
            let name: String; let overview: String?; let still_path: String?; let air_date: String?; let vote_average: Double?
        }
        let localizationKey = LocalizationPreferences.current.contentID
        let value = try JSONDecoder().decode(Episode.self, from: await catalogData(path: "tv/\(id)/season/\(season)/episode/\(number)", token: token))
        return .init(name: value.name, overview: value.overview, stillPath: value.still_path, airDate: value.air_date, rating: value.vote_average, localizationKey: localizationKey)
    }

    private static func catalogData(path: String, token: String, credits: Bool = false) async throws -> Data {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = [.init(name: "language", value: deviceLanguage), .init(name: "region", value: LocalizationPreferences.current.regionCode)]
        if credits { components.queryItems?.append(.init(name: "append_to_response", value: "credits")) }
        let authorization = authorize(&components, credential: token)
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw TMDBError.requestFailed }
        return data
    }

    // Matching requests use their own typed responses, without pulling credits/images.
    private static func recognitionData(path: String, query: [URLQueryItem] = [], token: String) async throws -> Data? {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(path)")!
        components.queryItems = [.init(name: "language", value: deviceLanguage), .init(name: "region", value: LocalizationPreferences.current.regionCode)] + query
        let authorization = authorize(&components, credential: token)
        var request = URLRequest(url: components.url!); request.timeoutInterval = 20
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        try Task.checkCancellation()
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TMDBError.requestFailed }
        if http.statusCode == 404 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw TMDBError.http(http.statusCode) }
        return data
    }
    static func recognitionSearch(title: String, kind: CatalogMediaKind, year: Int?, token: String) async throws -> [TMDBSearchResult] {
        let endpoint = kind == .unknown ? "multi" : kind.rawValue
        var query: [URLQueryItem] = [.init(name: "query", value: title), .init(name: "include_adult", value: "false")]
        if let year, kind != .unknown { query.append(.init(name: kind == .tv ? "first_air_date_year" : "year", value: String(year))) }
        guard let data = try await recognitionData(path: "search/\(endpoint)", query: query, token: token) else { return [] }
        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }
    static func recognitionDetails(id: Int, kind: CatalogMediaKind, token: String) async throws -> CatalogCandidateDetails? {
        guard let data = try await recognitionData(path: "\(kind.rawValue)/\(id)",
            query: [.init(name: "append_to_response", value: "alternative_titles,translations")], token: token) else { return nil }
        return try JSONDecoder().decode(CatalogCandidateDetails.self, from: data)
    }
    static func recognitionExternal(id: String, token: String) async throws -> [TMDBSearchResult] {
        struct Found: Decodable { var movie_results: [TMDBSearchResult]; var tv_results: [TMDBSearchResult] }
        guard let data = try await recognitionData(path: "find/\(id)", query: [.init(name: "external_source", value: "imdb_id")], token: token) else { return [] }
        let value = try JSONDecoder().decode(Found.self, from: data)
        return value.movie_results + value.tv_results
    }
    static func recognitionEpisodeGroup(id: String, token: String) async throws -> CatalogEpisodeGroup {
        guard let data = try await recognitionData(path: "tv/episode_group/\(id)", token: token) else { throw TMDBError.http(404) }
        return try JSONDecoder().decode(CatalogEpisodeGroup.self, from: data)
    }

    private struct SearchResponse: Decodable { let results: [TMDBSearchResult] }
    struct Person: Decodable, Identifiable {
        let id: Int
        let name: String
        let character: String?
    }
    struct Video: Decodable, Identifiable {
        let id: String
        let key: String
        let name: String
        let site: String
        let type: String
        var externalURL: URL? {
            guard site.caseInsensitiveCompare("YouTube") == .orderedSame,
                  key.range(of: "^[A-Za-z0-9_-]{6,20}$", options: .regularExpression) != nil else { return nil }
            return URL(string: "https://www.youtube.com/watch?v=\(key)")
        }
    }
    struct Extras: Decodable {
        struct Credits: Decodable { let cast: [Person] }
        struct Videos: Decodable { let results: [Video] }
        let credits: Credits?
        let videos: Videos?
    }

    static func search(title: String, television: Bool, token: String) async throws -> [TMDBSearchResult] {
        var components = URLComponents(string: "https://api.themoviedb.org/3/search/\(television ? "tv" : "movie")")!
        components.queryItems = [
            URLQueryItem(name: "query", value: title),
            URLQueryItem(name: "language", value: deviceLanguage), .init(name: "region", value: LocalizationPreferences.current.regionCode),
            URLQueryItem(name: "include_adult", value: "false")
        ]
        let authorization = authorize(&components, credential: token)
        var request = URLRequest(url: components.url!)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else {
            throw TMDBError.requestFailed
        }
        return try JSONDecoder().decode(SearchResponse.self, from: data).results
    }

    static func extras(id: Int, television: Bool, token: String) async throws -> Extras {
        var components = URLComponents(string: "https://api.themoviedb.org/3/\(television ? "tv" : "movie")/\(id)")!
        components.queryItems = [URLQueryItem(name: "append_to_response", value: "credits,videos"),
                                 URLQueryItem(name: "language", value: deviceLanguage), .init(name: "region", value: LocalizationPreferences.current.regionCode)]
        let authorization = authorize(&components, credential: token)
        var request = URLRequest(url: components.url!)
        if let authorization { request.setValue(authorization, forHTTPHeaderField: "Authorization") }
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode) else { throw TMDBError.requestFailed }
        return try JSONDecoder().decode(Extras.self, from: data)
    }
}

private enum TMDBError: LocalizedError {
    case requestFailed, http(Int)
    var errorDescription: String? {
        switch self {
        case .http(401): "TMDB 认证失败（HTTP 401），请检查 API 密钥或读取令牌。"
        case .http(403): "TMDB 拒绝访问（HTTP 403），请检查账户权限或网络访问限制。"
        case .http(429): "TMDB 请求过于频繁，请稍后重试。"
        case .http(let code): "TMDB 请求失败（HTTP \(code)）。"
        case .requestFailed: "无法获取 TMDB 资料，请检查令牌和网络连接。"
        }
    }
}
