import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var folders: [FolderSource] = []
    @Published private(set) var smbSources: [SMBSource] = []
    @Published private(set) var webDAVSources: [WebDAVSource] = []
    @Published private(set) var jellyfinSources: [JellyfinSource] = []
    @Published private(set) var embySources: [EmbySource] = []
    @Published private(set) var plexSources: [PlexSource] = []
    @Published private(set) var cloudSources: [CloudSource] = []
    @Published private(set) var dlnaSources: [DLNASource] = []
    @Published private(set) var vlcNetworkSources: [VLCNetworkSource] = []
    @Published private(set) var collections: [MediaCollection] = []
    @Published private(set) var smartPlaylists: [SmartPlaylist] = []
    @Published private(set) var viewerProfiles: [ViewerProfile] = []
    @Published private(set) var activeProfileID: UUID?
    private var libraryConfigUpdatedAt: Date?
    private var lastNetworkConfiguration: NetworkSourceConfiguration?
    @Published private(set) var scanningFolders: Set<UUID> = []
    @Published private(set) var offlineFolders: Set<UUID> = []
    @Published private(set) var scanningSMBSources: Set<UUID> = []
    @Published private(set) var offlineSMBSources: Set<UUID> = []
    @Published private(set) var scanningWebDAVSources: Set<UUID> = []
    @Published private(set) var offlineWebDAVSources: Set<UUID> = []
    @Published private(set) var scanningJellyfinSources: Set<UUID> = []
    @Published private(set) var offlineJellyfinSources: Set<UUID> = []
    @Published private(set) var scanningEmbySources: Set<UUID> = []
    @Published private(set) var offlineEmbySources: Set<UUID> = []
    @Published private(set) var scanningPlexSources: Set<UUID> = []
    @Published private(set) var offlinePlexSources: Set<UUID> = []
    @Published private(set) var scanningCloudSources: Set<UUID> = []
    @Published private(set) var offlineCloudSources: Set<UUID> = []
    @Published private(set) var scanningDLNASources: Set<UUID> = []
    @Published private(set) var offlineDLNASources: Set<UUID> = []
    @Published private(set) var scanningVLCNetworkSources: Set<UUID> = []
    @Published private(set) var offlineVLCNetworkSources: Set<UUID> = []
    @Published private(set) var downloading: Set<UUID> = []
    @Published private(set) var downloadProgress: [UUID: Double] = [:]
    @Published private(set) var enrichingMetadata = false
    @Published private(set) var syncing = false
    @Published private(set) var syncStatus: String?
    @Published private(set) var traktSyncing = false
    @Published private(set) var traktStatus: String?
    @Published var iCloudSyncEnabled = UserDefaults.standard.bool(forKey: "lucent.iCloudSyncEnabled") {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: "lucent.iCloudSyncEnabled")
            scheduleSync()
        }
    }
    @Published var errorMessage: String?
    @Published var diagnosticMessage: String?

    private let fileURL: URL
    private var database: LibraryDatabase?
    private var syncTask: Task<Void, Never>?
    private var traktTask: Task<Void, Never>?
    private var cloudRefreshTasks: [UUID: Task<String, Error>] = [:]
    private var syncRequestedDuringRun = false
    private var lastServerReport: [UUID: Date] = [:]
    private var downloadOperations: [UUID: HTTPDownloader] = [:]
    private var smbDownloadOperations: [UUID: Task<Void, Error>] = [:]
    private var cancelledDownloads: Set<UUID> = []
    private var pausedSMBDownloads: Set<UUID> = []
    private var restoredInterruptedDownloads = false
    private var userPausedDownloadIDs: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "lucent.userPausedDownloads") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "lucent.userPausedDownloads") }
    }
    private var pendingTraktUnwatched: Set<TraktClient.Watched> {
        get {
            guard let data = UserDefaults.standard.data(forKey: "lucent.trakt.pendingUnwatched") else { return [] }
            return (try? JSONDecoder().decode(Set<TraktClient.Watched>.self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue),
                                      forKey: "lucent.trakt.pendingUnwatched")
        }
    }
    private var pendingTraktUnrated: Set<TraktClient.Watched> {
        get {
            guard let data = UserDefaults.standard.data(forKey: "lucent.trakt.pendingUnrated") else { return [] }
            return (try? JSONDecoder().decode(Set<TraktClient.Watched>.self, from: data)) ?? []
        }
        set {
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue),
                                      forKey: "lucent.trakt.pendingUnrated")
        }
    }

    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lucent", isDirectory: true)
        fileURL = directory.appendingPathComponent("library.json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let sqlite = try LibraryDatabase(url: directory.appendingPathComponent("library.sqlite"))
            database = sqlite
            let stored = try sqlite.load()
            if sqlite.hasStoredConfiguration || !stored.items.isEmpty ||
                !FileManager.default.fileExists(atPath: fileURL.path) {
                applySnapshot(stored)
            } else {
                let data = try Data(contentsOf: fileURL)
                if let snapshot = try? JSONDecoder().decode(LibrarySnapshot.self, from: data) {
                    applySnapshot(snapshot)
                } else {
                    items = try JSONDecoder().decode([MediaItem].self, from: data)
                }
                try sqlite.save(snapshot())
            }
            for index in items.indices where items[index].identity == nil {
                let filename: String
                switch items[index].location {
                case .remote(let url): filename = url.lastPathComponent
                case .folderFile(_, let relativePath): filename = URL(fileURLWithPath: relativePath).lastPathComponent
                case .smbFile(_, let relativePath): filename = URL(fileURLWithPath: relativePath).lastPathComponent
                case .webDAVFile(_, let relativePath): filename = URL(fileURLWithPath: relativePath).lastPathComponent
                case .jellyfinItem: filename = items[index].title
                case .embyItem: filename = items[index].title
                case .plexItem: filename = items[index].title
                case .cloudFile(_, _, let name): filename = name
                case .bookmark(let data):
                    #if os(tvOS)
                    filename = items[index].title
                    #else
                    filename = (try? Self.bookmarkedFilename(data)) ?? items[index].title
                    #endif
                }
                items[index].identity = MediaNameParser.parse(filename: filename).identity
            }
        } catch {
            errorMessage = "无法读取媒体库：\(error.localizedDescription)"
        }
        if viewerProfiles.isEmpty {
            var initial = ViewerProfile(name: "默认", isChild: false)
            initial.playbackStates = Dictionary(uniqueKeysWithValues: items.map {
                ($0.id, ProfilePlaybackState(item: $0))
            })
            viewerProfiles = [initial]
            activeProfileID = initial.id
        } else if !viewerProfiles.contains(where: { $0.id == activeProfileID }) {
            activeProfileID = viewerProfiles.first?.id
        }
        lastNetworkConfiguration = networkConfiguration()
    }

    private func applySnapshot(_ snapshot: LibrarySnapshot) {
        items = snapshot.items
        folders = snapshot.folders
        smbSources = snapshot.smbSources ?? []
        webDAVSources = snapshot.webDAVSources ?? []
        jellyfinSources = snapshot.jellyfinSources ?? []
        embySources = snapshot.embySources ?? []
        plexSources = snapshot.plexSources ?? []
        cloudSources = snapshot.cloudSources ?? []
        dlnaSources = snapshot.dlnaSources ?? []
        vlcNetworkSources = snapshot.vlcNetworkSources ?? []
        collections = snapshot.collections ?? []
        smartPlaylists = snapshot.smartPlaylists ?? []
        libraryConfigUpdatedAt = snapshot.libraryConfigUpdatedAt
        viewerProfiles = snapshot.viewerProfiles ?? []
        activeProfileID = snapshot.activeProfileID
    }

    private func snapshot() -> LibrarySnapshot {
        var profiles = viewerProfiles
        if let index = profiles.firstIndex(where: { $0.id == activeProfileID }) {
            for item in items { profiles[index].playbackStates[item.id] = ProfilePlaybackState(item: item) }
        }
        return LibrarySnapshot(items: items, folders: folders, smbSources: smbSources,
                        webDAVSources: webDAVSources, jellyfinSources: jellyfinSources,
                        embySources: embySources,
                        plexSources: plexSources, cloudSources: cloudSources, dlnaSources: dlnaSources,
                        vlcNetworkSources: vlcNetworkSources,
                        collections: collections,
                        smartPlaylists: smartPlaylists,
                        libraryConfigUpdatedAt: libraryConfigUpdatedAt,
                        viewerProfiles: profiles, activeProfileID: activeProfileID)
    }

    var activeProfile: ViewerProfile? { viewerProfiles.first { $0.id == activeProfileID } }
    private var isDefaultProfile: Bool { activeProfileID == viewerProfiles.first?.id }
    var visibleItems: [MediaItem] {
        guard let profile = activeProfile, profile.isChild else { return items }
        let blocked = Set(profile.blockedItemIDs)
        return items.filter { !blocked.contains($0.id) }
    }

    func addViewerProfile(name: String, isChild: Bool) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !viewerProfiles.contains(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) else { return }
        if isChild, (try? KeychainPasswordStore.profilePIN()) == nil {
            errorMessage = "请先设置家长 PIN。"
            return
        }
        viewerProfiles.append(ViewerProfile(name: trimmed, isChild: isChild))
        save()
    }

    func configureProfilePIN(_ pin: String) -> Bool {
        guard activeProfile?.isChild == false,
              pin.range(of: "^[0-9]{4,8}$", options: .regularExpression) != nil else {
            errorMessage = "家长 PIN 需要 4–8 位数字。"
            return false
        }
        do {
            try KeychainPasswordStore.setProfilePIN(pin)
            return true
        } catch {
            errorMessage = "无法保存家长 PIN：\(error.localizedDescription)"
            return false
        }
    }

    func removeViewerProfile(id: UUID) {
        guard activeProfile?.isChild == false,
              id != activeProfileID, id != viewerProfiles.first?.id else { return }
        viewerProfiles.removeAll { $0.id == id }
        save()
    }

    func switchViewerProfile(id: UUID, pin: String? = nil) -> Bool {
        guard let target = viewerProfiles.firstIndex(where: { $0.id == id }) else { return false }
        if activeProfile?.isChild == true && !viewerProfiles[target].isChild {
            guard let expected = try? KeychainPasswordStore.profilePIN(),
                  !expected.isEmpty, expected == pin else {
                errorMessage = "请输入家长 PIN 以切换到成人资料。"
                return false
            }
        }
        if let active = viewerProfiles.firstIndex(where: { $0.id == activeProfileID }) {
            for item in items { viewerProfiles[active].playbackStates[item.id] = ProfilePlaybackState(item: item) }
        }
        activeProfileID = id
        for index in items.indices {
            if let state = viewerProfiles[target].playbackStates[items[index].id] {
                items[index].position = state.position
                items[index].watched = state.watched
                items[index].favorite = state.favorite
                items[index].lastPlayedAt = state.lastPlayedAt
                items[index].stateUpdatedAt = state.stateUpdatedAt
            } else {
                items[index].position = 0
                items[index].watched = false
                items[index].favorite = false
                items[index].lastPlayedAt = nil
                items[index].stateUpdatedAt = nil
            }
        }
        save()
        return true
    }

    func setChildVisibility(profileID: UUID, itemID: UUID, visible: Bool) {
        guard activeProfile?.isChild == false,
              let index = viewerProfiles.firstIndex(where: { $0.id == profileID && $0.isChild }) else { return }
        viewerProfiles[index].blockedItemIDs.removeAll { $0 == itemID }
        if !visible { viewerProfiles[index].blockedItemIDs.append(itemID) }
        save()
    }

    func addRemote(_ rawAddress: String) -> Bool {
        let address = rawAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), let scheme = url.scheme?.lowercased(),
              ["http", "https", "ftp", "ftps", "sftp", "nfs"].contains(scheme),
              let host = url.host, url.user == nil, url.password == nil else {
            errorMessage = "请输入有效的视频地址。"
            return false
        }
        guard ["https", "sftp", "ftps"].contains(scheme) || Self.isLocalHost(host) else {
            errorMessage = "未加密连接仅支持局域网地址。"
            return false
        }
        guard !items.contains(where: { $0.location == .remote(url) }) else {
            errorMessage = "这个地址已在媒体库中。"
            return false
        }
        let name = url.lastPathComponent.removingPercentEncoding ?? "网络视频"
        let parsed = MediaNameParser.parse(filename: name.isEmpty ? "网络视频" : name)
        items.insert(MediaItem(title: parsed.title, location: .remote(url), identity: parsed.identity), at: 0)
        save()
        return true
    }

    func importDLNAVideos(_ videos: [DLNAClient.Video]) -> Int {
        guard isDefaultProfile else { return 0 }
        var known = Set(items.compactMap { item -> URL? in
            if case .remote(let url) = item.location { return url }
            return nil
        })
        var added = 0
        for video in videos {
            guard let scheme = video.url.scheme?.lowercased(), let host = video.url.host,
                  scheme == "https" || (scheme == "http" && Self.isLocalHost(host)),
                  known.insert(video.url).inserted else { continue }
            let parsed = MediaNameParser.parse(filename: video.url.lastPathComponent)
            let title = video.title.trimmingCharacters(in: .whitespacesAndNewlines)
            items.insert(MediaItem(title: title.isEmpty ? parsed.title : title,
                                   location: .remote(video.url), identity: parsed.identity), at: 0)
            added += 1
        }
        if added > 0 { save(); scheduleMetadataEnrichment() }
        return added
    }

    func addDLNA(device: DLNAClient.Device, videos: [DLNAClient.Video]) -> Int {
        guard isDefaultProfile else { return 0 }
        let source: DLNASource
        if let existing = dlnaSources.first(where: { $0.descriptionAddress == device.descriptionURL.absoluteString }) {
            source = existing
        } else {
            source = DLNASource(name: device.name, descriptionURL: device.descriptionURL)
            dlnaSources.append(source)
        }
        return reconcileDLNA(id: source.id, videos: videos)
    }

    func scanDLNA(id: UUID) {
        guard isDefaultProfile, let source = dlnaSources.first(where: { $0.id == id }),
              let url = URL(string: source.descriptionAddress),
              !scanningDLNASources.contains(id) else { return }
        scanningDLNASources.insert(id)
        Task {
            defer { scanningDLNASources.remove(id) }
            do {
                let device = try await DLNAClient.connect(descriptionURL: url)
                let videos = try await DLNAClient.scan(device: device)
                guard dlnaSources.contains(where: { $0.id == id }) else { return }
                _ = reconcileDLNA(id: id, videos: videos)
                offlineDLNASources.remove(id)
            } catch {
                offlineDLNASources.insert(id)
                errorMessage = "DLNA 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func removeDLNA(id: UUID) {
        guard let source = dlnaSources.first(where: { $0.id == id }) else { return }
        let owned = Set(source.mediaIDs)
        dlnaSources.removeAll { $0.id == id }
        offlineDLNASources.remove(id)
        removeItemsAndAssets { owned.contains($0.id) }
        save()
    }

    private func reconcileDLNA(id: UUID, videos: [DLNAClient.Video]) -> Int {
        guard let sourceIndex = dlnaSources.firstIndex(where: { $0.id == id }) else { return 0 }
        var owned = Set(dlnaSources[sourceIndex].mediaIDs)
        var found = Set<UUID>()
        var added = 0
        for video in videos {
            guard let scheme = video.url.scheme?.lowercased(), let host = video.url.host,
                  scheme == "https" || (scheme == "http" && Self.isLocalHost(host)) else { continue }
            if let index = items.firstIndex(where: { $0.location == .remote(video.url) }) {
                if owned.contains(items[index].id) {
                    found.insert(items[index].id)
                    items[index].missingSince = nil
                }
                continue
            }
            let parsed = MediaNameParser.parse(filename: video.url.lastPathComponent)
            let title = video.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let item = MediaItem(title: title.isEmpty ? parsed.title : title,
                                 location: .remote(video.url), identity: parsed.identity)
            items.insert(item, at: 0)
            owned.insert(item.id)
            found.insert(item.id)
            added += 1
        }
        for index in items.indices where owned.contains(items[index].id) && !found.contains(items[index].id) {
            if items[index].missingSince == nil { items[index].missingSince = Date() }
        }
        dlnaSources[sourceIndex].mediaIDs = Array(owned)
        dlnaSources[sourceIndex].lastScannedAt = Date()
        save()
        if added > 0 { scheduleMetadataEnrichment() }
        return added
    }

    func importNetworkVideos(_ videos: [VLCNetworkBrowser.Video]) -> Int {
        guard isDefaultProfile else { return 0 }
        var known = Set(items.compactMap { item -> URL? in
            if case .remote(let url) = item.location { return url }
            return nil
        })
        var added = 0
        for video in videos {
            guard let scheme = video.url.scheme?.lowercased(), let host = video.url.host,
                  ["sftp", "ftps"].contains(scheme) || Self.isLocalHost(host),
                  known.insert(video.url).inserted else { continue }
            let parsed = MediaNameParser.parse(filename: video.url.lastPathComponent)
            items.insert(MediaItem(title: video.title.isEmpty ? parsed.title : video.title,
                                   location: .remote(video.url), identity: parsed.identity), at: 0)
            added += 1
        }
        if added > 0 { save(); scheduleMetadataEnrichment() }
        return added
    }

    func addVLCNetworkSource(root: URL, username: String, password: String,
                             videos: [VLCNetworkBrowser.Video]) -> Int {
        guard isDefaultProfile else { return 0 }
        let source: VLCNetworkSource
        if let existing = vlcNetworkSources.first(where: { $0.rootAddress == root.absoluteString }) {
            source = existing
        } else {
            source = VLCNetworkSource(root: root, username: username)
        }
        do { try KeychainPasswordStore.setVLCNetworkPassword(password, for: source.id) }
        catch { errorMessage = "无法保存网络片源凭据：\(error.localizedDescription)"; return 0 }
        if !vlcNetworkSources.contains(where: { $0.id == source.id }) { vlcNetworkSources.append(source) }
        if let index = vlcNetworkSources.firstIndex(where: { $0.id == source.id }) {
            vlcNetworkSources[index].username = username
        }
        return reconcileVLCNetwork(id: source.id, videos: videos)
    }

    func scanVLCNetwork(id: UUID) {
        guard isDefaultProfile, let source = vlcNetworkSources.first(where: { $0.id == id }),
              let root = URL(string: source.rootAddress),
              !scanningVLCNetworkSources.contains(id) else { return }
        scanningVLCNetworkSources.insert(id)
        Task {
            defer { scanningVLCNetworkSources.remove(id) }
            do {
                let password = try KeychainPasswordStore.vlcNetworkPassword(for: id)
                let videos = try await VLCNetworkBrowser.browse(root: root,
                                                                 username: source.username,
                                                                 password: password)
                guard vlcNetworkSources.contains(where: { $0.id == id }) else { return }
                _ = reconcileVLCNetwork(id: id, videos: videos)
                offlineVLCNetworkSources.remove(id)
            } catch {
                offlineVLCNetworkSources.insert(id)
                errorMessage = "网络目录扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func removeVLCNetwork(id: UUID) {
        guard let source = vlcNetworkSources.first(where: { $0.id == id }) else { return }
        let owned = Set(source.mediaIDs)
        vlcNetworkSources.removeAll { $0.id == id }
        offlineVLCNetworkSources.remove(id)
        KeychainPasswordStore.removeVLCNetworkPassword(for: id)
        removeItemsAndAssets { owned.contains($0.id) }
        save()
    }

    func updateVLCNetworkCredentials(id: UUID, username: String, password: String) {
        guard let index = vlcNetworkSources.firstIndex(where: { $0.id == id }) else { return }
        do {
            try KeychainPasswordStore.setVLCNetworkPassword(password, for: id)
            vlcNetworkSources[index].username = username
            offlineVLCNetworkSources.remove(id)
            save()
            scanVLCNetwork(id: id)
        } catch {
            errorMessage = "无法更新网络片源凭据：\(error.localizedDescription)"
        }
    }

    private func reconcileVLCNetwork(id: UUID, videos: [VLCNetworkBrowser.Video]) -> Int {
        guard let sourceIndex = vlcNetworkSources.firstIndex(where: { $0.id == id }) else { return 0 }
        var owned = Set(vlcNetworkSources[sourceIndex].mediaIDs)
        var found = Set<UUID>()
        var added = 0
        for video in videos {
            guard let scheme = video.url.scheme?.lowercased(), let host = video.url.host,
                  ["sftp", "ftps"].contains(scheme) || Self.isLocalHost(host) else { continue }
            if let index = items.firstIndex(where: { $0.location == .remote(video.url) }) {
                if owned.contains(items[index].id) {
                    found.insert(items[index].id)
                    items[index].missingSince = nil
                }
                continue
            }
            let parsed = MediaNameParser.parse(filename: video.url.lastPathComponent)
            let item = MediaItem(title: video.title.isEmpty ? parsed.title : video.title,
                                 location: .remote(video.url), identity: parsed.identity)
            items.insert(item, at: 0)
            owned.insert(item.id)
            found.insert(item.id)
            added += 1
        }
        for index in items.indices where owned.contains(items[index].id) && !found.contains(items[index].id) {
            if items[index].missingSince == nil { items[index].missingSince = Date() }
        }
        vlcNetworkSources[sourceIndex].mediaIDs = Array(owned)
        vlcNetworkSources[sourceIndex].lastScannedAt = Date()
        save()
        if added > 0 { scheduleMetadataEnrichment() }
        return added
    }

    #if !os(tvOS)
    func addFile(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "无法读取所选文件，请重新选择。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            #if os(macOS)
            let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
            #else
            let data = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            #endif
            let normalizedPath = url.standardizedFileURL.path
            guard !items.contains(where: {
                guard case .bookmark(let existing) = $0.location else { return false }
                var stale = false
                #if os(macOS)
                let resolved = try? URL(resolvingBookmarkData: existing, options: .withSecurityScope,
                                        relativeTo: nil, bookmarkDataIsStale: &stale)
                #else
                let resolved = try? URL(resolvingBookmarkData: existing, options: [],
                                        relativeTo: nil, bookmarkDataIsStale: &stale)
                #endif
                return resolved?.standardizedFileURL.path == normalizedPath
            }) else { return }
            let parsed = MediaNameParser.parse(filename: url.lastPathComponent)
            items.insert(MediaItem(title: parsed.title, location: .bookmark(data), identity: parsed.identity), at: 0)
            save()
        } catch {
            errorMessage = "无法保存文件访问权限：\(error.localizedDescription)"
        }
    }

    func addUploadedFile(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard !items.contains(where: {
            guard case .bookmark(let data) = $0.location else { return false }
            var stale = false
            let existing = try? URL(resolvingBookmarkData: data, options: [],
                                    relativeTo: nil, bookmarkDataIsStale: &stale)
            return existing?.standardizedFileURL == url.standardizedFileURL
        }) else { return }
        do {
            let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let parsed = MediaNameParser.parse(filename: url.lastPathComponent)
            items.insert(MediaItem(title: parsed.title, location: .bookmark(bookmark), identity: parsed.identity), at: 0)
            save()
            scheduleMetadataEnrichment()
        } catch {
            errorMessage = "无法导入上传文件：\(error.localizedDescription)"
        }
    }

    var uploadDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Uploads", isDirectory: true)
    }

    func addFolder(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "无法读取所选文件夹，请重新选择。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            let bookmark = try makeBookmark(for: url)
            let path = url.standardizedFileURL.path
            guard !folders.contains(where: { source in
                guard let existing = try? resolveBookmark(source.bookmark) else { return false }
                return existing.standardizedFileURL.path == path
            }) else { return }
            let source = FolderSource(name: url.lastPathComponent, bookmark: bookmark)
            folders.append(source)
            save()
            scanFolder(id: source.id)
        } catch {
            errorMessage = "无法保存文件夹访问权限：\(error.localizedDescription)"
        }
    }

    func scanFolder(id: UUID) {
        guard let source = folders.first(where: { $0.id == id }), !scanningFolders.contains(id) else { return }
        scanningFolders.insert(id)
        Task {
            defer { scanningFolders.remove(id) }
            do {
                let bookmark = source.bookmark
                let paths = try await Task.detached(priority: .utility) {
                    try FolderScanner.scan(bookmark: bookmark)
                }.value
                guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
                reconcileFolder(id: id, paths: paths)
                folders[index].lastScannedAt = Date()
                offlineFolders.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlineFolders.insert(id)
                errorMessage = "扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func removeFolder(id: UUID) {
        folders.removeAll { $0.id == id }
        offlineFolders.remove(id)
        removeItemsAndAssets {
            if case .folderFile(let sourceID, _) = $0.location { return sourceID == id }
            return false
        }
        save()
    }

    private func makeBookmark(for url: URL) throws -> Data {
        #if os(macOS)
        return try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        #else
        return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        #endif
    }

    private func resolveBookmark(_ data: Data) throws -> URL {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        if stale { throw CocoaError(.fileReadNoPermission) }
        return url
    }

    private static func bookmarkedFilename(_ data: Data) throws -> String {
        var stale = false
        #if os(macOS)
        let url = try URL(resolvingBookmarkData: data, options: .withSecurityScope,
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let url = try URL(resolvingBookmarkData: data, options: [],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        return url.lastPathComponent
    }
    #endif

    func refreshFolders() {
        guard isDefaultProfile else { return }
        #if !os(tvOS)
        for source in folders { scanFolder(id: source.id) }
        #endif
        for source in smbSources { scanSMB(id: source.id) }
        for source in webDAVSources { scanWebDAV(id: source.id) }
        for source in jellyfinSources { scanJellyfin(id: source.id) }
        for source in embySources { scanEmby(id: source.id) }
        for source in plexSources { scanPlex(id: source.id) }
        for source in cloudSources { scanCloud(id: source.id) }
        for source in dlnaSources { scanDLNA(id: source.id) }
        for source in vlcNetworkSources { scanVLCNetwork(id: source.id) }
    }

    func addSMB(host: String, share: String, username: String, password: String) -> Bool {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let share = share.trimmingCharacters(in: .whitespacesAndNewlines)
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, !share.isEmpty,
              !host.contains("/"), !host.contains("@"), !host.contains(" "),
              !share.contains("/"), share != ".", share != ".." else {
            errorMessage = "请输入有效的服务器地址和共享名称。"
            return false
        }
        guard !smbSources.contains(where: {
            $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            $0.share.caseInsensitiveCompare(share) == .orderedSame && $0.username == username
        }) else {
            errorMessage = "这个 SMB 片源已添加。"
            return false
        }
        let source = SMBSource(host: host, share: share, username: username)
        do {
            try KeychainPasswordStore.set(password, for: source.id)
            smbSources.append(source)
            save()
            scanSMB(id: source.id)
            return true
        } catch {
            errorMessage = "无法保存 SMB 凭据：\(error.localizedDescription)"
            return false
        }
    }

    func scanSMB(id: UUID) {
        guard let source = smbSources.first(where: { $0.id == id }),
              !scanningSMBSources.contains(id) else { return }
        let password: String?
        do { password = try KeychainPasswordStore.get(for: id) }
        catch {
            errorMessage = "无法读取 SMB 凭据：\(error.localizedDescription)"
            return
        }
        scanningSMBSources.insert(id)
        Task {
            defer { scanningSMBSources.remove(id) }
            do {
                let paths = try await Task.detached(priority: .utility) {
                    try SMBScanner.scan(source: source, password: password)
                }.value
                guard let index = smbSources.firstIndex(where: { $0.id == id }) else { return }
                reconcileSMB(id: id, paths: paths)
                smbSources[index].lastScannedAt = Date()
                offlineSMBSources.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlineSMBSources.insert(id)
                errorMessage = "SMB 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func updateSMBCredentials(id: UUID, username: String, password: String?) -> Bool {
        guard let index = smbSources.firstIndex(where: { $0.id == id }) else { return false }
        do {
            if let password { try KeychainPasswordStore.set(password, for: id) }
            smbSources[index].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            offlineSMBSources.remove(id)
            save()
            scanSMB(id: id)
            return true
        } catch {
            errorMessage = "无法更新 SMB 凭据：\(error.localizedDescription)"
            return false
        }
    }

    func removeSMB(id: UUID) {
        smbSources.removeAll { $0.id == id }
        scanningSMBSources.remove(id)
        offlineSMBSources.remove(id)
        removeItemsAndAssets {
            if case .smbFile(let sourceID, _) = $0.location { return sourceID == id }
            return false
        }
        KeychainPasswordStore.remove(for: id)
        save()
    }

    func addWebDAV(address: String, username: String, password: String) -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host) else {
            errorMessage = "请输入有效的 WebDAV 地址；公网地址需要 HTTPS。"
            return false
        }
        let normalized = raw.hasSuffix("/") ? raw : raw + "/"
        guard !webDAVSources.contains(where: { $0.baseAddress == normalized && $0.username == username }) else {
            errorMessage = "这个 WebDAV 片源已添加。"
            return false
        }
        let source = WebDAVSource(baseAddress: normalized, username: username)
        do {
            try KeychainPasswordStore.setWebDAVPassword(password, for: source.id)
            webDAVSources.append(source)
            save()
            scanWebDAV(id: source.id)
            return true
        } catch {
            errorMessage = "无法保存 WebDAV 凭据：\(error.localizedDescription)"
            return false
        }
    }

    func scanWebDAV(id: UUID) {
        guard let source = webDAVSources.first(where: { $0.id == id }),
              !scanningWebDAVSources.contains(id) else { return }
        let password: String?
        do { password = try KeychainPasswordStore.webDAVPassword(for: id) }
        catch { errorMessage = "无法读取 WebDAV 凭据：\(error.localizedDescription)"; return }
        scanningWebDAVSources.insert(id)
        Task {
            defer { scanningWebDAVSources.remove(id) }
            do {
                let paths = try await WebDAVClient.scan(source: source, password: password)
                guard let index = webDAVSources.firstIndex(where: { $0.id == id }) else { return }
                reconcile(paths: paths, existingPath: { item in
                    if case .webDAVFile(let sourceID, let path) = item.location, sourceID == id { return path }
                    return nil
                }, location: { .webDAVFile(sourceID: id, relativePath: $0) })
                webDAVSources[index].lastScannedAt = Date()
                offlineWebDAVSources.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlineWebDAVSources.insert(id)
                errorMessage = "WebDAV 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func updateWebDAVCredentials(id: UUID, username: String, password: String?) -> Bool {
        guard let index = webDAVSources.firstIndex(where: { $0.id == id }) else { return false }
        do {
            if let password { try KeychainPasswordStore.setWebDAVPassword(password, for: id) }
            webDAVSources[index].username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            offlineWebDAVSources.remove(id)
            save()
            scanWebDAV(id: id)
            return true
        } catch {
            errorMessage = "无法更新 WebDAV 凭据：\(error.localizedDescription)"
            return false
        }
    }

    func removeWebDAV(id: UUID) {
        webDAVSources.removeAll { $0.id == id }
        offlineWebDAVSources.remove(id)
        removeItemsAndAssets {
            if case .webDAVFile(let sourceID, _) = $0.location { return sourceID == id }
            return false
        }
        KeychainPasswordStore.removeWebDAVPassword(for: id)
        save()
    }

    func addJellyfin(address: String, token: String) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host), !token.isEmpty else {
            errorMessage = "请输入有效的 Jellyfin 地址和访问令牌。"
            return false
        }
        let normalized = raw.hasSuffix("/") ? raw : raw + "/"
        guard !jellyfinSources.contains(where: { $0.baseAddress == normalized }) else {
            errorMessage = "这个 Jellyfin 服务器已添加。"
            return false
        }
        do {
            let userID = try await JellyfinClient.currentUserID(baseAddress: normalized, token: token)
            let source = JellyfinSource(baseAddress: normalized, userID: userID)
            try KeychainPasswordStore.setJellyfinToken(token, for: source.id)
            jellyfinSources.append(source)
            save()
            scanJellyfin(id: source.id)
            return true
        } catch {
            errorMessage = "连接 Jellyfin 失败：\(error.localizedDescription)"
            return false
        }
    }

    func addJellyfin(address: String, username: String, password: String) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入有效的 Jellyfin 地址与用户名。"
            return false
        }
        let normalized = raw.hasSuffix("/") ? raw : raw + "/"
        guard !jellyfinSources.contains(where: { $0.baseAddress == normalized }) else {
            errorMessage = "这个 Jellyfin 服务器已添加。"
            return false
        }
        do {
            let token = try await JellyfinClient.authenticate(baseAddress: raw, username: username,
                                                                password: password)
            return await addJellyfin(address: raw, token: token)
        } catch {
            errorMessage = "Jellyfin 登录失败：\(error.localizedDescription)"
            return false
        }
    }

    func scanJellyfin(id: UUID) {
        guard let source = jellyfinSources.first(where: { $0.id == id }),
              !scanningJellyfinSources.contains(id) else { return }
        let token: String
        do { token = try KeychainPasswordStore.jellyfinToken(for: id) ?? "" }
        catch { errorMessage = "无法读取 Jellyfin 令牌：\(error.localizedDescription)"; return }
        guard !token.isEmpty else { errorMessage = "Jellyfin 令牌已丢失，请重新添加服务器。"; return }
        scanningJellyfinSources.insert(id)
        Task {
            defer { scanningJellyfinSources.remove(id) }
            do {
                let remoteItems = try await JellyfinClient.scan(source: source, token: token)
                guard let index = jellyfinSources.firstIndex(where: { $0.id == id }) else { return }
                let remoteIDs = Set(remoteItems.map(\.id))
                for remote in remoteItems {
                    if let itemIndex = items.firstIndex(where: {
                        if case .jellyfinItem(let sourceID, let itemID) = $0.location {
                            return sourceID == id && itemID == remote.id
                        }
                        return false
                    }) {
                        items[itemIndex].missingSince = nil
                        if items[itemIndex].metadata == nil { items[itemIndex].title = remote.name }
                        items[itemIndex].serverSummary = remote.overview
                        if items[itemIndex].serverPosterKey != remote.imageTags?.primary,
                           items[itemIndex].metadata == nil { clearPoster(index: itemIndex) }
                        items[itemIndex].serverPosterKey = remote.imageTags?.primary
                        items[itemIndex].duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
                        items[itemIndex].serverFileExtension = remote.fileExtension
                        if (remote.remoteStateDate ?? .distantPast) > (items[itemIndex].stateUpdatedAt ?? .distantPast) ||
                            items[itemIndex].stateUpdatedAt == nil {
                            items[itemIndex].position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
                            items[itemIndex].watched = remote.userData?.played ?? false
                            items[itemIndex].favorite = remote.userData?.isFavorite ?? false
                            items[itemIndex].stateUpdatedAt = remote.remoteStateDate ?? Date()
                        }
                    } else {
                        var item = MediaItem(title: remote.name,
                                             location: .jellyfinItem(sourceID: id, itemID: remote.id),
                                             identity: remote.identity)
                        item.duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
                        item.position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
                        item.watched = remote.userData?.played ?? false
                        item.favorite = remote.userData?.isFavorite ?? false
                        item.stateUpdatedAt = remote.remoteStateDate ?? Date()
                        item.serverSummary = remote.overview
                        item.serverPosterKey = remote.imageTags?.primary
                        item.serverFileExtension = remote.fileExtension
                        items.insert(item, at: 0)
                    }
                }
                for itemIndex in items.indices {
                    if case .jellyfinItem(let sourceID, let itemID) = items[itemIndex].location,
                       sourceID == id, !remoteIDs.contains(itemID) {
                        items[itemIndex].missingSince = items[itemIndex].missingSince ?? Date()
                    }
                }
                jellyfinSources[index].lastScannedAt = Date()
                offlineJellyfinSources.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlineJellyfinSources.insert(id)
                errorMessage = "Jellyfin 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func removeJellyfin(id: UUID) {
        jellyfinSources.removeAll { $0.id == id }
        offlineJellyfinSources.remove(id)
        removeItemsAndAssets {
            if case .jellyfinItem(let sourceID, _) = $0.location { return sourceID == id }
            return false
        }
        KeychainPasswordStore.removeJellyfinToken(for: id)
        save()
    }

    func updateJellyfinToken(id: UUID, token: String) async -> Bool {
        guard let index = jellyfinSources.firstIndex(where: { $0.id == id }), !token.isEmpty else { return false }
        do {
            let userID = try await JellyfinClient.currentUserID(baseAddress: jellyfinSources[index].baseAddress,
                                                                 token: token)
            try KeychainPasswordStore.setJellyfinToken(token, for: id)
            jellyfinSources[index].userID = userID
            offlineJellyfinSources.remove(id)
            save()
            scanJellyfin(id: id)
            return true
        } catch {
            errorMessage = "无法更新 Jellyfin 令牌：\(error.localizedDescription)"
            return false
        }
    }

    func addEmby(address: String, token: String, userID: String) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host),
              !token.isEmpty, !userID.isEmpty else {
            errorMessage = "请输入有效的 Emby 地址、访问令牌和用户 ID。"
            return false
        }
        let normalized = Self.embyAPIAddress(raw)
        guard !embySources.contains(where: { $0.baseAddress == normalized }) else {
            errorMessage = "这个 Emby 服务器已添加。"
            return false
        }
        do {
            try await EmbyClient.validateUser(baseAddress: normalized, token: token, userID: userID)
            let source = EmbySource(baseAddress: normalized, userID: userID)
            try KeychainPasswordStore.setEmbyToken(token, for: source.id)
            embySources.append(source)
            save()
            scanEmby(id: source.id)
            return true
        } catch {
            errorMessage = "连接 Emby 失败：\(error.localizedDescription)"
            return false
        }
    }

    func addEmby(address: String, username: String, password: String) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入有效的 Emby 地址与用户名。"
            return false
        }
        let normalized = Self.embyAPIAddress(raw)
        guard !embySources.contains(where: { $0.baseAddress == normalized }) else {
            errorMessage = "这个 Emby 服务器已添加。"
            return false
        }
        do {
            let login = try await EmbyClient.authenticate(baseAddress: normalized, username: username,
                                                           password: password)
            return await addEmby(address: raw, token: login.token, userID: login.userID)
        } catch {
            errorMessage = "Emby 登录失败：\(error.localizedDescription)"
            return false
        }
    }

    func scanEmby(id: UUID) {
        guard let source = embySources.first(where: { $0.id == id }),
              !scanningEmbySources.contains(id) else { return }
        let token: String
        do { token = try KeychainPasswordStore.embyToken(for: id) ?? "" }
        catch { errorMessage = "无法读取 Emby 令牌：\(error.localizedDescription)"; return }
        guard !token.isEmpty else { errorMessage = "Emby 令牌已丢失，请重新添加服务器。"; return }
        scanningEmbySources.insert(id)
        Task {
            defer { scanningEmbySources.remove(id) }
            do {
                let remoteItems = try await EmbyClient.scan(source: source, token: token)
                guard let index = embySources.firstIndex(where: { $0.id == id }) else { return }
                let remoteIDs = Set(remoteItems.map(\.id))
                var updatedItems = items
                var existingIndices: [String: Int] = [:]
                for itemIndex in updatedItems.indices {
                    if case .embyItem(let sourceID, let itemID) = updatedItems[itemIndex].location,
                       sourceID == id {
                        existingIndices[itemID] = itemIndex
                    }
                }
                var addedItems: [MediaItem] = []
                for remote in remoteItems {
                    if let itemIndex = existingIndices[remote.id] {
                        updatedItems[itemIndex].missingSince = nil
                        if updatedItems[itemIndex].metadata == nil { updatedItems[itemIndex].title = remote.name }
                        updatedItems[itemIndex].serverSummary = remote.overview
                        if updatedItems[itemIndex].serverPosterKey != remote.imageTags?.primary,
                           updatedItems[itemIndex].metadata == nil { clearPoster(index: itemIndex) }
                        updatedItems[itemIndex].serverPosterKey = remote.imageTags?.primary
                        updatedItems[itemIndex].duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
                        updatedItems[itemIndex].serverFileExtension = remote.fileExtension
                        if (remote.remoteStateDate ?? .distantPast) > (updatedItems[itemIndex].stateUpdatedAt ?? .distantPast) ||
                            updatedItems[itemIndex].stateUpdatedAt == nil {
                            updatedItems[itemIndex].position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
                            updatedItems[itemIndex].watched = remote.userData?.played ?? false
                            updatedItems[itemIndex].favorite = remote.userData?.isFavorite ?? false
                            updatedItems[itemIndex].stateUpdatedAt = remote.remoteStateDate ?? Date()
                        }
                    } else {
                        var item = MediaItem(title: remote.name,
                                             location: .embyItem(sourceID: id, itemID: remote.id),
                                             identity: remote.identity)
                        item.duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
                        item.position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
                        item.watched = remote.userData?.played ?? false
                        item.favorite = remote.userData?.isFavorite ?? false
                        item.stateUpdatedAt = remote.remoteStateDate ?? Date()
                        item.serverSummary = remote.overview
                        item.serverPosterKey = remote.imageTags?.primary
                        item.serverFileExtension = remote.fileExtension
                        addedItems.append(item)
                    }
                }
                for itemIndex in updatedItems.indices {
                    if case .embyItem(let sourceID, let itemID) = updatedItems[itemIndex].location,
                       sourceID == id, !remoteIDs.contains(itemID) {
                        updatedItems[itemIndex].missingSince = updatedItems[itemIndex].missingSince ?? Date()
                    }
                }
                items = Array(addedItems.reversed()) + updatedItems
                embySources[index].lastScannedAt = Date()
                offlineEmbySources.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlineEmbySources.insert(id)
                errorMessage = "Emby 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func removeEmby(id: UUID) {
        embySources.removeAll { $0.id == id }
        offlineEmbySources.remove(id)
        removeItemsAndAssets {
            if case .embyItem(let sourceID, _) = $0.location { return sourceID == id }
            return false
        }
        KeychainPasswordStore.removeEmbyToken(for: id)
        save()
    }

    func updateEmbyToken(id: UUID, token: String) async -> Bool {
        guard let index = embySources.firstIndex(where: { $0.id == id }), !token.isEmpty else { return false }
        do {
            try await EmbyClient.validateUser(baseAddress: embySources[index].baseAddress,
                                              token: token, userID: embySources[index].userID)
            try KeychainPasswordStore.setEmbyToken(token, for: id)
            offlineEmbySources.remove(id)
            save()
            scanEmby(id: id)
            return true
        } catch {
            errorMessage = "无法更新 Emby 令牌：\(error.localizedDescription)"
            return false
        }
    }

    func addPlex(address: String, token: String) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host), !token.isEmpty else {
            errorMessage = "请输入有效的 Plex 地址和访问令牌。"
            return false
        }
        let normalized = raw.hasSuffix("/") ? raw : raw + "/"
        guard !plexSources.contains(where: { $0.baseAddress == normalized }) else {
            errorMessage = "这个 Plex 服务器已添加。"
            return false
        }
        do {
            try await PlexClient.validate(baseAddress: normalized, token: token)
            let source = PlexSource(baseAddress: normalized)
            try KeychainPasswordStore.setPlexToken(token, for: source.id)
            plexSources.append(source)
            save()
            scanPlex(id: source.id)
            return true
        } catch {
            errorMessage = "连接 Plex 失败：\(error.localizedDescription)"
            return false
        }
    }

    func scanPlex(id: UUID) {
        guard let source = plexSources.first(where: { $0.id == id }),
              !scanningPlexSources.contains(id) else { return }
        let token: String
        do { token = try KeychainPasswordStore.plexToken(for: id) ?? "" }
        catch { errorMessage = "无法读取 Plex 令牌：\(error.localizedDescription)"; return }
        guard !token.isEmpty else { errorMessage = "Plex 令牌已丢失，请重新添加服务器。"; return }
        scanningPlexSources.insert(id)
        Task {
            defer { scanningPlexSources.remove(id) }
            do {
                let remoteItems = try await PlexClient.scan(source: source, token: token)
                guard let index = plexSources.firstIndex(where: { $0.id == id }) else { return }
                let remoteIDs = Set(remoteItems.map(\.ratingKey))
                for remote in remoteItems {
                    guard let partKey = remote.partKey else { continue }
                    if let itemIndex = items.firstIndex(where: {
                        if case .plexItem(let sourceID, let key, _) = $0.location {
                            return sourceID == id && key == remote.ratingKey
                        }
                        return false
                    }) {
                        items[itemIndex].missingSince = nil
                        items[itemIndex].location = .plexItem(sourceID: id, ratingKey: remote.ratingKey,
                                                              partKey: partKey)
                        if items[itemIndex].metadata == nil { items[itemIndex].title = remote.title }
                        items[itemIndex].serverSummary = remote.summary
                        if items[itemIndex].serverPosterKey != remote.thumb,
                           items[itemIndex].metadata == nil { clearPoster(index: itemIndex) }
                        items[itemIndex].serverPosterKey = remote.thumb
                        items[itemIndex].duration = remote.duration.map { $0 / 1000 }
                        if (remote.lastViewedAt.map { Date(timeIntervalSince1970: $0) } ?? .distantPast) >
                            (items[itemIndex].stateUpdatedAt ?? .distantPast) || items[itemIndex].stateUpdatedAt == nil {
                            items[itemIndex].position = (remote.viewOffset ?? 0) / 1000
                            items[itemIndex].watched = (remote.viewCount ?? 0) > 0
                            items[itemIndex].stateUpdatedAt = remote.lastViewedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
                        }
                    } else {
                        var item = MediaItem(title: remote.title,
                                             location: .plexItem(sourceID: id, ratingKey: remote.ratingKey,
                                                                 partKey: partKey), identity: remote.identity)
                        item.duration = remote.duration.map { $0 / 1000 }
                        item.position = (remote.viewOffset ?? 0) / 1000
                        item.watched = (remote.viewCount ?? 0) > 0
                        item.stateUpdatedAt = remote.lastViewedAt.map { Date(timeIntervalSince1970: $0) } ?? Date()
                        item.serverSummary = remote.summary
                        item.serverPosterKey = remote.thumb
                        items.insert(item, at: 0)
                    }
                }
                for itemIndex in items.indices {
                    if case .plexItem(let sourceID, let key, _) = items[itemIndex].location,
                       sourceID == id, !remoteIDs.contains(key) {
                        items[itemIndex].missingSince = items[itemIndex].missingSince ?? Date()
                    }
                }
                plexSources[index].lastScannedAt = Date()
                offlinePlexSources.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlinePlexSources.insert(id)
                errorMessage = "Plex 扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func removePlex(id: UUID) {
        plexSources.removeAll { $0.id == id }
        offlinePlexSources.remove(id)
        removeItemsAndAssets {
            if case .plexItem(let sourceID, _, _) = $0.location { return sourceID == id }
            return false
        }
        KeychainPasswordStore.removePlexToken(for: id)
        save()
    }

    func updatePlexToken(id: UUID, token: String) async -> Bool {
        guard let source = plexSources.first(where: { $0.id == id }), !token.isEmpty else { return false }
        do {
            try await PlexClient.validate(baseAddress: source.baseAddress, token: token)
            try KeychainPasswordStore.setPlexToken(token, for: id)
            offlinePlexSources.remove(id)
            scanPlex(id: id)
            return true
        } catch {
            errorMessage = "无法更新 Plex 令牌：\(error.localizedDescription)"
            return false
        }
    }

    func addCloud(provider: CloudProvider, name: String, token: String,
                  clientID: String = "", refreshToken: String = "",
                  clientSecret: String = "") async -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !token.isEmpty || (!refreshToken.isEmpty &&
                                   (provider == .pan115 || provider == .guangyaPan || !clientID.isEmpty)) else {
            errorMessage = "请输入云盘名称，以及访问令牌或刷新令牌和应用 ID。"; return false
        }
        let source = CloudSource(provider: provider, name: trimmed,
                                 oauthClientID: clientID.isEmpty ? nil : clientID)
        do {
            let refreshed = !refreshToken.isEmpty
                ? try await CloudTokenRefresher.refresh(provider: provider, clientID: clientID,
                                                       refreshToken: refreshToken,
                                                       clientSecret: clientSecret) : nil
            let access = refreshed?.accessToken ?? token
            let entries = try await CloudDriveClient.scan(source: source, token: access)
            try KeychainPasswordStore.setCloudToken(access, for: source.id)
            if !clientSecret.isEmpty {
                try KeychainPasswordStore.setCloudClientSecret(clientSecret, for: source.id)
            }
            if !refreshToken.isEmpty {
                try KeychainPasswordStore.setCloudRefreshToken(refreshed?.refreshToken ?? refreshToken,
                                                               for: source.id)
                if let refreshed {
                    UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(refreshed.expiresIn - 60)),
                                              forKey: "lucent.cloud.expiry.\(source.id.uuidString)")
                }
            }
            cloudSources.append(source)
            reconcileCloud(id: source.id, entries: entries)
            if let index = cloudSources.firstIndex(where: { $0.id == source.id }) {
                cloudSources[index].lastScannedAt = Date()
            }
            save()
            scheduleMetadataEnrichment()
            return true
        } catch {
            errorMessage = "云盘连接失败：\(error.localizedDescription)"
            return false
        }
    }

    func scanCloud(id: UUID) {
        guard isDefaultProfile, let source = cloudSources.first(where: { $0.id == id }),
              !scanningCloudSources.contains(id) else { return }
        scanningCloudSources.insert(id)
        Task {
            defer { scanningCloudSources.remove(id) }
            do {
                let token = try await validCloudToken(source: source)
                let entries = try await CloudDriveClient.scan(source: source, token: token)
                guard let index = cloudSources.firstIndex(where: { $0.id == id }) else { return }
                reconcileCloud(id: id, entries: entries)
                cloudSources[index].lastScannedAt = Date()
                offlineCloudSources.remove(id)
                save()
                scheduleMetadataEnrichment()
            } catch {
                offlineCloudSources.insert(id)
                errorMessage = "云盘扫描失败：\(error.localizedDescription)"
            }
        }
    }

    func updateCloudToken(id: UUID, token: String) async -> Bool {
        guard let source = cloudSources.first(where: { $0.id == id }), !token.isEmpty else { return false }
        do {
            _ = try await CloudDriveClient.scan(source: source, token: token)
            try KeychainPasswordStore.setCloudToken(token, for: id)
            KeychainPasswordStore.removeCloudRefreshToken(for: id)
            UserDefaults.standard.removeObject(forKey: "lucent.cloud.expiry.\(id.uuidString)")
            offlineCloudSources.remove(id)
            scanCloud(id: id)
            return true
        } catch {
            errorMessage = "无法更新云盘令牌：\(error.localizedDescription)"
            return false
        }
    }

    func updateCloudAuthorization(id: UUID, clientID: String, refreshToken: String,
                                  clientSecret: String = "") async -> Bool {
        guard let index = cloudSources.firstIndex(where: { $0.id == id }),
              !refreshToken.isEmpty else { return false }
        do {
            let source = cloudSources[index]
            let secret = clientSecret.isEmpty
                ? try KeychainPasswordStore.cloudClientSecret(for: id) : clientSecret
            let token = try await CloudTokenRefresher.refresh(provider: source.provider,
                                                              clientID: clientID,
                                                              refreshToken: refreshToken,
                                                              clientSecret: secret)
            _ = try await CloudDriveClient.scan(source: source, token: token.accessToken)
            try KeychainPasswordStore.setCloudToken(token.accessToken, for: id)
            try KeychainPasswordStore.setCloudRefreshToken(token.refreshToken ?? refreshToken, for: id)
            if !clientSecret.isEmpty {
                try KeychainPasswordStore.setCloudClientSecret(clientSecret, for: id)
            }
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(token.expiresIn - 60)),
                                      forKey: "lucent.cloud.expiry.\(id.uuidString)")
            cloudSources[index].oauthClientID = clientID
            offlineCloudSources.remove(id)
            save()
            scanCloud(id: id)
            return true
        } catch {
            errorMessage = "无法更新云盘授权：\(error.localizedDescription)"
            return false
        }
    }

    func removeCloud(id: UUID) {
        cloudSources.removeAll { $0.id == id }
        offlineCloudSources.remove(id)
        removeItemsAndAssets {
            if case .cloudFile(let sourceID, _, _) = $0.location { return sourceID == id }
            return false
        }
        KeychainPasswordStore.removeCloudToken(for: id)
        KeychainPasswordStore.removeCloudRefreshToken(for: id)
        KeychainPasswordStore.removeCloudClientSecret(for: id)
        UserDefaults.standard.removeObject(forKey: "lucent.cloud.expiry.\(id.uuidString)")
        save()
    }

    func validCloudToken(source: CloudSource) async throws -> String {
        let expiry = UserDefaults.standard.object(forKey: "lucent.cloud.expiry.\(source.id.uuidString)") as? Date
        if let current = try KeychainPasswordStore.cloudToken(for: source.id),
           expiry.map({ $0 > Date() }) ?? true {
            return current
        }
        guard let refresh = try KeychainPasswordStore.cloudRefreshToken(for: source.id) else {
            throw CocoaError(.fileReadNoPermission)
        }
        let clientID = source.oauthClientID ?? ""
        if let task = cloudRefreshTasks[source.id] { return try await task.value }
        let task = Task<String, Error> {
            let token = try await CloudTokenRefresher.refresh(provider: source.provider,
                                                             clientID: clientID, refreshToken: refresh,
                                                             clientSecret: try KeychainPasswordStore.cloudClientSecret(for: source.id))
            try KeychainPasswordStore.setCloudToken(token.accessToken, for: source.id)
            if let rotated = token.refreshToken {
                try KeychainPasswordStore.setCloudRefreshToken(rotated, for: source.id)
            }
            UserDefaults.standard.set(Date().addingTimeInterval(TimeInterval(token.expiresIn - 60)),
                                      forKey: "lucent.cloud.expiry.\(source.id.uuidString)")
            return token.accessToken
        }
        cloudRefreshTasks[source.id] = task
        defer { cloudRefreshTasks[source.id] = nil }
        return try await task.value
    }

    private func reconcileCloud(id: UUID, entries: [CloudDriveClient.FileEntry]) {
        let found = Set(entries.map(\.identifier))
        let now = Date()
        for entry in entries {
            if let index = items.firstIndex(where: {
                if case .cloudFile(let sourceID, let identifier, _) = $0.location {
                    return sourceID == id && identifier == entry.identifier
                }
                return false
            }) {
                items[index].location = .cloudFile(sourceID: id, identifier: entry.identifier,
                                                   filename: entry.filename)
                items[index].missingSince = nil
            } else {
                let parsed = MediaNameParser.parse(filename: entry.filename)
                items.insert(MediaItem(title: parsed.title,
                                       location: .cloudFile(sourceID: id, identifier: entry.identifier,
                                                            filename: entry.filename),
                                       identity: parsed.identity), at: 0)
            }
        }
        for index in items.indices {
            if case .cloudFile(let sourceID, let identifier, _) = items[index].location,
               sourceID == id, !found.contains(identifier), items[index].missingSince == nil {
                items[index].missingSince = now
            }
        }
    }

    private func reconcileFolder(id: UUID, paths: [String]) {
        reconcile(paths: paths, existingPath: { item in
            if case .folderFile(let sourceID, let path) = item.location, sourceID == id { return path }
            return nil
        }, location: { .folderFile(sourceID: id, relativePath: $0) }, displayPath: { path in
            let name = URL(fileURLWithPath: path).lastPathComponent.uppercased()
            guard name == "VIDEO_TS" || name == "BDMV" else { return path }
            let parent = (path as NSString).deletingLastPathComponent
            return parent.isEmpty ? (self.folders.first(where: { $0.id == id })?.name ?? "光盘") : parent
        })
    }

    private func reconcileSMB(id: UUID, paths: [String]) {
        reconcile(paths: paths, existingPath: { item in
            if case .smbFile(let sourceID, let path) = item.location, sourceID == id { return path }
            return nil
        }, location: { .smbFile(sourceID: id, relativePath: $0) })
    }

    private func reconcile(paths: [String], existingPath: (MediaItem) -> String?,
                           location: (String) -> MediaLocation,
                           displayPath: (String) -> String = { $0 }) {
        let discovered = Set(paths)
        let old = items.compactMap { item -> (MediaItem, String)? in
            guard let path = existingPath(item) else { return nil }
            return (item, path)
        }
        let oldPaths = Set(old.map { $0.1 })
        let missing = old.filter { !discovered.contains($0.1) }
        let itemIndices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
        let missingByName = Dictionary(grouping: missing) {
            URL(fileURLWithPath: displayPath($0.1)).lastPathComponent.lowercased()
        }
        var movedIDs = Set<UUID>()
        var additions: [MediaItem] = []
        for (previous, path) in old where discovered.contains(path) {
            if let index = itemIndices[previous.id] { items[index].missingSince = nil }
        }
        for path in discovered.subtracting(oldPaths).sorted() {
            let filename = URL(fileURLWithPath: displayPath(path)).lastPathComponent
            let matches = missingByName[filename.lowercased()] ?? []
            if matches.count == 1, let previous = matches.first?.0,
               movedIDs.insert(previous.id).inserted {
                if let index = itemIndices[previous.id] {
                    items[index].location = location(path)
                    items[index].missingSince = nil
                }
            } else {
                let parsed = MediaNameParser.parse(relativePath: displayPath(path))
                additions.append(MediaItem(title: parsed.title, location: location(path), identity: parsed.identity))
            }
        }
        let missingIDs = Set(missing.map { $0.0.id }).subtracting(movedIDs)
        for id in missingIDs {
            if let index = itemIndices[id] { items[index].missingSince = items[index].missingSince ?? Date() }
        }
        items.insert(contentsOf: additions, at: 0)
    }

    func purgeMissingItems() {
        let removed = Set(items.filter { $0.missingSince != nil && downloadedURL(for: $0) == nil }.map(\.id))
        removeItemsAndAssets { removed.contains($0.id) }
        save()
    }

    private func removeItemsAndAssets(where shouldRemove: (MediaItem) -> Bool) {
        let removed = items.filter(shouldRemove)
        for item in removed {
            cancelDownload(id: item.id)
            if let url = downloadedURL(for: item) { try? FileManager.default.removeItem(at: url) }
            if let url = posterURL(for: item) { try? FileManager.default.removeItem(at: url) }
            if let url = subtitleURL(for: item) { try? FileManager.default.removeItem(at: url) }
        }
        let removedIDs = Set(removed.map(\.id))
        items.removeAll { removedIDs.contains($0.id) }
        for index in items.indices {
            items[index].extraItemIDs?.removeAll { removedIDs.contains($0) }
        }
        for index in collections.indices {
            collections[index].itemIDs.removeAll { removedIDs.contains($0) }
        }
        for index in viewerProfiles.indices {
            for id in removedIDs { viewerProfiles[index].playbackStates.removeValue(forKey: id) }
            viewerProfiles[index].blockedItemIDs.removeAll { removedIDs.contains($0) }
        }
    }

    func updateProgress(id: UUID, position: Double, duration: Double?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let safePosition = position.isFinite ? max(0, position) : 0
        let safeDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        items[index].position = safePosition
        if safePosition > 0 { items[index].lastPlayedAt = Date() }
        items[index].stateUpdatedAt = Date()
        if let safeDuration { items[index].duration = safeDuration }
        if let total = items[index].duration, total > 0, safePosition / total >= 0.95 {
            items[index].watched = true
        }
        if Date().timeIntervalSince(lastServerReport[id] ?? .distantPast) >= 10 {
            lastServerReport[id] = Date()
            reportServerProgress(item: items[index], stopped: false)
        }
        save()
    }

    func markUnwatched(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].position = 0
        items[index].watched = false
        items[index].stateUpdatedAt = Date()
        if isDefaultProfile, let key = Self.traktKey(for: items[index]) {
            pendingTraktUnwatched.insert(key)
        }
        if isDefaultProfile, case .jellyfinItem(let sourceID, let itemID) = items[index].location,
           let source = jellyfinSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID), !token.isEmpty {
            Task { try? await JellyfinClient.updateUserData(source: source, token: token,
                                                             itemID: itemID, position: 0, played: false) }
        }
        if isDefaultProfile, case .embyItem(let sourceID, let itemID) = items[index].location,
           let source = embySources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.embyToken(for: sourceID), !token.isEmpty {
            Task { try? await EmbyClient.updateUserData(source: source, token: token,
                                                        itemID: itemID, position: 0, played: false) }
        }
        if isDefaultProfile, case .plexItem(let sourceID, let ratingKey, _) = items[index].location,
           let source = plexSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.plexToken(for: sourceID), !token.isEmpty {
            Task { try? await PlexClient.markPlayed(source: source, token: token,
                                                    ratingKey: ratingKey, played: false) }
        }
        save()
        scheduleTraktSync()
    }

    func markWatched(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].watched = true
        items[index].stateUpdatedAt = Date()
        if let key = Self.traktKey(for: items[index]) {
            pendingTraktUnwatched.remove(key)
        }
        if isDefaultProfile, case .jellyfinItem(let sourceID, let itemID) = items[index].location,
           let source = jellyfinSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID), !token.isEmpty {
            Task { try? await JellyfinClient.updateUserData(source: source, token: token,
                                                             itemID: itemID, played: true) }
        }
        if isDefaultProfile, case .embyItem(let sourceID, let itemID) = items[index].location,
           let source = embySources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.embyToken(for: sourceID), !token.isEmpty {
            Task { try? await EmbyClient.updateUserData(source: source, token: token,
                                                        itemID: itemID, played: true) }
        }
        if isDefaultProfile, case .plexItem(let sourceID, let ratingKey, _) = items[index].location,
           let source = plexSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.plexToken(for: sourceID), !token.isEmpty {
            Task { try? await PlexClient.markPlayed(source: source, token: token,
                                                    ratingKey: ratingKey, played: true) }
        }
        save()
        scheduleTraktSync()
    }

    func toggleFavorite(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].favorite = !items[index].isFavorite
        items[index].stateUpdatedAt = Date()
        if isDefaultProfile, case .jellyfinItem(let sourceID, let itemID) = items[index].location,
           let source = jellyfinSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID), !token.isEmpty {
            let favorite = items[index].isFavorite
            Task { try? await JellyfinClient.updateUserData(source: source, token: token,
                                                             itemID: itemID, favorite: favorite) }
        }
        if isDefaultProfile, case .embyItem(let sourceID, let itemID) = items[index].location,
           let source = embySources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.embyToken(for: sourceID), !token.isEmpty {
            let favorite = items[index].isFavorite
            Task { try? await EmbyClient.updateUserData(source: source, token: token,
                                                        itemID: itemID, favorite: favorite) }
        }
        save()
    }

    func finishPlayback(id: UUID, position: Double, duration: Double?) {
        updateProgress(id: id, position: position, duration: duration)
        guard let item = items.first(where: { $0.id == id }) else { return }
        reportServerProgress(item: item, stopped: true)
        if item.watched { scheduleTraktSync() }
    }

    func testNetwork(item: MediaItem) {
        let reader: (@Sendable () throws -> SMBScanner.RangeResult)?
        switch item.location {
        case .remote(let url):
            guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                diagnosticMessage = "此协议暂不支持范围测速。"; return
            }
            reader = { try HTTPRangeReader.read(url: url, headers: [:], offset: 0, length: 1_048_576) }
        case .smbFile(let id, let path):
            guard let source = smbSources.first(where: { $0.id == id }) else { return }
            let password = try? KeychainPasswordStore.get(for: id)
            reader = { try SMBScanner.readRange(source: source, password: password,
                                                path: path, offset: 0, length: 1_048_576) }
        case .webDAVFile(let id, let path):
            guard let source = webDAVSources.first(where: { $0.id == id }) else { return }
            let password = try? KeychainPasswordStore.webDAVPassword(for: id)
            reader = { try WebDAVClient.readRange(source: source, password: password,
                                                 path: path, offset: 0, length: 1_048_576) }
        case .jellyfinItem(let id, let itemID):
            guard let source = jellyfinSources.first(where: { $0.id == id }),
                  let token = try? KeychainPasswordStore.jellyfinToken(for: id), !token.isEmpty else { return }
            reader = { try JellyfinClient.readRange(source: source, token: token,
                                                   itemID: itemID, offset: 0, length: 1_048_576) }
        case .embyItem(let id, let itemID):
            guard let source = embySources.first(where: { $0.id == id }),
                  let token = try? KeychainPasswordStore.embyToken(for: id), !token.isEmpty else { return }
            reader = { try EmbyClient.readRange(source: source, token: token,
                                               itemID: itemID, offset: 0, length: 1_048_576) }
        case .plexItem(let id, _, let partKey):
            guard let source = plexSources.first(where: { $0.id == id }),
                  let token = try? KeychainPasswordStore.plexToken(for: id), !token.isEmpty else { return }
            reader = { try PlexClient.readRange(source: source, token: token,
                                               partKey: partKey, offset: 0, length: 1_048_576) }
        case .cloudFile(let id, let identifier, _):
            guard let source = cloudSources.first(where: { $0.id == id }),
                  let token = try? KeychainPasswordStore.cloudToken(for: id), !token.isEmpty else { return }
            reader = { try CloudDriveClient.readRange(source: source, token: token,
                                                     identifier: identifier, offset: 0, length: 1_048_576) }
        case .bookmark, .folderFile:
            reader = nil
        }
        guard let reader else { return }
        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    let start = Date()
                    let data = try reader()
                    return (data.data.count, max(Date().timeIntervalSince(start), 0.001))
                }.value
                let megabits = Double(result.0) * 8 / result.1 / 1_000_000
                diagnosticMessage = "\(item.title)：\(megabits.formatted(.number.precision(.fractionLength(1)))) Mb/s（读取 \(result.0) 字节）。"
            } catch {
                diagnosticMessage = "\(item.title)：连接测试失败，\(error.localizedDescription)"
            }
        }
    }

    private func reportServerProgress(item: MediaItem, stopped: Bool) {
        if isDefaultProfile, case .jellyfinItem(let sourceID, let itemID) = item.location,
           let source = jellyfinSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID), !token.isEmpty {
            Task { try? await JellyfinClient.updateUserData(source: source, token: token,
                                                             itemID: itemID, position: item.position,
                                                             played: item.watched) }
        }
        if isDefaultProfile, case .embyItem(let sourceID, let itemID) = item.location,
           let source = embySources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.embyToken(for: sourceID), !token.isEmpty {
            Task { try? await EmbyClient.updateUserData(source: source, token: token,
                                                        itemID: itemID, position: item.position,
                                                        played: item.watched) }
        }
        if isDefaultProfile, case .plexItem(let sourceID, let ratingKey, _) = item.location,
           let source = plexSources.first(where: { $0.id == sourceID }),
           let token = try? KeychainPasswordStore.plexToken(for: sourceID), !token.isEmpty {
            Task { try? await PlexClient.reportProgress(source: source, token: token,
                                                        ratingKey: ratingKey, position: item.position,
                                                        duration: item.duration, stopped: stopped) }
        }
    }

    func applyMetadata(id: UUID, title: String, metadata: MediaMetadata) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].metadata?.posterPath != metadata.posterPath { clearPoster(index: index) }
        items[index].title = title
        items[index].metadata = metadata
        items[index].stateUpdatedAt = Date()
        save()
    }

    func enrichMissingMetadata(showResult: Bool = true) async {
        guard !enrichingMetadata else { return }
        let token: String
        do { token = try KeychainPasswordStore.metadataToken() ?? "" }
        catch { errorMessage = "无法读取 TMDB 令牌：\(error.localizedDescription)"; return }
        guard !token.isEmpty else {
            errorMessage = "请先在任意影片的“匹配在线资料”中填写 TMDB 读取令牌。"
            return
        }
        enrichingMetadata = true
        defer { enrichingMetadata = false }
        let retryBefore = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let candidates = Array(items.filter { item in
            let isServerItem: Bool
            switch item.location {
            case .jellyfinItem, .embyItem, .plexItem: isServerItem = true
            default: isServerItem = false
            }
            return !isServerItem && item.metadata == nil &&
                (item.metadataAttemptedAt ?? .distantPast) < retryBefore
        }.prefix(30))
        var matched = 0
        for item in candidates {
            let query = item.identity?.seriesName ?? item.title
            if let index = items.firstIndex(where: { $0.id == item.id }) {
                items[index].metadataAttemptedAt = Date()
            }
            do {
                let results = try await TMDBService.search(title: query,
                                                           television: item.identity?.seriesName != nil,
                                                           token: token)
                let normalized = query.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
                if let best = results.first(where: {
                    $0.displayTitle.folding(options: [.diacriticInsensitive, .caseInsensitive],
                                            locale: .current) == normalized
                }), let index = items.firstIndex(where: { $0.id == item.id }) {
                    if items[index].metadata?.posterPath != best.metadata.posterPath {
                        clearPoster(index: index)
                    }
                    items[index].metadata = best.metadata
                    if item.identity?.seriesName == nil { items[index].title = best.displayTitle }
                    items[index].stateUpdatedAt = Date()
                    matched += 1
                }
                try await Task.sleep(for: .milliseconds(400))
            } catch {
                errorMessage = "TMDB 匹配中断：\(error.localizedDescription)"
                break
            }
        }
        if !candidates.isEmpty { save() }
        if showResult { diagnosticMessage = "自动匹配了 \(matched) 部影片；每次最多处理 30 项。" }
    }

    private func scheduleMetadataEnrichment() {
        guard !enrichingMetadata,
              let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else { return }
        Task { await enrichMissingMetadata(showResult: false) }
    }

    func downloadedURL(for item: MediaItem) -> URL? {
        guard let name = item.downloadFileName,
              !name.contains("/"), !name.contains("..") else { return nil }
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func hasPausedDownload(id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: resumeURL(for: id).path) ||
            FileManager.default.fileExists(atPath: smbPartialURL(for: id).path)
    }

    func restoreInterruptedDownloads() {
        guard !restoredInterruptedDownloads else { return }
        restoredInterruptedDownloads = true
        let paused = userPausedDownloadIDs
        for item in items where hasPausedDownload(id: item.id) && !paused.contains(item.id.uuidString) {
            Task { await download(id: item.id) }
        }
    }

    private func resumeURL(for id: UUID) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).resume")
    }

    private func smbPartialURL(for id: UUID) -> URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).partial")
    }

    func posterURL(for item: MediaItem) -> URL? {
        guard let name = item.posterFileName,
              !name.contains("/"), !name.contains("..") else { return nil }
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("Posters", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func clearPoster(index: Int) {
        if let url = posterURL(for: items[index]) { try? FileManager.default.removeItem(at: url) }
        items[index].posterFileName = nil
    }

    func subtitleURL(for item: MediaItem) -> URL? {
        guard let name = item.customSubtitleFileName,
              !name.contains("/"), !name.contains("..") else { return nil }
        let url = fileURL.deletingLastPathComponent().appendingPathComponent("Subtitles", isDirectory: true)
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func installSubtitle(id: UUID, data: Data, filename: String) {
        let suffix = (filename as NSString).pathExtension.lowercased()
        guard SubtitleParser.supportedExtensions.contains(suffix), data.count <= 5_000_000,
              let index = items.firstIndex(where: { $0.id == id }) else {
            errorMessage = "字幕格式无效或超过 5 MB。"
            return
        }
        do {
            let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent("\(id.uuidString).\(suffix)")
            try data.write(to: destination, options: .atomic)
            if let old = subtitleURL(for: items[index]), old != destination {
                try? FileManager.default.removeItem(at: old)
            }
            items[index].customSubtitleFileName = destination.lastPathComponent
            save()
        } catch { errorMessage = "无法保存字幕：\(error.localizedDescription)" }
    }

    #if !os(tvOS)
    func importSubtitle(id: UUID, from url: URL) {
        guard SubtitleParser.supportedExtensions.contains(url.pathExtension.lowercased()),
              let index = items.firstIndex(where: { $0.id == id }) else {
            errorMessage = "请选择 SRT、VTT、ASS、SSA 或 SUP 字幕文件。"
            return
        }
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "无法读取字幕文件。"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }
        do {
            guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
            let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Subtitles", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(id.uuidString).\(url.pathExtension.lowercased())"
            let destination = directory.appendingPathComponent(name)
            if let old = subtitleURL(for: items[index]) { try? FileManager.default.removeItem(at: old) }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.copyItem(at: url, to: destination)
            items[index].customSubtitleFileName = name
            save()
        } catch {
            errorMessage = "无法导入字幕：\(error.localizedDescription)"
        }
    }
    #endif

    func removeSubtitle(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if let url = subtitleURL(for: items[index]) { try? FileManager.default.removeItem(at: url) }
        items[index].customSubtitleFileName = nil
        save()
    }

    func ensurePoster(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }),
              posterURL(for: item) == nil else { return }
        let request: URLRequest?
        if let url = item.metadata?.posterURL {
            request = URLRequest(url: url)
        } else {
            guard let key = item.serverPosterKey else { return }
            switch item.location {
            case .jellyfinItem(let sourceID, let itemID):
                guard let source = jellyfinSources.first(where: { $0.id == sourceID }),
                      let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID), !token.isEmpty else { return }
                request = JellyfinClient.posterRequest(source: source, token: token, itemID: itemID)
            case .embyItem(let sourceID, let itemID):
                guard let source = embySources.first(where: { $0.id == sourceID }),
                      let token = try? KeychainPasswordStore.embyToken(for: sourceID), !token.isEmpty else { return }
                request = EmbyClient.posterRequest(source: source, token: token, itemID: itemID)
            case .plexItem(let sourceID, _, _):
                guard let source = plexSources.first(where: { $0.id == sourceID }),
                      let token = try? KeychainPasswordStore.plexToken(for: sourceID), !token.isEmpty else { return }
                request = PlexClient.posterRequest(source: source, token: token, thumb: key)
            default: return
            }
        }
        guard let request else { return }
        do {
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard let response = response as? HTTPURLResponse,
                  (200..<300).contains(response.statusCode),
                  response.mimeType?.hasPrefix("image/") == true,
                  let size = try? temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                  size <= 5_000_000 else { return }
            let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Posters", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let name = "\(id.uuidString).jpg"
            let destination = directory.appendingPathComponent(name)
            if let index = items.firstIndex(where: { $0.id == id }) {
                guard items[index].metadata == item.metadata,
                      items[index].serverPosterKey == item.serverPosterKey else { return }
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: temporary, to: destination)
                items[index].posterFileName = name
                save()
            }
        } catch {
            // Artwork is optional; the title remains usable offline.
        }
    }

    func download(id: UUID) async {
        guard let item = items.first(where: { $0.id == id }), !downloading.contains(id) else { return }
        userPausedDownloadIDs.remove(id.uuidString)
        let extensionName: String
        switch item.location {
        case .remote(let url): extensionName = url.pathExtension
        case .smbFile(_, let path), .webDAVFile(_, let path): extensionName = (path as NSString).pathExtension
            case .jellyfinItem, .embyItem: extensionName = item.serverFileExtension ?? "mp4"
            case .plexItem(_, _, let partKey): extensionName = (partKey as NSString).pathExtension
            case .cloudFile(_, _, let filename): extensionName = (filename as NSString).pathExtension
        case .bookmark, .folderFile: return
        }
        let safeExtension = extensionName.range(of: "^[A-Za-z0-9]{1,8}$", options: .regularExpression) == nil
            ? "mp4" : extensionName.lowercased()
        let name = "\(id.uuidString).\(safeExtension)"
        let directory = fileURL.deletingLastPathComponent().appendingPathComponent("Downloads", isDirectory: true)
        let destination = directory.appendingPathComponent(name)
        downloading.insert(id)
        cancelledDownloads.remove(id)
        downloadProgress[id] = 0
        defer {
            downloading.remove(id)
            downloadProgress[id] = nil
            downloadOperations[id] = nil
            smbDownloadOperations[id] = nil
            cancelledDownloads.remove(id)
            pausedSMBDownloads.remove(id)
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let temporary: URL
            if case .smbFile = item.location { temporary = smbPartialURL(for: id) }
            else { temporary = directory.appendingPathComponent(UUID().uuidString + ".partial") }
            defer {
                if !pausedSMBDownloads.contains(id) { try? FileManager.default.removeItem(at: temporary) }
            }
            switch item.location {
            case .remote(let url):
                guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                    throw URLError(.unsupportedURL)
                }
                try await copyHTTP(URLRequest(url: url), to: temporary, id: id)
            case .webDAVFile(let sourceID, let path):
                guard let source = webDAVSources.first(where: { $0.id == sourceID }),
                      let request = WebDAVClient.downloadRequest(
                        source: source, password: try KeychainPasswordStore.webDAVPassword(for: sourceID), path: path
                      ) else { throw CocoaError(.fileReadNoPermission) }
                try await copyHTTP(request, to: temporary, id: id)
            case .jellyfinItem(let sourceID, let itemID):
                guard let source = jellyfinSources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.jellyfinToken(for: sourceID),
                      let request = JellyfinClient.downloadRequest(source: source, token: token, itemID: itemID) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                try await copyHTTP(request, to: temporary, id: id)
            case .embyItem(let sourceID, let itemID):
                guard let source = embySources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.embyToken(for: sourceID),
                      let request = EmbyClient.downloadRequest(source: source, token: token, itemID: itemID) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                try await copyHTTP(request, to: temporary, id: id)
            case .plexItem(let sourceID, _, let partKey):
                guard let source = plexSources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.plexToken(for: sourceID),
                      let request = PlexClient.downloadRequest(source: source, token: token, partKey: partKey) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                try await copyHTTP(request, to: temporary, id: id)
            case .cloudFile(let sourceID, let identifier, _):
                guard let source = cloudSources.first(where: { $0.id == sourceID }) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let token = try await validCloudToken(source: source)
                let request = try await CloudDriveClient.downloadRequestAsync(
                    source: source, token: token, identifier: identifier)
                try await copyHTTP(request, to: temporary, id: id)
            case .smbFile(let sourceID, let path):
                guard let source = smbSources.first(where: { $0.id == sourceID }) else {
                    throw CocoaError(.fileReadNoPermission)
                }
                let password = try KeychainPasswordStore.get(for: sourceID)
                let progressStore = self
                let transfer = Task.detached(priority: .utility) {
                    try SMBDownloader.copy(source: source, password: password, path: path,
                                           to: temporary) { fraction in
                        Task { @MainActor in progressStore.downloadProgress[id] = fraction }
                    }
                }
                smbDownloadOperations[id] = transfer
                try await withTaskCancellationHandler {
                    try await transfer.value
                } onCancel: {
                    transfer.cancel()
                }
            case .bookmark, .folderFile: return
            }
            guard !cancelledDownloads.contains(id), items.contains(where: { $0.id == id }) else {
                throw CancellationError()
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: temporary, to: destination)
            try? FileManager.default.removeItem(at: resumeURL(for: id))
            if let index = items.firstIndex(where: { $0.id == id }) {
                items[index].downloadFileName = name
                save()
            }
        } catch {
            if !Task.isCancelled && !cancelledDownloads.contains(id) && !(error is CancellationError) {
                errorMessage = "下载失败：\(error.localizedDescription)"
            }
        }
    }

    func cancelDownload(id: UUID) {
        userPausedDownloadIDs.remove(id.uuidString)
        if downloading.contains(id) { cancelledDownloads.insert(id) }
        downloadOperations[id]?.cancel()
        smbDownloadOperations[id]?.cancel()
        try? FileManager.default.removeItem(at: resumeURL(for: id))
        pausedSMBDownloads.remove(id)
        if !downloading.contains(id) { try? FileManager.default.removeItem(at: smbPartialURL(for: id)) }
        objectWillChange.send()
    }

    func pauseDownload(id: UUID) async {
        userPausedDownloadIDs.insert(id.uuidString)
        if let operation = smbDownloadOperations[id] {
            pausedSMBDownloads.insert(id)
            cancelledDownloads.insert(id)
            operation.cancel()
            return
        }
        guard let operation = downloadOperations[id] else { return }
        cancelledDownloads.insert(id)
        if !(await operation.pause()) {
            errorMessage = "此服务器不支持继续下载，请重新开始。"
        }
    }

    func removeDownload(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              let url = downloadedURL(for: items[index]) else { return }
        do {
            try FileManager.default.removeItem(at: url)
            items[index].downloadFileName = nil
            save()
        } catch {
            errorMessage = "无法删除下载文件：\(error.localizedDescription)"
        }
    }

    private func copyHTTP(_ request: URLRequest, to destination: URL, id: UUID) async throws {
        let operation = HTTPDownloader()
        downloadOperations[id] = operation
        try await operation.download(request, to: destination, resumeURL: resumeURL(for: id)) { [weak self] fraction in
            Task { @MainActor [weak self] in self?.downloadProgress[id] = fraction }
        }
    }

    func addCollection(name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !collections.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        collections.append(MediaCollection(name: name))
        libraryConfigUpdatedAt = Date()
        save()
    }

    func addSmartPlaylist(name: String, titleContains: String, seriesContains: String,
                          favoritesOnly: Bool, unwatchedOnly: Bool,
                          addedWithinDays: Int?, minimumRating: Double?) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty,
              !smartPlaylists.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) else { return }
        smartPlaylists.append(SmartPlaylist(name: name,
                                           titleContains: titleContains.trimmingCharacters(in: .whitespacesAndNewlines),
                                           seriesContains: seriesContains.trimmingCharacters(in: .whitespacesAndNewlines),
                                           favoritesOnly: favoritesOnly, unwatchedOnly: unwatchedOnly,
                                           addedWithinDays: addedWithinDays, minimumRating: minimumRating))
        libraryConfigUpdatedAt = Date()
        save()
    }

    func removeSmartPlaylist(id: UUID) {
        smartPlaylists.removeAll { $0.id == id }
        libraryConfigUpdatedAt = Date()
        save()
    }

    func removeCollection(id: UUID) {
        let members = collections.first(where: { $0.id == id })?.itemIDs ?? []
        collections.removeAll { $0.id == id }
        libraryConfigUpdatedAt = Date()
        let now = Date()
        for index in items.indices where members.contains(items[index].id) {
            items[index].stateUpdatedAt = now
        }
        save()
    }

    func setCollectionItem(collectionID: UUID, itemID: UUID, included: Bool) {
        guard let index = collections.firstIndex(where: { $0.id == collectionID }) else { return }
        collections[index].itemIDs.removeAll { $0 == itemID }
        if included { collections[index].itemIDs.append(itemID) }
        if let itemIndex = items.firstIndex(where: { $0.id == itemID }) {
            items[itemIndex].stateUpdatedAt = Date()
        }
        save()
    }

    func setExtra(parentID: UUID, extraID: UUID, included: Bool) {
        guard parentID != extraID,
              let index = items.firstIndex(where: { $0.id == parentID }),
              items.contains(where: { $0.id == extraID }) else { return }
        var extras = items[index].extraItemIDs ?? []
        extras.removeAll { $0 == extraID }
        if included { extras.append(extraID) }
        items[index].extraItemIDs = extras
        save()
    }

    func syncTrakt() async {
        guard isDefaultProfile, !traktSyncing else { return }
        let clientID = UserDefaults.standard.string(forKey: "lucent.trakt.clientID") ?? ""
        guard !clientID.isEmpty,
              let clientSecret = try? KeychainPasswordStore.traktSecret("clientSecret"),
              !clientSecret.isEmpty else {
            traktStatus = "请先配置 Trakt 应用凭据。"
            return
        }
        traktSyncing = true
        defer { traktSyncing = false }
        do {
            let removals = pendingTraktUnwatched
            if !removals.isEmpty {
                try await TraktClient.removeWatched(Array(removals), clientID: clientID,
                                                    clientSecret: clientSecret)
                pendingTraktUnwatched.subtract(removals)
            }
            let ratingRemovals = pendingTraktUnrated
            if !ratingRemovals.isEmpty {
                try await TraktClient.removeRatings(Array(ratingRemovals), clientID: clientID,
                                                    clientSecret: clientSecret)
                pendingTraktUnrated.subtract(ratingRemovals)
            }
            let remote = try await TraktClient.watched(clientID: clientID, clientSecret: clientSecret)
            let progress = try await TraktClient.playback(clientID: clientID, clientSecret: clientSecret)
            let remoteRatings = Dictionary(uniqueKeysWithValues:
                try await TraktClient.ratings(clientID: clientID, clientSecret: clientSecret)
                    .map { ($0.item, $0.rating) })
            guard isDefaultProfile else { return }
            var local = Set<TraktClient.Watched>()
            var outboundRatings: [TraktClient.Rated] = []
            var imported = 0
            for index in items.indices {
                guard let key = Self.traktKey(for: items[index]) else { continue }
                if items[index].watched { local.insert(key) }
                if let rating = items[index].personalRating {
                    if remoteRatings[key] != rating {
                        outboundRatings.append(TraktClient.Rated(item: key, rating: rating))
                    }
                } else if let rating = remoteRatings[key], !pendingTraktUnrated.contains(key) {
                    items[index].personalRating = rating
                    imported += 1
                }
                if remote.contains(key), !items[index].watched {
                    items[index].watched = true
                    items[index].position = 0
                    items[index].stateUpdatedAt = Date()
                    imported += 1
                } else if let remoteProgress = progress.first(where: { $0.item == key }),
                          !items[index].watched, let duration = items[index].duration, duration > 0 {
                    let position = duration * min(100, max(0, remoteProgress.percentage)) / 100
                    if position > items[index].position {
                        items[index].position = position
                        items[index].stateUpdatedAt = Date()
                        imported += 1
                    }
                }
            }
            let outbound = Array(local.subtracting(remote))
            try await TraktClient.addWatched(outbound, clientID: clientID, clientSecret: clientSecret)
            try await TraktClient.addRatings(outboundRatings, clientID: clientID,
                                             clientSecret: clientSecret)
            save()
            traktStatus = "Trakt 同步完成：导入 \(imported) 项，上传 \(outbound.count + outboundRatings.count) 项。"
        } catch {
            traktStatus = "Trakt 同步失败：\(error.localizedDescription)"
        }
    }

    func scheduleTraktSync() {
        guard isDefaultProfile, TraktClient.connected else { return }
        traktTask?.cancel()
        traktTask = Task {
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { await syncTrakt() }
        }
    }

    private static func traktKey(for item: MediaItem) -> TraktClient.Watched? {
        guard let id = item.metadata?.providerID else { return nil }
        switch item.identity {
        case .some(.movie), .none:
            return TraktClient.Watched(tmdbID: id, season: nil, episode: nil)
        case .some(.episode(_, let season, let number, _)):
            return TraktClient.Watched(tmdbID: id, season: season, episode: number)
        }
    }

    func setPersonalRating(id: UUID, rating: Int?) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              rating == nil || (1...10).contains(rating!) else { return }
        items[index].personalRating = rating
        if let key = Self.traktKey(for: items[index]) {
            if rating == nil { pendingTraktUnrated.insert(key) }
            else { pendingTraktUnrated.remove(key) }
        }
        save()
        scheduleTraktSync()
    }

    func rename(id: UUID, title: String) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = value
        items[index].stateUpdatedAt = Date()
        save()
    }

    func updateDetails(id: UUID, title: String, identity: MediaIdentity,
                       skipIntroEnd: Double? = nil, skipCreditsStart: Double? = nil) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = value
        items[index].identity = identity
        items[index].skipIntroEnd = skipIntroEnd
        items[index].skipCreditsStart = skipCreditsStart
        items[index].stateUpdatedAt = Date()
        save()
    }

    func remove(id: UUID) {
        removeItemsAndAssets { $0.id == id }
        save()
    }

    private func save() {
        do {
            let currentNetworkConfiguration = networkConfiguration()
            if currentNetworkConfiguration != lastNetworkConfiguration {
                libraryConfigUpdatedAt = Date()
                lastNetworkConfiguration = currentNetworkConfiguration
            }
            if let database { try database.save(snapshot()) }
            else {
                let data = try JSONEncoder().encode(snapshot())
                try data.write(to: fileURL, options: .atomic)
            }
            if syncing { syncRequestedDuringRun = true }
            else { scheduleSync() }
        } catch {
            errorMessage = "无法保存媒体库：\(error.localizedDescription)"
        }
    }

    private func networkConfiguration() -> NetworkSourceConfiguration {
        var smb = smbSources
        var webDAV = webDAVSources
        var jellyfin = jellyfinSources
        var emby = embySources
        var plex = plexSources
        var cloud = cloudSources
        var dlna = dlnaSources
        var vlcNetwork = vlcNetworkSources
        for index in smb.indices { smb[index].lastScannedAt = nil }
        for index in webDAV.indices { webDAV[index].lastScannedAt = nil }
        for index in jellyfin.indices { jellyfin[index].lastScannedAt = nil }
        for index in emby.indices { emby[index].lastScannedAt = nil }
        for index in plex.indices { plex[index].lastScannedAt = nil }
        for index in cloud.indices { cloud[index].lastScannedAt = nil }
        for index in dlna.indices { dlna[index].lastScannedAt = nil; dlna[index].mediaIDs = [] }
        for index in vlcNetwork.indices {
            vlcNetwork[index].lastScannedAt = nil
            vlcNetwork[index].mediaIDs = []
        }
        return NetworkSourceConfiguration(smb: smb, webDAV: webDAV,
                                          jellyfin: jellyfin, emby: emby, plex: plex, cloud: cloud,
                                          dlna: dlna, vlcNetwork: vlcNetwork)
    }

    func syncNow() async {
        guard iCloudSyncEnabled, !syncing else { return }
        guard isDefaultProfile else {
            syncStatus = "其他观看资料仅保存在本机"
            return
        }
        syncing = true
        defer {
            syncing = false
            if syncRequestedDuringRun {
                syncRequestedDuringRun = false
                scheduleSync()
            }
        }
        guard await CloudPlaybackSync.available() else {
            syncStatus = "iCloud 账户不可用"
            return
        }
        do {
            let remote = try await CloudPlaybackSync.fetchAll()
            var changed = false
            for index in items.indices {
                guard let key = CloudPlaybackSync.key(for: items[index], library: self),
                      let state = remote[key],
                      state.updatedAt > (items[index].stateUpdatedAt ?? .distantPast) else { continue }
                items[index].favorite = state.favorite
                items[index].watched = state.watched
                items[index].position = state.position
                items[index].duration = state.duration
                items[index].title = state.title
                if items[index].metadata?.posterPath != state.metadata?.posterPath {
                    clearPoster(index: index)
                }
                items[index].metadata = state.metadata
                if let names = state.collectionNames {
                    let itemID = items[index].id
                    for collectionIndex in collections.indices {
                        collections[collectionIndex].itemIDs.removeAll { $0 == itemID }
                    }
                    for name in Set(names) {
                        if let collectionIndex = collections.firstIndex(where: { $0.name == name }) {
                            collections[collectionIndex].itemIDs.append(itemID)
                        } else {
                            var collection = MediaCollection(name: name)
                            collection.itemIDs.append(itemID)
                            collections.append(collection)
                        }
                    }
                }
                items[index].stateUpdatedAt = state.updatedAt
                changed = true
            }
            let remoteConfiguration = try await CloudPlaybackSync.fetchConfiguration()
            if let remoteConfiguration,
               remoteConfiguration.updatedAt > (libraryConfigUpdatedAt ?? .distantPast) {
                let allowedNames = Set(remoteConfiguration.collectionNames)
                collections.removeAll { !allowedNames.contains($0.name) }
                for name in remoteConfiguration.collectionNames where
                    !collections.contains(where: { $0.name == name }) {
                    collections.append(MediaCollection(name: name))
                }
                smartPlaylists = remoteConfiguration.smartPlaylists
                if let sources = remoteConfiguration.networkSources {
                    smbSources = sources.smb
                    webDAVSources = sources.webDAV
                    jellyfinSources = sources.jellyfin
                    embySources = sources.emby
                    plexSources = sources.plex
                    cloudSources = sources.cloud
                    if let dlna = sources.dlna { dlnaSources = dlna }
                    if let vlcNetwork = sources.vlcNetwork { vlcNetworkSources = vlcNetwork }
                    lastNetworkConfiguration = networkConfiguration()
                }
                libraryConfigUpdatedAt = remoteConfiguration.updatedAt
                changed = true
            }
            if changed { save() }
            var uploads: [CloudPlaybackState] = []
            for item in items {
                guard let key = CloudPlaybackSync.key(for: item, library: self),
                      let updatedAt = item.stateUpdatedAt,
                      updatedAt > (remote[key]?.updatedAt ?? .distantPast) else { continue }
                uploads.append(CloudPlaybackState(
                    key: key, updatedAt: updatedAt, favorite: item.isFavorite,
                    watched: item.watched, position: item.position, duration: item.duration,
                    title: item.title, metadata: item.metadata,
                    collectionNames: collections.filter { $0.itemIDs.contains(item.id) }.map(\.name)
                ))
            }
            if !uploads.isEmpty { try await CloudPlaybackSync.saveMany(uploads) }
            if libraryConfigUpdatedAt == nil,
               !collections.isEmpty || !smartPlaylists.isEmpty ||
               !smbSources.isEmpty || !webDAVSources.isEmpty || !jellyfinSources.isEmpty ||
               !embySources.isEmpty || !plexSources.isEmpty || !cloudSources.isEmpty ||
               !dlnaSources.isEmpty || !vlcNetworkSources.isEmpty {
                libraryConfigUpdatedAt = Date()
                save()
            }
            if let libraryConfigUpdatedAt,
               libraryConfigUpdatedAt > (remoteConfiguration?.updatedAt ?? .distantPast) {
                try await CloudPlaybackSync.saveConfiguration(
                    CloudLibraryConfiguration(updatedAt: libraryConfigUpdatedAt,
                                              collectionNames: collections.map(\.name),
                                              smartPlaylists: smartPlaylists,
                                              networkSources: networkConfiguration()))
            }
            syncStatus = "上次同步：\(Date().formatted(date: .abbreviated, time: .shortened))"
        } catch {
            syncStatus = "iCloud 同步失败：\(error.localizedDescription)"
        }
    }

    private func scheduleSync() {
        guard iCloudSyncEnabled, !syncing else { return }
        syncTask?.cancel()
        syncTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            await self?.syncNow()
        }
    }

    private static func embyAPIAddress(_ address: String) -> String {
        let trimmed = address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let base = address.hasPrefix("https://") ? "https://" : "http://"
        let withoutScheme = trimmed.dropFirst(base.count)
        let path = String(withoutScheme).lowercased()
        return base + withoutScheme + (path.hasSuffix("/emby") ? "/" : "/emby/")
    }

    private static func isLocalHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") || value == "::1" { return true }
        let octets = value.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        let parts = octets.compactMap { UInt8($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || parts[0] == 127 ||
            (parts[0] == 169 && parts[1] == 254) ||
            (parts[0] == 192 && parts[1] == 168) ||
            (parts[0] == 172 && (16...31).contains(parts[1]))
    }
}
