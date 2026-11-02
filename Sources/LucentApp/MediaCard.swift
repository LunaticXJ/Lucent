import Foundation

/// Server-independent presentation data. Playback keeps the original source identity.
struct MediaCard: Sendable {
    private let original: JellyfinItem?
    let isFolder: Bool?
    let providerIDs: [String: String]?
    let id: String
    let title: String
    let kind: String
    let summary: String?
    let rating: Double?
    let year: Int?
    let genres: [String]?
    let releaseDate: String?
    let seriesName: String?
    let season: Int?
    let episode: Int?
    let durationTicks: Int64?
    let played: Bool
    let favorite: Bool
    let positionTicks: Int64

    init(local item: MediaItem, asSeries: Bool) {
        func ticks(_ seconds: Double?) -> Int64? {
            guard let seconds, seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 10_000_000 - 1 else { return nil }
            return Int64(seconds * 10_000_000)
        }
        original = nil; isFolder = false
        providerIDs = item.metadata.map { ["Tmdb": String($0.providerID)] }
        id = item.id.uuidString
        title = asSeries ? item.catalogDisplayTitle : (item.catalogEpisode?.name ?? item.catalogDisplayTitle)
        kind = asSeries ? "Series" : (item.identity?.seriesName == nil ? "Movie" : "Episode")
        summary = asSeries ? item.metadata?.summary : (item.catalogEpisode?.overview ?? item.metadata?.summary)
        rating = asSeries ? item.metadata?.rating : (item.catalogEpisode?.rating ?? item.metadata?.rating)
        year = item.metadata?.year; genres = item.metadata?.genres
        releaseDate = item.catalogEpisode?.airDate ?? item.metadata?.releaseDate
        if case .episode(let series, let seasonValue, let episodeValue, _) = item.identity {
            seriesName = item.metadata?.localizedTitle ?? series; season = seasonValue; episode = episodeValue
        } else { seriesName = nil; season = nil; episode = nil }
        durationTicks = ticks(item.technicalInfo?.duration ?? item.duration)
        positionTicks = ticks(item.position) ?? 0
        played = item.watched; favorite = item.isFavorite
    }
    init(server item: JellyfinItem) {
        original = item; isFolder = item.isFolder
        providerIDs = item.providerIds
        id = item.id; title = item.name; kind = item.type; summary = item.overview
        rating = item.communityRating; year = item.productionYear; genres = item.genres
        releaseDate = item.premiereDate; seriesName = item.seriesName
        season = item.parentIndexNumber; episode = item.indexNumber; durationTicks = item.runTimeTicks
        positionTicks = item.userData?.playbackPositionTicks ?? 0
        played = item.userData?.played ?? false; favorite = item.userData?.isFavorite ?? false
    }
    init(id: String, title: String, kind: String, isFolder: Bool) {
        self.id = id; self.title = title; self.kind = kind; self.isFolder = isFolder
        original = nil; providerIDs = nil; summary = nil; rating = nil; year = nil
        genres = nil; releaseDate = nil; seriesName = nil; season = nil; episode = nil
        durationTicks = nil; played = false; favorite = false; positionTicks = 0
    }
    // Display aliases keep the existing layout readable while its data is transport-independent.
    var name: String { title }
    var type: String { kind }
    var overview: String? { summary }
    var communityRating: Double? { rating }
    var productionYear: Int? { year }
    var premiereDate: String? { releaseDate }
    var runTimeTicks: Int64? { durationTicks }
    var identity: MediaIdentity {
        if kind == "Series" { return .episode(series: title, season: 1, number: 0, name: nil) }
        return kind == "Episode" ? .episode(series: seriesName ?? title, season: season ?? 0, number: episode ?? 0, name: title) : .movie(year: year)
    }
    struct WatchState: Sendable { let played: Bool; let isFavorite: Bool; let playbackPositionTicks: Int64 }
    var userData: WatchState? { .init(played: played, isFavorite: favorite, playbackPositionTicks: positionTicks) }
    /// Compatibility boundary for existing detail/hero consumers; no JSON round trip.
    var legacyPresentation: JellyfinItem {
        if let original { return original }
        return JellyfinItem(id: id, name: title, type: kind, isFolder: isFolder, seriesName: seriesName, genres: genres,
            parentIndexNumber: season, indexNumber: episode, productionYear: year,
            premiereDate: releaseDate, communityRating: rating, runTimeTicks: durationTicks,
            userData: .init(played: played, isFavorite: favorite, playbackPositionTicks: positionTicks,
                            lastPlayedDate: nil, unplayedItemCount: nil), overview: summary, providerIds: providerIDs)
    }
}
