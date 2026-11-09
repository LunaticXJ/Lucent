import Foundation

/// A directory listing does not require a recursive media-library scan.
struct SourceDirectoryEntry: Identifiable, Sendable {
    let name: String
    let path: String
    let isDirectory: Bool
    var id: String { path }
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm",
        "m2ts", "mts", "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"]
}

enum MediaLocation: Codable, Equatable, Sendable {
    case remote(URL)
    case bookmark(Data)
    case folderFile(sourceID: UUID, relativePath: String)
    case smbFile(sourceID: UUID, relativePath: String)
    case webDAVFile(sourceID: UUID, relativePath: String)
    case jellyfinItem(sourceID: UUID, itemID: String)
    case embyItem(sourceID: UUID, itemID: String)
    case plexItem(sourceID: UUID, ratingKey: String, partKey: String)
    case cloudFile(sourceID: UUID, identifier: String, filename: String)
}

enum CloudProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case dropbox, googleDrive, pan115, pan123, baiduPan, guangyaPan
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dropbox: "Dropbox"
        case .googleDrive: "Google Drive"
        case .pan115: "115 网盘"
        case .pan123: "123 云盘"
        case .baiduPan: "百度网盘"
        case .guangyaPan: "光鸭云盘"
        }
    }
}

struct CloudSource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var provider: CloudProvider
    var name: String
    var lastScannedAt: Date?
    var oauthClientID: String?

    init(provider: CloudProvider, name: String, oauthClientID: String? = nil) {
        id = UUID()
        self.provider = provider
        self.name = name
        lastScannedAt = nil
        self.oauthClientID = oauthClientID
    }
}

struct DLNASource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var descriptionAddress: String
    var lastScannedAt: Date?
    var mediaIDs: [UUID]

    init(name: String, descriptionURL: URL) {
        id = UUID()
        self.name = name
        descriptionAddress = descriptionURL.absoluteString
        lastScannedAt = nil
        mediaIDs = []
    }
}

struct FolderSource: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var bookmark: Data
    var lastScannedAt: Date?

    init(name: String, bookmark: Data) {
        id = UUID()
        self.name = name
        self.bookmark = bookmark
        lastScannedAt = nil
    }
}

struct SMBSource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var host: String
    var share: String
    var domain: String? = nil
    var syncAllowed: Bool? = nil
    var username: String
    var lastScannedAt: Date?
    var displayName: String?

    init(host: String, share: String, username: String) {
        id = UUID()
        self.host = host
        self.share = share
        self.username = username
        lastScannedAt = nil
    }

    var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? "\(share) · \(host)" }
}

struct WebDAVSource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var baseAddress: String
    var syncAllowed: Bool? = nil
    var username: String
    var lastScannedAt: Date?
    var displayName: String?

    init(baseAddress: String, username: String) {
        id = UUID()
        self.baseAddress = baseAddress
        self.username = username
        lastScannedAt = nil
    }

    var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (URL(string: baseAddress)?.host ?? baseAddress) }
}

struct JellyfinSource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var baseAddress: String
    var userID: String
    var lastScannedAt: Date?
    var displayName: String?
    var username: String?
    var usesTokenLogin: Bool?

    init(baseAddress: String, userID: String) {
        id = UUID()
        self.baseAddress = baseAddress
        self.userID = userID
        lastScannedAt = nil
        displayName = nil
        username = nil
        usesTokenLogin = nil
    }

    var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (URL(string: baseAddress)?.host ?? baseAddress) }
}

struct PlexSource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var baseAddress: String
    var lastScannedAt: Date?
    var displayName: String?
    var username: String?

    init(baseAddress: String) {
        id = UUID()
        self.baseAddress = baseAddress
        lastScannedAt = nil
        displayName = nil
        username = nil
    }

    var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (URL(string: baseAddress)?.host ?? baseAddress) }
}

/// NAS media services expose an Emby-compatible API; retain their identity separately
/// from the transport so credentials, catalog IDs and playback remain source-scoped.
enum EmbyServerKind: String, Codable, CaseIterable, Sendable {
    case emby, fnos, zspace, ugreen
    var title: String {
        switch self {
        case .emby: "Emby"
        case .fnos: "飞牛私有云"
        case .zspace: "极空间影视"
        case .ugreen: "绿联云影视"
        }
    }
    var assetName: String {
        switch self {
        case .emby: "EmbyBrand"
        case .fnos: "FnOSBrand"
        case .zspace: "ZSpaceBrand"
        case .ugreen: "UGREENBrand"
        }
    }
    var defaultPort: String {
        switch self {
        case .emby: "8096"
        case .fnos: "8005"
        case .zspace: "8021"
        case .ugreen: "9443"
        }
    }
    var usesHTTPS: Bool { self == .ugreen }
}

struct EmbySource: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var baseAddress: String
    var userID: String
    var lastScannedAt: Date?
    var displayName: String?
    var username: String?
    var usesTokenLogin: Bool?
    var serverKind: EmbyServerKind?
    var kind: EmbyServerKind { serverKind ?? .emby }

    init(baseAddress: String, userID: String) {
        id = UUID()
        self.baseAddress = baseAddress
        self.userID = userID
        lastScannedAt = nil
        displayName = nil
        username = nil
        usesTokenLogin = nil
    }

    var name: String { displayName.flatMap { $0.isEmpty ? nil : $0 } ?? (URL(string: baseAddress)?.host ?? baseAddress) }
}

struct LibrarySnapshot: Codable {
    var fileSources: [LibraryFileSource]? = nil
    var storageFileIdentities: [String: UUID]? = nil
    var pendingScopeScanIDs: [UUID]? = nil
    var items: [MediaItem]
    var folders: [FolderSource]
    var smbSources: [SMBSource]?
    var webDAVSources: [WebDAVSource]?
    var jellyfinSources: [JellyfinSource]?
    var embySources: [EmbySource]?
    var plexSources: [PlexSource]?
    var cloudSources: [CloudSource]?
    var dlnaSources: [DLNASource]?
    var collections: [MediaCollection]?
    var smartPlaylists: [SmartPlaylist]?
    var libraryConfigUpdatedAt: Date?
    var viewerProfiles: [ViewerProfile]?
    var activeProfileID: UUID?
}

struct ProfilePlaybackState: Codable, Equatable {
    var position: Double
    var watched: Bool
    var favorite: Bool
    var lastPlayedAt: Date?
    var stateUpdatedAt: Date?
    var favoriteUpdatedAt: Date?

    init(item: MediaItem) {
        position = item.position
        watched = item.watched
        favorite = item.isFavorite
        lastPlayedAt = item.lastPlayedAt
        stateUpdatedAt = item.stateUpdatedAt
        favoriteUpdatedAt = item.favoriteUpdatedAt
    }
}

struct ViewerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var isChild: Bool
    var blockedItemIDs: [UUID]
    var playbackStates: [UUID: ProfilePlaybackState]

    init(name: String, isChild: Bool) {
        id = UUID()
        self.name = name
        self.isChild = isChild
        blockedItemIDs = []
        playbackStates = [:]
    }
}

struct MediaCollection: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var itemIDs: [UUID]

    init(name: String) {
        id = UUID()
        self.name = name
        itemIDs = []
    }
}

struct SmartPlaylist: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var name: String
    var titleContains: String
    var seriesContains: String
    var favoritesOnly: Bool
    var unwatchedOnly: Bool
    var addedWithinDays: Int?
    var minimumRating: Double?

    init(name: String, titleContains: String = "", seriesContains: String = "",
         favoritesOnly: Bool = false, unwatchedOnly: Bool = false,
         addedWithinDays: Int? = nil, minimumRating: Double? = nil) {
        id = UUID()
        self.name = name
        self.titleContains = titleContains
        self.seriesContains = seriesContains
        self.favoritesOnly = favoritesOnly
        self.unwatchedOnly = unwatchedOnly
        self.addedWithinDays = addedWithinDays
        self.minimumRating = minimumRating
    }

    func includes(_ item: MediaItem, now: Date = Date()) -> Bool {
        if !titleContains.isEmpty && !item.title.localizedCaseInsensitiveContains(titleContains) { return false }
        if !seriesContains.isEmpty &&
            !(item.identity?.seriesName?.localizedCaseInsensitiveContains(seriesContains) ?? false) { return false }
        if favoritesOnly && !item.isFavorite { return false }
        if unwatchedOnly && item.watched { return false }
        if let addedWithinDays, item.addedAt < now.addingTimeInterval(-Double(addedWithinDays) * 86_400) {
            return false
        }
        if let minimumRating, (item.metadata?.rating ?? 0) < minimumRating { return false }
        return true
    }
}

struct MediaMetadata: Codable, Equatable, Sendable {
    var providerID: Int
    var summary: String?
    var posterPath: String?
    var rating: Double?
    var catalogVersion: Int? = nil
    var catalogKind: CatalogMediaKind? = nil
    var localizedTitle: String? = nil
    var year: Int? = nil
    var releaseDate: String? = nil
    var genres: [String]? = nil
    var genreIDs: [Int]? = nil
    var originCountries: [String]? = nil
    var originalLanguage: String? = nil
    var backdropPath: String? = nil
    var cast: [CatalogPerson]? = nil
    var localizationKey: String? = nil
    var seriesStatus: String? = nil
    var seriesEndDate: String? = nil

    var posterURL: URL? {
        guard let posterPath, posterPath.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w500\(posterPath)")
    }
    var originalPosterURL: URL? {
        guard let posterPath, posterPath.hasPrefix("/") else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/original\(posterPath)")
    }
}

enum MediaIdentity: Codable, Equatable, Sendable {
    case movie(year: Int?)
    case episode(series: String, season: Int, number: Int, name: String?)

    var movieYear: Int? {
        if case .movie(let year) = self { return year }
        return nil
    }
    var episodeSortOrder: Int {
        if case .episode(_, let season, let number, _) = self { return season * 100_000 + number }
        return 0
    }

    var seriesName: String? {
        if case .episode(let series, _, _, _) = self { return series }
        return nil
    }

    static func seasonTitle(_ season: Int) -> String {
        season == 0 ? "特别篇".lucentLocalized : String(format: "第 %lld 季".lucentLocalized, season)
    }

    static func specialEpisodeTitle(_ number: Int) -> String {
        String(format: "%@ · 第 %lld 集".lucentLocalized, seasonTitle(0), number)
    }

    var episodeLabel: String? {
        if case .episode(_, let season, let number, _) = self {
            return season == 0 ? Self.specialEpisodeTitle(number) : String(format: "S%02dE%02d", season, number)
        }
        return nil
    }
}

struct MediaItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var location: MediaLocation
    var addedAt: Date
    var duration: Double?
    var position: Double
    var watched: Bool
    var identity: MediaIdentity?
    var favorite: Bool?
    var seriesFavorite: Bool?
    var lastPlayedAt: Date?
    var metadata: MediaMetadata?
    var downloadFileName: String?
    var stateUpdatedAt: Date?
    var favoriteUpdatedAt: Date?
    var metadataAttemptedAt: Date?
    var serverSummary: String?
    var serverPosterKey: String?
    var posterFileName: String?
    var missingSince: Date?
    var customSubtitleFileName: String?
    var serverFileExtension: String?
    var skipIntroEnd: Double?
    var skipCreditsStart: Double?
    var skipCreditsDuration: Double? = nil
    var extraItemIDs: [UUID]?
    var personalRating: Int?
    var technicalInfo: LocalMediaTechnicalInfo? = nil
    var technicalProbeAttemptedAt: Date? = nil
    var technicalProbeError: String? = nil
    var metadataRetryAfter: Date? = nil
    var metadataMatchStatus: String? = nil
    var catalogEpisode: CatalogEpisode? = nil
    var catalogPath: String? = nil

    init(title: String, location: MediaLocation, identity: MediaIdentity? = nil) {
        self.id = UUID()
        self.title = title
        self.location = location
        self.addedAt = Date()
        self.duration = nil
        self.position = 0
        self.watched = false
        self.identity = identity
        self.favorite = false
        self.lastPlayedAt = nil
        self.metadata = nil
        self.downloadFileName = nil
        self.stateUpdatedAt = nil
        self.metadataAttemptedAt = nil
        self.serverSummary = nil
        self.serverPosterKey = nil
        self.posterFileName = nil
        self.missingSince = nil
        self.customSubtitleFileName = nil
        self.serverFileExtension = nil
        self.skipIntroEnd = nil
        self.skipCreditsStart = nil
        self.extraItemIDs = nil
        self.personalRating = nil
    }

    var isFavorite: Bool { favorite == true }
    var resumePosition: Double {
        PlaybackProgressPolicy.current.resumePosition(position: position, duration: duration, watched: watched)
    }
    var isInProgress: Bool { resumePosition > 0 }
    var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(max(position / duration, 0), 1)
    }
}

extension MediaItem {
    var catalogDisplayYear: Int? {
        [metadata?.year, metadata?.releaseDate.flatMap { Int($0.prefix(4)) },
         identity?.movieYear, catalogEpisode?.airDate.flatMap { Int($0.prefix(4)) }]
            .compactMap { $0 }.first { $0 > 0 }
    }
    var catalogDisplayYearText: String? { CatalogYearLabel.text(start: catalogDisplayYear, isSeries: identity?.seriesName != nil, status: metadata?.seriesStatus, endDate: metadata?.seriesEndDate) }
}
