import CloudKit
import CryptoKit
import Foundation

struct CloudPlaybackState: Sendable {
    let key: String
    let updatedAt: Date
    let favorite: Bool
    let watched: Bool
    let position: Double
    let duration: Double?
    let title: String
    let metadata: MediaMetadata?
    let collectionNames: [String]?
    var favoriteUpdatedAt: Date? = nil
    var playbackUpdatedAt: Date? = nil
}

struct CloudLibraryConfiguration: Sendable {
    let updatedAt: Date
    let collectionNames: [String]
    let smartPlaylists: [SmartPlaylist]
    let networkSources: NetworkSourceConfiguration?
    var preferences: [String: Data]? = nil
}

struct NetworkSourceConfiguration: Codable, Equatable, Sendable {
    var smb: [SMBSource]
    var webDAV: [WebDAVSource]
    var jellyfin: [JellyfinSource]
    var emby: [EmbySource]
    var plex: [PlexSource]
    var cloud: [CloudSource]
    var dlna: [DLNASource]?
}

@MainActor
enum CloudPlaybackSync {
    private static let recordType = "LucentPlaybackState"
    private static let configurationRecordType = "LucentLibraryConfiguration"

    private static func withSyncDatabase<R: Sendable>(
        _ body: @MainActor @Sendable (CKDatabase) async throws -> R
    ) async throws -> R {
        guard UserDefaults.standard.bool(forKey: "lucent.iCloudSyncEnabled"), !Task.isCancelled else { throw CancellationError() }
        let configuration = CKOperation.Configuration()
        configuration.allowsCellularAccess = NetworkUsagePolicy.allowsSync
        return try await CKContainer.default().privateCloudDatabase.configuredWith(configuration: configuration) { database in
            try await body(database)
        }
    }

    static func fetchConfiguration() async throws -> CloudLibraryConfiguration? {
        return try await withSyncDatabase { database in
            let id = CKRecord.ID(recordName: "library")
            let record: CKRecord
            do { record = try await database.record(for: id) }
            catch let error as CKError where error.code == .unknownItem { return nil }
            guard let updatedAt = record["updatedAt"] as? Date,
                  let collectionNames = record["collectionNames"] as? [String] else { return nil }
            let playlists = (record["smartPlaylists"] as? Data)
                .flatMap { try? JSONDecoder().decode([SmartPlaylist].self, from: $0) } ?? []
            let networkSources = (record["networkSources"] as? Data)
                .flatMap { try? JSONDecoder().decode(NetworkSourceConfiguration.self, from: $0) }
            return CloudLibraryConfiguration(updatedAt: updatedAt,
                                             collectionNames: collectionNames,
                                             smartPlaylists: playlists,
                                             networkSources: networkSources,
                                             preferences: (record["preferences"] as? Data).flatMap { try? JSONDecoder().decode([String: Data].self, from: $0) })
        }
    }

    static func saveConfiguration(_ configuration: CloudLibraryConfiguration) async throws {
        try await withSyncDatabase { database in
            let id = CKRecord.ID(recordName: "library")
            let record = (try? await database.record(for: id)) ??
                CKRecord(recordType: configurationRecordType, recordID: id)
            if let remoteDate = record["updatedAt"] as? Date,
               remoteDate > configuration.updatedAt { return }
            record["updatedAt"] = configuration.updatedAt
            record["collectionNames"] = configuration.collectionNames as NSArray
            record["smartPlaylists"] = try JSONEncoder().encode(configuration.smartPlaylists)
            if let networkSources = configuration.networkSources {
                record["networkSources"] = try JSONEncoder().encode(networkSources)
            }
            if let preferences = configuration.preferences {
                record["preferences"] = try JSONEncoder().encode(preferences)
            }
            _ = try await database.save(record)
        }
    }

    static func key(for item: MediaItem, library: LibraryStore) -> String? {
        let raw: String
        switch item.location {
        case .remote(let url): raw = "remote|\(url.absoluteString)"
        case .smbFile(let id, let path):
            guard let source = library.smbSources.first(where: { $0.id == id }) else { return nil }
            raw = "smb|\(source.host.lowercased())|\(source.share.lowercased())|\(path)"
        case .webDAVFile(let id, let path):
            guard let source = library.webDAVSources.first(where: { $0.id == id }) else { return nil }
            raw = "webdav|\(source.baseAddress.lowercased())|\(path)"
        case .jellyfinItem(let id, let itemID):
            guard let source = library.jellyfinSources.first(where: { $0.id == id }) else { return nil }
            raw = "jellyfin|\(source.baseAddress.lowercased())|\(itemID)"
        case .embyItem(let id, let itemID):
            guard let source = library.embySources.first(where: { $0.id == id }) else { return nil }
            raw = "emby|\(source.baseAddress.lowercased())|\(itemID)"
        case .plexItem(let id, let ratingKey, _):
            guard let source = library.plexSources.first(where: { $0.id == id }) else { return nil }
            raw = "plex|\(source.baseAddress.lowercased())|\(ratingKey)"
        case .cloudFile(let id, let identifier, _):
            guard let source = library.cloudSources.first(where: { $0.id == id }) else { return nil }
            raw = "cloud|\(source.provider.rawValue)|\(identifier)"
        case .bookmark, .folderFile:
            return nil
        }
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func available() async -> Bool {
        (try? await CKContainer.default().accountStatus()) == .available
    }

    static func fetchAll() async throws -> [String: CloudPlaybackState] {
        return try await withSyncDatabase { database in
            let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
            var page = try await database.records(matching: query, resultsLimit: 200)
            var states: [String: CloudPlaybackState] = [:]
            while true {
                for (_, result) in page.matchResults {
                    if case .success(let record) = result, let state = decode(record) {
                        states[state.key] = state
                    }
                }
                guard let cursor = page.queryCursor else { break }
                page = try await database.records(continuingMatchFrom: cursor, resultsLimit: 200)
            }
            return states
        }
    }

    static func save(_ state: CloudPlaybackState) async throws {
        try await withSyncDatabase { database in
            let id = CKRecord.ID(recordName: state.key)
            let record = (try? await database.record(for: id)) ?? CKRecord(recordType: recordType, recordID: id)
            if let remoteDate = record["updatedAt"] as? Date, remoteDate > state.updatedAt { return }
            try fill(record, state: state)
            _ = try await database.save(record)
        }
    }

    static func saveMany(_ states: [CloudPlaybackState]) async throws {
        for state in states { try await save(state) }
    }

    private static func fill(_ record: CKRecord, state: CloudPlaybackState) throws {
        record["updatedAt"] = state.updatedAt
        record["favorite"] = state.favorite ? 1 : 0
        record["favoriteUpdatedAt"] = state.favoriteUpdatedAt
        record["playbackUpdatedAt"] = state.playbackUpdatedAt
        record["watched"] = state.watched ? 1 : 0
        record["position"] = state.position
        if let duration = state.duration { record["duration"] = duration }
        else { record["duration"] = nil }
        record["title"] = state.title
        if let metadata = state.metadata {
            record["metadata"] = try JSONEncoder().encode(metadata)
        } else {
            record["metadata"] = nil
        }
        if let names = state.collectionNames { record["collections"] = names as NSArray }
        else { record["collections"] = nil }
    }

    private static func decode(_ record: CKRecord) -> CloudPlaybackState? {
        guard let date = record["updatedAt"] as? Date,
              let favorite = record["favorite"] as? Int,
              let watched = record["watched"] as? Int,
              let position = record["position"] as? Double,
              let title = record["title"] as? String else { return nil }
        let metadata = (record["metadata"] as? Data).flatMap { try? JSONDecoder().decode(MediaMetadata.self, from: $0) }
        return CloudPlaybackState(key: record.recordID.recordName, updatedAt: date,
                                  favorite: favorite != 0, watched: watched != 0,
                                  position: position, duration: record["duration"] as? Double,
                                  title: title, metadata: metadata,
                                  collectionNames: record["collections"] as? [String],
                                  favoriteUpdatedAt: record["favoriteUpdatedAt"] as? Date,
                                  playbackUpdatedAt: record["playbackUpdatedAt"] as? Date)
    }
}

/// An explicit allowlist: never sync credentials, caches, diagnostics or the device's opt-in switch.
enum CloudUserPreferences {
    static let keys: Set<String> = [
        "lucent.appearance.theme", "lucent.home.collapseDock", "lucent.home.selectedCatalog",
        "lucent.library.autoScanInterval", "lucent.playback.atmosLayout",
        "lucent.autoSkipSegments", "lucent.subtitleFontScale", "lucent.subtitleBackgroundOpacity",
        "lucent.player.controlsAutoHideDelay", "lucent.player.seekPreview", "lucent.player.seekInterval",
        "lucent.player.showRemainingTime", "lucent.player.videoScaleMode", "lucent.player.nextEpisodePrompt",
        "lucent.player.minimumResumePercent", "lucent.player.completedPercent", "lucent.playback.discTransition",
        "lucent.locale.interface", "lucent.locale.content", "lucent.locale.subtitles", "lucent.locale.audio",
        "lucent.locale.region", "lucent.locale.dateOrder", "lucent.locale.clock", "lucent.locale.zone",
        "lucent.danmaku.enabled", "lucent.danmaku.opacity", "lucent.danmaku.fontSize", "lucent.danmaku.area",
        "lucent.danmaku.customServers", "lucent.danmaku.selectedServer",
        "lucent.danmaku.duration", "lucent.danmaku.offset", "lucent.danmaku.blocked",
        "lucent.library.home.continue", "lucent.library.home.movies", "lucent.library.home.series",
        "lucent.library.home.favorites", "lucent.library.home.unwatched",
        "lucent.gestures.doubleTap", "lucent.gestures.seek", "lucent.gestures.seekSpan",
        "lucent.gestures.brightness", "lucent.gestures.volume", "lucent.gestures.hold",
        "lucent.gestures.holdRate", "lucent.gestures.pinch", "lucent.gestures.restoreBrightness",
        "lucent.network.cellularPlayback", "lucent.network.cellularSync", "lucent.network.cellularDownloads"
    ]
    static func capture(defaults: UserDefaults = .standard) -> [String: Data] {
        Dictionary(uniqueKeysWithValues: keys.compactMap { key in
            // Empty array represents a reset to the app default on every device.
            let values: [Any] = defaults.object(forKey: key).map { [$0] } ?? []
            return (try? PropertyListSerialization.data(fromPropertyList: values, format: .binary, options: 0))
                .map { (key, $0) }
        })
    }
    static func apply(_ values: [String: Data], defaults: UserDefaults = .standard) {
        for (key, data) in values where keys.contains(key) {
            guard let array = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [Any],
                  array.count <= 1 else { continue }
            if let value = array.first { defaults.set(value, forKey: key) }
            else { defaults.removeObject(forKey: key) }
        }
        NetworkUsagePolicy.notifySettingsChanged()
    }
}
