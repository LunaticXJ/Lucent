import Foundation

struct LocalMediaTechnicalInfo: Codable, Equatable, Sendable {
    var probedAt: Date
    var duration: Double
    var container: String?
    var width: Int
    var height: Int
    var videoCodec: String?
    var dynamicRange: String
    /// Persist stream fields using the same schema consumed by the detail cards.
    var streamData: Data
    var streams: [JellyfinItem.MediaSource.Stream] {
        (try? JSONDecoder().decode([JellyfinItem.MediaSource.Stream].self, from: streamData)) ?? []
    }
}

struct CatalogPerson: Codable, Equatable, Sendable {
    var id: Int
    var name: String
    var character: String?
    var profilePath: String?
}

struct CatalogEpisode: Codable, Equatable, Sendable {
    var name: String
    var overview: String?
    var stillPath: String?
    var airDate: String?
    var rating: Double?
    var localizationKey: String? = nil
}

enum CatalogMatching {
    /// Keep folder identity intact; interpret only a separated trailing year as release metadata.
    /// Mirrors Kodi/Plex's "Show name (Year)" convention, including unbracketed folders.
    static func seriesQuery(_ value: String) -> (title: String, year: Int?) {
        let pattern = #"^(.*?)\s*(?:[（(\[]\s*((?:19|20)\d{2})\s*[）)\]]|[ ._-]+((?:19|20)\d{2}))\s*$"#
        let ns = value as NSString
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: ns.length)) else {
            return (value, nil)
        }
        let title = ns.substring(with: match.range(at: 1)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return (value, nil) }
        let yearRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
        return (title, Int(ns.substring(with: yearRange)))
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func best(_ results: [TMDBSearchResult], title: String, year: Int?) -> TMDBSearchResult? {
        let title = normalized(title)
        let candidates = results.filter {
            [$0.displayTitle, $0.originalTitle, $0.originalName].compactMap { $0 }.contains { normalized($0) == title }
        }
        if let year {
            let dated = candidates.filter { Int($0.year ?? "") == year }
            return dated.count == 1 ? dated[0] : nil
        }
        // Ambiguous remakes require a manual match rather than guessing by popularity.
        return candidates.count == 1 ? candidates[0] : nil
    }
}

extension MediaItem {
    var catalogRecognitionPath: String {
        if let catalogPath { return catalogPath }
        switch location {
        case .folderFile(_, let path), .smbFile(_, let path), .webDAVFile(_, let path): return path
        case .cloudFile(_, _, let filename): return filename
        default: return identity?.seriesName ?? title
        }
    }
    var catalogRecognitionIdentity: MediaIdentity {
        let parsed = MediaNameParser.parse(relativePath: catalogRecognitionPath).identity
        if metadata == nil, parsed.seriesName != nil { return parsed }
        return identity ?? parsed
    }
    var needsCatalogEpisode: Bool {
        if case .episode(_, _, let number, _) = identity { return number > 0 }
        return false
    }
    var catalogGroupID: String {
        if identity?.seriesName != nil {
            return metadata.map { "tv:\($0.providerID)" } ?? "tv-name:\(CatalogMatching.normalized(identity?.seriesName ?? title))"
        }
        return metadata.map { "movie:\($0.providerID)" } ?? "file:\(id)"
    }
    var localPlaybackFeatures: PlaybackMediaFeatures {
        guard let info = technicalInfo else { return .unknown }
        let video = info.streams.first { $0.type == "Video" }
        let subtitles = info.streams.filter { ["ass", "ssa"].contains($0.codec?.lowercased() ?? "") }
        return PlaybackMediaFeatures(container: info.container, videoCodec: info.videoCodec,
            videoCodecTag: video?.codecTag, videoProfile: video?.profile, videoPixelFormat: video?.pixelFormat,
            styledSubtitleStreamIndices: subtitles.compactMap(\.index), defaultStyledSubtitle: subtitles.contains { $0.isDefault == true },
            audioCodec: info.streams.first { $0.type == "Audio" && $0.isDefault == true }?.codec ?? info.streams.first { $0.type == "Audio" }?.codec,
            dynamicRange: info.dynamicRange, resolution: "\(info.width)×\(info.height)")
    }
    var catalogDisplayTitle: String { metadata?.localizedTitle ?? identity?.seriesName ?? title }

    /// An adapter to reuse Lucent's existing local/remote detail UI. This creates
    /// no server item and performs no server requests.
    func localDetailItem(asSeries: Bool = false) -> JellyfinItem? {
        switch location {
        case .embyItem, .jellyfinItem, .plexItem: return nil
        default: break
        }
        func ticks(_ seconds: Double) -> Int64? {
            guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 10_000_000 - 1 else { return nil }
            return Int64(seconds * 10_000_000)
        }
        var value: [String: Any] = ["Id": id.uuidString, "Name": asSeries ? catalogDisplayTitle : (catalogEpisode?.name ?? (identity?.seriesName == nil ? catalogDisplayTitle : title)),
            "Type": asSeries ? "Series" : (identity?.seriesName == nil ? "Movie" : "Episode"),
            "UserData": ["Played": watched, "IsFavorite": isFavorite, "PlaybackPositionTicks": ticks(position) ?? 0]]
        if let summary = asSeries ? metadata?.summary : (catalogEpisode?.overview ?? metadata?.summary) { value["Overview"] = summary }
        if let metadata {
            value["ProviderIds"] = ["Tmdb": String(metadata.providerID)]
            value["CommunityRating"] = asSeries ? metadata.rating : (catalogEpisode?.rating ?? metadata.rating)
            value["ProductionYear"] = metadata.year
            value["Genres"] = metadata.genres
            value["PremiereDate"] = catalogEpisode?.airDate ?? metadata.releaseDate
            value["People"] = metadata.cast?.map { person -> [String: Any] in
                var fields: [String: Any] = ["Id": String(person.id), "Name": person.name]
                fields["Role"] = person.character; fields["PrimaryImageTag"] = person.profilePath
                return fields
            }
        }
        if case .episode(let series, let season, let episode, _) = identity {
            value["SeriesName"] = metadata?.localizedTitle ?? series
            value["ParentIndexNumber"] = season; value["IndexNumber"] = episode
        }
        if let duration = technicalInfo?.duration ?? duration, let durationTicks = ticks(duration), durationTicks > 0 { value["RunTimeTicks"] = durationTicks }
        let path: String?
        switch location {
        case .folderFile(_, let p), .smbFile(_, let p), .webDAVFile(_, let p): path = p
        case .cloudFile(_, _, let filename): path = filename
        case .remote(let url): path = url.lastPathComponent
        default: path = nil
        }
        value["Path"] = path
        if let info = technicalInfo {
            var source: [String: Any] = ["MediaStreams": (try? JSONSerialization.jsonObject(with: info.streamData)) ?? []]
            source["Container"] = info.container
            value["MediaSources"] = [source]
        }
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else { return nil }
        return try? JSONDecoder().decode(JellyfinItem.self, from: data)
    }
}

// Independently implemented from the documented recognition decision rules of
// MoviePilot v2 (see docs/design/aggregate-library-v2/tmdb-recognition.md).
// No upstream implementation code is embedded or imported.
enum CatalogMediaKind: String, Codable, Sendable { case movie, tv, unknown }

struct CatalogRecognitionInput: Hashable, Sendable {
    var names: [String]
    var year: Int?
    var kind: CatalogMediaKind
    var season: Int?
    var tmdbID: Int?
    var imdbID: String?
    var episodeGroup: String?

    init(item: MediaItem) {
        let path = item.catalogRecognitionPath
        let identity = item.catalogRecognitionIdentity
        let rawTitle = identity.seriesName ?? item.title
        let title = CatalogRecognitionInput.stripTags(rawTitle)
        let query = CatalogMatching.seriesQuery(title)
        names = Self.searchNames(query.title)
        year = query.year ?? identity.movieYear
        if case .episode(_, let value, _, _) = identity { kind = .tv; season = value }
        else { kind = .unknown; season = nil }
        if let knownKind = item.metadata?.catalogKind { kind = knownKind }
        tmdbID = item.metadata?.providerID ?? Self.capture(#"(?i)[\[{;]tmdb(?:id)?[=:-](\d+)(?=[;\]}])"#, in: path).flatMap(Int.init)
        imdbID = Self.capture(#"(?i)\b(tt\d{7,10})\b"#, in: path)
        episodeGroup = Self.capture(#"(?i)(?:[;{]g=|episode_group=)([0-9a-f]+)"#, in: path)
        if let type = Self.capture(#"(?i)type=(movie|tv)"#, in: path) { kind = CatalogMediaKind(rawValue: type.lowercased()) ?? kind }
    }
    init(names: [String], year: Int? = nil, kind: CatalogMediaKind = .unknown, season: Int? = nil,
         tmdbID: Int? = nil, imdbID: String? = nil, episodeGroup: String? = nil) {
        self.names = names; self.year = year; self.kind = kind; self.season = season
        self.tmdbID = tmdbID; self.imdbID = imdbID; self.episodeGroup = episodeGroup
    }
    private static func capture(_ pattern: String, in value: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
    static func stripTags(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)[\[{](?:tmdb(?:id)?|imdb(?:id)?)[=:-][^\]}]+[\]}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\{\[.*?\]\}"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static func searchNames(_ value: String) -> [String] {
        let clean = stripTags(value)
        let chinese = clean.range(of: #"[\p{Han}]"#, options: .regularExpression) != nil
        let latin = clean.range(of: #"[A-Za-z]"#, options: .regularExpression) != nil
        var values: [String] = []
        if chinese && latin {
            // Chinese and English release titles are separate search terms.
            let cn = clean.replacingOccurrences(of: #"[A-Za-z][A-Za-z0-9 .:'’_-]*"#, with: "", options: .regularExpression)
            let en = clean.replacingOccurrences(of: #"[\p{Han}]"#, with: " ", options: .regularExpression)
            values += [cn, cn.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? cn, en]
        } else {
            values += [clean, clean.applyingTransform(StringTransform("Traditional-Simplified"), reverse: false) ?? clean]
        }
        var seen = Set<String>()
        return values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines.union(.init(charactersIn: "[]()（）【】.-_"))) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

struct CatalogCandidateDetails: Decodable, Sendable {
    struct Aliases: Decodable, Sendable { var titles: [Alias]?; var results: [Alias]? }
    struct Alias: Decodable, Sendable { var title: String }
    struct Translations: Decodable, Sendable { var translations: [Translation] }
    struct Translation: Decodable, Sendable {
        struct Value: Decodable, Sendable { var title: String?; var name: String? }
        var data: Value
    }
    struct Season: Decodable, Sendable { var season_number: Int; var air_date: String? }
    var id: Int
    var title: String?
    var name: String?
    var original_title: String?
    var original_name: String?
    var release_date: String?
    var first_air_date: String?
    var alternative_titles: Aliases?
    var translations: Translations?
    var seasons: [Season]?
    var allNames: [String] {
        [title, name, original_title, original_name].compactMap { $0 } +
        (alternative_titles?.titles ?? alternative_titles?.results ?? []).map(\.title) +
        (translations?.translations ?? []).compactMap { $0.data.title ?? $0.data.name }
    }
    var year: Int? { (release_date ?? first_air_date).flatMap { Int($0.prefix(4)) } }
}

struct CatalogEpisodeGroup: Decodable, Sendable {
    struct Group: Decodable, Sendable {
        struct Episode: Decodable, Sendable {
            var order: Int; var season_number: Int; var episode_number: Int; var air_date: String?
        }
        var order: Int; var episodes: [Episode]
    }
    var groups: [Group]
}

struct CatalogRecognitionResult: Sendable {
    var id: Int
    var kind: CatalogMediaKind
    var reason: String
}

actor TMDBCatalogRecognizer {
    typealias Search = @Sendable (String, CatalogMediaKind, Int?) async throws -> [TMDBSearchResult]
    typealias Details = @Sendable (Int, CatalogMediaKind) async throws -> CatalogCandidateDetails?
    typealias External = @Sendable (String) async throws -> [TMDBSearchResult]
    typealias EpisodeGroup = @Sendable (String) async throws -> CatalogEpisodeGroup
    private let search: Search
    private let details: Details
    private let external: External
    private let episodeGroup: EpisodeGroup
    private var searches: [String: [TMDBSearchResult]] = [:]
    private var detailCache: [String: CatalogCandidateDetails] = [:]
    private var missingDetails = Set<String>()
    private var groups: [String: CatalogEpisodeGroup] = [:]
    private var recognized: [CatalogRecognitionInput: CatalogRecognitionResult] = [:]
    private var unmatched = Set<CatalogRecognitionInput>()

    init(search: @escaping Search, details: @escaping Details, external: @escaping External,
         episodeGroup: @escaping EpisodeGroup) {
        self.search = search; self.details = details; self.external = external; self.episodeGroup = episodeGroup
    }
    init(token: String) {
        search = { try await TMDBService.recognitionSearch(title: $0, kind: $1, year: $2, token: token) }
        details = { try await TMDBService.recognitionDetails(id: $0, kind: $1, token: token) }
        external = { try await TMDBService.recognitionExternal(id: $0, token: token) }
        episodeGroup = { try await TMDBService.recognitionEpisodeGroup(id: $0, token: token) }
    }
    static func nameKey(_ value: String) -> String {
        let ignored = CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: "、.。,，·:：;；!！?？'’\"“”()（）[]【】「」-—―+|\\_/&#～~\u{200B}\u{200C}\u{200D}\u{FEFF}"))
        return value.unicodeScalars.filter { !ignored.contains($0) }.map(String.init).joined().uppercased()
    }
    private func named(_ names: [String], _ title: String) -> Bool {
        let key = Self.nameKey(title)
        return !key.isEmpty && names.contains { Self.nameKey($0) == key }
    }
    private func directNames(_ candidate: TMDBSearchResult) -> [String] {
        [candidate.title, candidate.name, candidate.originalTitle, candidate.originalName].compactMap { $0 }
    }
    private func getDetails(_ id: Int, _ kind: CatalogMediaKind) async throws -> CatalogCandidateDetails? {
        let key = "\(kind.rawValue):\(id)"
        if let value = detailCache[key] { return value }
        if missingDetails.contains(key) { return nil }
        try Task.checkCancellation()
        let value = try await details(id, kind)
        if let value { detailCache[key] = value } else { missingDetails.insert(key) }
        return value
    }
    private func candidates(_ title: String, _ kind: CatalogMediaKind, _ year: Int?) async throws -> [TMDBSearchResult] {
        let key = "\(kind.rawValue)|\(title)|\(year.map(String.init) ?? "")"
        if let value = searches[key] { return value }
        try Task.checkCancellation()
        let value = try await search(title, kind, year)
        let sorted = value.filter { $0.mediaType != "person" }.sorted {
            if kind == .unknown, $0.recognitionKind != $1.recognitionKind { return $0.recognitionKind == .movie }
            return ($0.releaseDate ?? $0.firstAirDate ?? "") > ($1.releaseDate ?? $1.firstAirDate ?? "")
        }
        searches[key] = sorted
        return sorted
    }
    private func choose(_ title: String, kind: CatalogMediaKind, year: Int?) async throws -> CatalogRecognitionResult? {
        let values = try await candidates(title, kind, year).filter { year == nil || Int($0.year ?? "") == year }
        // Title/original-title pass finishes before any alias/detail requests.
        for value in values where named(directNames(value), title) {
            return .init(id: value.id, kind: kind == .unknown ? value.recognitionKind : kind, reason: "标题/原名匹配")
        }
        for value in values {
            let type = kind == .unknown ? value.recognitionKind : kind
            if let detail = try await getDetails(value.id, type), named(detail.allNames, title) {
                return .init(id: value.id, kind: type, reason: "别名/译名匹配")
            }
        }
        return nil
    }
    private func getGroup(_ id: String) async throws -> CatalogEpisodeGroup {
        if let value = groups[id] { return value }
        let value = try await episodeGroup(id); groups[id] = value; return value
    }
    func coordinates(group: String?, season: Int, episode: Int) async throws -> (season: Int, episode: Int) {
        guard let group else { return (season, episode) }
        let value = try await getGroup(group)
        guard let row = value.groups.first(where: { $0.order == season })?.episodes.first(where: { $0.order + 1 == episode }) else {
            throw URLError(.resourceUnavailable)
        }
        return (row.season_number, row.episode_number)
    }
    private func seasonMatch(_ title: String, input: CatalogRecognitionInput) async throws -> CatalogRecognitionResult? {
        guard let year = input.year, let season = input.season else { return nil }
        let values = try await candidates(title, .tv, nil)
        for value in values {
            if Int(value.year ?? "") == year, named(directNames(value), title) {
                return .init(id: value.id, kind: .tv, reason: "剧集首播年份匹配")
            }
            guard let detail = try await getDetails(value.id, .tv), named(detail.allNames, title) else { continue }
            var seasonYear: Int?
            if let id = input.episodeGroup {
                let group = try await getGroup(id)
                seasonYear = group.groups.first { $0.order == season }?.episodes.first?.air_date.flatMap { Int($0.prefix(4)) }
            } else {
                seasonYear = detail.seasons?.first { $0.season_number == season }?.air_date.flatMap { Int($0.prefix(4)) }
            }
            if Int(value.year ?? "") == year || seasonYear == year {
                return .init(id: value.id, kind: .tv, reason: "剧集/当前季年份匹配")
            }
        }
        return nil
    }
    private func typedMatch(_ title: String, kind: CatalogMediaKind, input: CatalogRecognitionInput) async throws -> CatalogRecognitionResult? {
        if kind == .tv, let value = try await seasonMatch(title, input: input) { return value }
        let years: [Int?] = input.year.map { [$0, $0 + 1, $0 - 1] } ?? [nil]
        for year in years {
            if let value = try await choose(title, kind: kind, year: year) { return value }
        }
        return nil
    }
    func recognize(_ input: CatalogRecognitionInput) async throws -> CatalogRecognitionResult? {
        if let value = recognized[input] { return value }
        if unmatched.contains(input) { return nil }
        let value = try await resolve(input)
        if let value { recognized[input] = value } else { unmatched.insert(input) }
        return value
    }
    private func resolve(_ input: CatalogRecognitionInput) async throws -> CatalogRecognitionResult? {
        if let id = input.tmdbID {
            let types: [CatalogMediaKind] = input.kind == .unknown ? [.tv, .movie] : [input.kind]
            var values: [(CatalogMediaKind, CatalogCandidateDetails)] = []
            for kind in types { if let value = try await getDetails(id, kind) { values.append((kind, value)) } }
            if values.count == 1 { return .init(id: id, kind: values[0].0, reason: "指定 TMDB ID") }
            if values.count == 2 {
                let ranked = values.map { kind, detail in
                    let titleMatch = input.names.contains { name in detail.allNames.contains { $0.contains(name) || name.contains($0) } }
                    return (kind, (titleMatch ? 2 : 0) + (input.year != nil && input.year == detail.year ? 1 : 0))
                }.sorted { $0.1 > $1.1 }
                if ranked[0].1 > ranked[1].1 { return .init(id: id, kind: ranked[0].0, reason: "TMDB ID 类型消歧") }
            }
            // An explicit identity must never silently become another title.
            return nil
        }
        if let id = input.imdbID {
            let values = try await external(id).filter { input.kind == .unknown || $0.recognitionKind == input.kind }
            if let value = values.first { return .init(id: value.id, kind: value.recognitionKind, reason: "IMDb ID") }
        }
        for title in input.names {
            if input.kind == .tv {
                if let value = try await typedMatch(title, kind: .tv, input: input) { return value }
                if input.year != nil, let value = try await choose(title, kind: .tv, year: nil) { return value }
            } else if input.kind == .unknown && input.year == nil {
                if let value = try await choose(title, kind: .unknown, year: nil) { return value }
            } else {
                if let value = try await typedMatch(title, kind: .movie, input: input) { return value }
                if let value = try await typedMatch(title, kind: .tv, input: input) { return value }
                if let value = try await choose(title, kind: .unknown, year: nil) { return value }
            }
        }
        return nil
    }
}

extension TMDBSearchResult {
    var recognitionKind: CatalogMediaKind { mediaType == "tv" || (mediaType == nil && name != nil && title == nil) ? .tv : .movie }
}
