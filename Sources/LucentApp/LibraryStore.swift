import Combine
import Foundation

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var fileSources: [LibraryFileSource] = []
    @Published private(set) var storageConnectionStates: [UUID: String] = [:]
    @Published private(set) var scopeScanStates: [UUID: String] = [:]
    private var storageFileIdentities: [String: UUID] = [:]
    private let scanCoordinator = LibraryScanCoordinator()
    private var scopeScanTasks: [UUID: Task<Void, Never>] {
        get { scanCoordinator.tasks }
        set { scanCoordinator.tasks = newValue }
    }
    private var pendingScopeScans: [UUID] {
        get { scanCoordinator.pending }
        set { scanCoordinator.pending = newValue }
    }
    @Published private(set) var catalogStructureRevision = UUID()
    @Published private(set) var items: [MediaItem] = []
    @Published private(set) var folders: [FolderSource] = []
    @Published private(set) var smbSources: [SMBSource] = []
    @Published private(set) var webDAVSources: [WebDAVSource] = []
    @Published private(set) var jellyfinSources: [JellyfinSource] = []
    @Published private(set) var embySources: [EmbySource] = []
    @Published private(set) var plexSources: [PlexSource] = []
    @Published private(set) var cloudSources: [CloudSource] = []
    @Published private(set) var excludedFileSourceIDs: Set<UUID> = Set(
        UserDefaults.standard.stringArray(forKey: "lucent.library.excludedFileSources")?
            .compactMap(UUID.init(uuidString:)) ?? [])
    @Published private(set) var dlnaSources: [DLNASource] = []
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
    @Published private(set) var scanningPlexSources: Set<UUID> = []
    @Published private(set) var offlinePlexSources: Set<UUID> = []
    @Published private(set) var scanningCloudSources: Set<UUID> = []
    @Published private(set) var offlineCloudSources: Set<UUID> = []
    @Published private(set) var scanningDLNASources: Set<UUID> = []
    @Published private(set) var offlineDLNASources: Set<UUID> = []
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
            if iCloudSyncEnabled { scheduleSync() }
            else { syncTask?.cancel() }
        }
    }
    @Published var errorMessage: String?
    @Published var diagnosticMessage: String?

    private let fileURL: URL
    private lazy var serverOutbox = ServerStateOutbox(url: fileURL.deletingLastPathComponent().appendingPathComponent("server-state-outbox.json"))
    private var database: LibraryRepository?
    @Published private(set) var processingItemTitle: String?
    @Published private(set) var catalogProcessingStatus: String?
    @Published private(set) var mediaProbeEnabled = UserDefaults.standard.bool(forKey: "lucent.library.mediaProbeEnabled")
    private var technicalProbeTask: Task<Void, Never>?
    private var catalogArtworkTask: Task<Void, Never>?
    private var warmedCatalogArtwork: Set<URL> = []
    private var catalogMetadataCache: [String: MediaMetadata] = [:]
    private let metadataCoordinator = MetadataCoordinator()
    private var metadataEnrichmentFailed = false
    private var metadataRetryRequested = false
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
    private var networkObserver: NSObjectProtocol?
    private var preferencesObserver: NSObjectProtocol?
    private var lastUserPreferences: [String: Data] = [:]
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
            let sqlite = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
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
        migrateLegacyFileSourcesIfNeeded()
        for index in items.indices where items[index].technicalInfo == nil && items[index].technicalProbeError == nil {
            items[index].technicalProbeAttemptedAt = nil
        }
        lastNetworkConfiguration = networkConfiguration()
        lastUserPreferences = CloudUserPreferences.capture()
        preferencesObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification,
                                                                     object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let current = CloudUserPreferences.capture()
                guard current != self.lastUserPreferences else { return }
                self.lastUserPreferences = current
                self.libraryConfigUpdatedAt = Date()
                self.save()
            }
        }
        _ = NetworkUsagePolicy.shared
        networkObserver = NotificationCenter.default.addObserver(forName: NetworkUsagePolicy.changed, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if NetworkUsagePolicy.shared.route == .cellular && !NetworkUsagePolicy.allowsDownloads {
                    for id in Array(self.downloading) { await self.pauseDownload(id: id) }
                }
                if NetworkUsagePolicy.syncPermitted(on: NetworkUsagePolicy.shared.route, allowed: NetworkUsagePolicy.allowsSync) {
                    self.scheduleSync(); self.scheduleTraktSync()
                    await self.resumeServerStateSync()
                }
                if NetworkUsagePolicy.shared.route != .cellular || NetworkUsagePolicy.allowsDownloads {
                    self.restoreInterruptedDownloads()
                }
            }
        }
        pumpScopeScans()
        scheduleMetadataEnrichment()
        Task { [weak self] in
            _ = await NetworkUsagePolicy.shared.readyRoute()
            await self?.resumeServerStateSync()
        }
    }

    private func applySnapshot(_ snapshot: LibrarySnapshot) {
        items = snapshot.items
        fileSources = snapshot.fileSources ?? []
        storageFileIdentities = snapshot.storageFileIdentities ?? [:]
        pendingScopeScans = snapshot.pendingScopeScanIDs ?? []
        folders = snapshot.folders
        smbSources = snapshot.smbSources ?? []
        webDAVSources = snapshot.webDAVSources ?? []
        jellyfinSources = snapshot.jellyfinSources ?? []
        embySources = snapshot.embySources ?? []
        plexSources = snapshot.plexSources ?? []
        cloudSources = snapshot.cloudSources ?? []
        dlnaSources = snapshot.dlnaSources ?? []
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
        return LibrarySnapshot(fileSources: fileSources, storageFileIdentities: storageFileIdentities, pendingScopeScanIDs: Array(Set(pendingScopeScans + scopeScanTasks.filter { !$0.value.isCancelled }.map(\.key))), items: items, folders: folders, smbSources: smbSources,
                        webDAVSources: webDAVSources, jellyfinSources: jellyfinSources,
                        embySources: embySources,
                        plexSources: plexSources, cloudSources: cloudSources, dlnaSources: dlnaSources,
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
                items[index].favoriteUpdatedAt = state.favoriteUpdatedAt
                items[index].lastPlayedAt = state.lastPlayedAt
                items[index].stateUpdatedAt = state.stateUpdatedAt
            } else {
                items[index].position = 0
                items[index].watched = false
                items[index].favorite = false
                items[index].favoriteUpdatedAt = nil
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

    func addDLNA(device: DLNAClient.Device, videos: [DLNAClient.Video]) -> Int {
        guard isDefaultProfile else { return 0 }
        let source: DLNASource
        if let existing = dlnaSources.first(where: { $0.descriptionAddress == device.descriptionURL.absoluteString }) {
            source = existing
        } else {
            source = DLNASource(name: device.name, descriptionURL: device.descriptionURL)
            dlnaSources.append(source)
        }
        if videos.isEmpty { save(); return 0 }
        return reconcileDLNA(id: source.id, videos: videos)
    }

    func scanDLNA(id: UUID) {
        for scope in fileSources where scope.storageID == id && scope.enabled && !scope.needsConfirmation { scanFileScope(scope.id) }
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
            setFileSourceIncluded(false, id: source.id)
        } catch {
            errorMessage = "无法保存文件夹访问权限：\(error.localizedDescription)"
        }
    }

    func renameFolder(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        save()
    }

    func scanFolder(id: UUID) {
        for scope in fileSources where scope.storageID == id && scope.enabled && !scope.needsConfirmation { scanFileScope(scope.id) }
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

    func updateServerAddress(id: UUID, address: String, replacementToken: String? = nil,
                             username: String? = nil, password: String = "") async -> UUID? {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host) else {
            errorMessage = "请输入有效的服务器地址。外网连接需要 HTTPS。"
            return nil
        }
        let loginName = username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        do {
            if let index = embySources.firstIndex(where: { $0.id == id }) {
                let normalized = Self.embyAPIAddress(raw)
                let source = embySources[index]
                let token: String
                var authenticatedUserID: String?
                if !loginName.isEmpty && password.isEmpty &&
                    loginName.caseInsensitiveCompare(source.username ?? loginName) != .orderedSame {
                    errorMessage = "更换登录用户名时，请同时输入密码。"
                    return nil
                }
                if !loginName.isEmpty && !password.isEmpty {
                    let login = try await EmbyClient.authenticate(baseAddress: normalized,
                                                                   username: loginName, password: password)
                    token = login.token
                    authenticatedUserID = login.userID
                } else if let replacementToken, !replacementToken.isEmpty {
                    token = replacementToken
                } else {
                    guard let saved = try KeychainPasswordStore.embyToken(for: id) else {
                        errorMessage = "原访问令牌不可用，请重新输入登录凭据。"
                        return nil
                    }
                    token = saved
                }
                let userID = authenticatedUserID ?? source.userID
                let resolvedName = try await EmbyClient.validateUser(baseAddress: normalized, token: token,
                                                                     userID: userID)
                if userID.caseInsensitiveCompare(source.userID) != .orderedSame {
                    guard !embySources.contains(where: {
                        $0.id != id && $0.baseAddress == normalized &&
                        $0.userID.caseInsensitiveCompare(userID) == .orderedSame
                    }) else {
                        errorMessage = "该服务器账号已添加。"
                        return nil
                    }
                    var replacement = EmbySource(baseAddress: normalized, userID: userID)
                    replacement.displayName = source.displayName
                    replacement.serverKind = source.serverKind
                    replacement.username = resolvedName ?? loginName
                    replacement.usesTokenLogin = false
                    try KeychainPasswordStore.setEmbyToken(token, for: replacement.id)
                    embySources.append(replacement)
                    removeEmby(id: id)
                    return replacement.id
                }
                try KeychainPasswordStore.setEmbyToken(token, for: id)
                embySources[index].baseAddress = normalized
                embySources[index].username = resolvedName ?? source.username
                if !loginName.isEmpty && !password.isEmpty { embySources[index].usesTokenLogin = false }
            } else if let index = jellyfinSources.firstIndex(where: { $0.id == id }) {
                let normalized = raw.hasSuffix("/") ? raw : raw + "/"
                let source = jellyfinSources[index]
                let token: String
                if !loginName.isEmpty && password.isEmpty &&
                    loginName.caseInsensitiveCompare(source.username ?? loginName) != .orderedSame {
                    errorMessage = "更换登录用户名时，请同时输入密码。"
                    return nil
                }
                if !loginName.isEmpty && !password.isEmpty {
                    token = try await JellyfinClient.authenticate(baseAddress: normalized,
                                                                    username: loginName, password: password)
                } else if let replacementToken, !replacementToken.isEmpty {
                    token = replacementToken
                } else {
                    guard let saved = try KeychainPasswordStore.jellyfinToken(for: id) else {
                        errorMessage = "原访问令牌不可用，请重新输入登录凭据。"
                        return nil
                    }
                    token = saved
                }
                let user = try await JellyfinClient.currentUser(baseAddress: normalized, token: token)
                if user.id.caseInsensitiveCompare(source.userID) != .orderedSame {
                    guard !jellyfinSources.contains(where: {
                        $0.id != id && $0.baseAddress == normalized &&
                        $0.userID.caseInsensitiveCompare(user.id) == .orderedSame
                    }) else {
                        errorMessage = "该服务器账号已添加。"
                        return nil
                    }
                    var replacement = JellyfinSource(baseAddress: normalized, userID: user.id)
                    replacement.displayName = source.displayName
                    replacement.username = user.name ?? loginName
                    replacement.usesTokenLogin = loginName.isEmpty
                    try KeychainPasswordStore.setJellyfinToken(token, for: replacement.id)
                    jellyfinSources.append(replacement)
                    removeJellyfin(id: id)
                    return replacement.id
                }
                try KeychainPasswordStore.setJellyfinToken(token, for: id)
                jellyfinSources[index].baseAddress = normalized
                jellyfinSources[index].username = user.name ?? source.username
                if !loginName.isEmpty && !password.isEmpty { jellyfinSources[index].usesTokenLogin = false }
                offlineJellyfinSources.remove(id)
            } else if let index = plexSources.firstIndex(where: { $0.id == id }) {
                let normalized = raw.hasSuffix("/") ? raw : raw + "/"
                let source = plexSources[index]
                let oldToken = try KeychainPasswordStore.plexToken(for: id)
                guard let token = replacementToken?.isEmpty == false ? replacementToken : oldToken else {
                    errorMessage = "原访问令牌不可用，请重新输入访问令牌。"
                    return nil
                }
                try await PlexClient.validate(baseAddress: normalized, token: token)
                let accountName = try? await PlexClient.accountName(token: token)
                // Account lookup can fail independently of server validation. A changed token
                // with unknown account identity gets a fresh source to avoid mixing watch data.
                let changedAccount = accountName.map { name in
                    source.username.map { $0.caseInsensitiveCompare(name) != .orderedSame } ?? (token != oldToken)
                } ?? (token != oldToken)
                if changedAccount {
                    guard !plexSources.contains(where: {
                        $0.id != id && $0.baseAddress == normalized &&
                        accountName != nil && $0.username?.caseInsensitiveCompare(accountName!) == .orderedSame
                    }) else {
                        errorMessage = "该服务器账号已添加。"
                        return nil
                    }
                    var replacement = PlexSource(baseAddress: normalized)
                    replacement.displayName = source.displayName
                    replacement.username = accountName
                    try KeychainPasswordStore.setPlexToken(token, for: replacement.id)
                    plexSources.append(replacement)
                    removePlex(id: id)
                    return replacement.id
                }
                try KeychainPasswordStore.setPlexToken(token, for: id)
                plexSources[index].baseAddress = normalized
                plexSources[index].username = accountName ?? source.username
                offlinePlexSources.remove(id)
            } else { return nil }
            save()
            return id
        } catch {
            errorMessage = "更新服务器连接失败：\(error.localizedDescription)"
            return nil
        }
    }

    var localLibraryItems: [MediaItem] {
        let included = fileSources.filter { $0.enabled && !$0.needsConfirmation }.reduce(into: Set<UUID>()) { $0.formUnion($1.itemIDs) }
        let storedDLNA = Set(dlnaSources.flatMap(\.mediaIDs)).union(storageFileIdentities.values)
        return items.filter { item in
            if included.contains(item.id) { return true }
            switch item.location {
            case .bookmark: return true
            case .remote: return !storedDLNA.contains(item.id)
            default: return false
            }
        }
    }

    func isFileSourceIncluded(_ id: UUID) -> Bool {
        if let scope = fileSources.first(where: { $0.id == id }) { return scope.enabled && !scope.needsConfirmation }
        return fileSources.contains { $0.storageID == id && $0.enabled && !$0.needsConfirmation }
    }

    func fileSourceItemCount(_ id: UUID) -> Int {
        if let scope = fileSources.first(where: { $0.id == id }) {
            return items.filter { scope.itemIDs.contains($0.id) && $0.missingSince == nil }.count
        }
        return items.reduce(into: 0) { count, item in
            switch item.location {
            case .folderFile(let sourceID, _), .smbFile(let sourceID, _),
                 .webDAVFile(let sourceID, _), .cloudFile(let sourceID, _, _):
                if sourceID == id && item.missingSince == nil { count += 1 }
            default: break
            }
        }
    }

    func setFileSourceIncluded(_ included: Bool, id: UUID) {
        if let index = fileSources.firstIndex(where: { $0.id == id }) {
            fileSources[index].enabled = included
            fileSources[index].needsConfirmation = false
            if included { scanFileScope(id) } else { cancelScopeScan(id) }
            save(); return
        }
        if included { excludedFileSourceIDs.remove(id) }
        else { excludedFileSourceIDs.insert(id) }
        UserDefaults.standard.set(excludedFileSourceIDs.map(\.uuidString),
                                  forKey: "lucent.library.excludedFileSources")
        if included {
            #if !os(tvOS)
            if folders.contains(where: { $0.id == id }) { scanFolder(id: id) }
            #endif
            if smbSources.contains(where: { $0.id == id }) { scanSMB(id: id) }
            if webDAVSources.contains(where: { $0.id == id }) { scanWebDAV(id: id) }
            if cloudSources.contains(where: { $0.id == id }) { scanCloud(id: id) }
            scheduleMetadataEnrichment()
        }
    }

    var fileSourceIDs: [UUID] {
        fileSources.map(\.id)
    }

    func isScanningFileSource(_ id: UUID) -> Bool {
        if scopeScanTasks[id] != nil || pendingScopeScans.contains(id) { return true }
        return scanningFolders.contains(id) || scanningSMBSources.contains(id) ||
        scanningWebDAVSources.contains(id) || scanningCloudSources.contains(id)
    }

    func refreshFileSource(_ id: UUID) {
        if fileSources.contains(where: { $0.id == id }) { scanFileScope(id); return }
        #if !os(tvOS)
        if folders.contains(where: { $0.id == id }) { scanFolder(id: id) }
        #endif
        if smbSources.contains(where: { $0.id == id }) { scanSMB(id: id) }
        if webDAVSources.contains(where: { $0.id == id }) { scanWebDAV(id: id) }
        if cloudSources.contains(where: { $0.id == id }) { scanCloud(id: id) }
    }

    func browsedFileItem(sourceID: UUID, path: String) -> MediaItem? {
        guard !path.isEmpty, !path.split(separator: "/").contains("..") else { return nil }
        let location: MediaLocation
        if folders.contains(where: { $0.id == sourceID }) { location = .folderFile(sourceID: sourceID, relativePath: path) }
        else if smbSources.contains(where: { $0.id == sourceID }) { location = .smbFile(sourceID: sourceID, relativePath: path) }
        else if webDAVSources.contains(where: { $0.id == sourceID }) { location = .webDAVFile(sourceID: sourceID, relativePath: path) }
        else { return nil }
        if let item = items.first(where: { $0.location == location }) { return item }
        let parsed = MediaNameParser.parse(filename: (path as NSString).lastPathComponent)
        let item = MediaItem(title: parsed.title, location: location, identity: parsed.identity)
        items.append(item)
        save()
        if isFileSourceIncluded(sourceID) { scheduleMetadataEnrichment() }
        return item
    }

    func renameFileSource(id: UUID, name: String) {
        if let index = fileSources.firstIndex(where: { $0.id == id }) {
            let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { return }
            fileSources[index].name = clean; save(); return
        }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = folders.firstIndex(where: { $0.id == id }) { folders[index].name = name }
        else if let index = smbSources.firstIndex(where: { $0.id == id }) { smbSources[index].displayName = name }
        else if let index = webDAVSources.firstIndex(where: { $0.id == id }) { webDAVSources[index].displayName = name }
        else if let index = cloudSources.firstIndex(where: { $0.id == id }) { cloudSources[index].name = name }
        else { return }
        save()
    }

    func renameServer(id: UUID, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let index = embySources.firstIndex(where: { $0.id == id }) {
            embySources[index].displayName = trimmed
        } else if let index = jellyfinSources.firstIndex(where: { $0.id == id }) {
            jellyfinSources[index].displayName = trimmed
        } else if let index = plexSources.firstIndex(where: { $0.id == id }) {
            plexSources[index].displayName = trimmed
        } else { return }
        save()
    }

    func refreshFolders() {
        guard isDefaultProfile else { return }
        scheduleMetadataEnrichment()
        pumpScopeScans()
        let interval = (UserDefaults.standard.object(forKey: "lucent.library.autoScanInterval") as? Double) ?? 86_400
        guard interval > 0 else { return }
        let before = Date().addingTimeInterval(-interval)
        for scope in fileSources where scope.enabled && !scope.needsConfirmation && (scope.lastScannedAt ?? scope.importedAt ?? .distantPast) < before { scanFileScope(scope.id) }
    }

    func saveSMBConnection(id: UUID?, name: String, host: String, share: String, username: String,
                           domain: String, password: String?, syncAllowed: Bool) -> Bool {
        let host = host.trimmingCharacters(in:.whitespacesAndNewlines)
        let share = share.trimmingCharacters(in:.whitespacesAndNewlines)
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, !host.isEmpty, !share.isEmpty, !host.contains("/"), !host.contains("@"),
              !host.contains(" "), !share.contains("/"), share != ".", share != ".." else {
            errorMessage = "请填写名称、有效的服务器地址和共享名称。"; return false
        }
        guard !smbSources.contains(where: { $0.id != id && $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.share.caseInsensitiveCompare(share) == .orderedSame && $0.username == username && ($0.domain ?? "") == domain }) else {
            errorMessage = "该 SMB 连接已存在。"; return false
        }
        var source = id.flatMap { value in smbSources.first { $0.id == value } } ?? SMBSource(host:host,share:share,username:username)
        guard id == nil || source.id == id else { errorMessage = "存储已移除。"; return false }
        do {
            if let password { try KeychainPasswordStore.set(password,for:source.id) }
            source.host = host; source.share = share; source.username = username
            source.domain = domain.isEmpty ? nil : domain; source.displayName = name; source.syncAllowed = syncAllowed
            if let index = smbSources.firstIndex(where: { $0.id == source.id }) { smbSources[index] = source }
            else { smbSources.append(source) }
            save(); return true
        } catch { errorMessage = "无法保存 SMB 凭据。"; return false }
    }

    func saveWebDAVConnection(id: UUID?, name: String, address: String, username: String,
                              password: String?, syncAllowed: Bool) -> Bool {
        let name = name.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !name.isEmpty, let url = URL(string:address), let host = url.host,
              ["http","https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil,
              url.scheme?.lowercased() == "https" || Self.isLocalHost(host) else {
            errorMessage = "请填写名称与有效地址；公网连接需使用 HTTPS。"; return false
        }
        let address = address.hasSuffix("/") ? address : address + "/"
        guard !webDAVSources.contains(where: { $0.id != id && $0.baseAddress == address && $0.username == username }) else { errorMessage = "该 WebDAV 连接已存在。"; return false }
        var source = id.flatMap { value in webDAVSources.first { $0.id == value } } ?? WebDAVSource(baseAddress:address,username:username)
        guard id == nil || source.id == id else { errorMessage = "存储已移除。"; return false }
        do {
            if let password { try KeychainPasswordStore.setWebDAVPassword(password,for:source.id) }
            source.baseAddress = address; source.username = username; source.displayName = name; source.syncAllowed = syncAllowed
            if let index = webDAVSources.firstIndex(where: { $0.id == source.id }) { webDAVSources[index] = source }
            else { webDAVSources.append(source) }
            save(); return true
        } catch { errorMessage = "无法保存 WebDAV 凭据。"; return false }
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
            setFileSourceIncluded(false, id: source.id)
            return true
        } catch {
            errorMessage = "无法保存 SMB 凭据：\(error.localizedDescription)"
            return false
        }
    }

    func scanSMB(id: UUID) {
        for scope in fileSources where scope.storageID == id && scope.enabled && !scope.needsConfirmation { scanFileScope(scope.id) }
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
            setFileSourceIncluded(false, id: source.id)
            return true
        } catch {
            errorMessage = "无法保存 WebDAV 凭据：\(error.localizedDescription)"
            return false
        }
    }

    func scanWebDAV(id: UUID) {
        for scope in fileSources where scope.storageID == id && scope.enabled && !scope.needsConfirmation { scanFileScope(scope.id) }
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
        do {
            let user = try await JellyfinClient.currentUser(baseAddress: normalized, token: token)
            guard !jellyfinSources.contains(where: {
                $0.baseAddress == normalized && $0.userID.caseInsensitiveCompare(user.id) == .orderedSame
            }) else {
                errorMessage = "这个 Jellyfin 用户已添加。"
                return false
            }
            var source = JellyfinSource(baseAddress: normalized, userID: user.id)
            source.username = user.name
            source.usesTokenLogin = true
            try KeychainPasswordStore.setJellyfinToken(token, for: source.id)
            jellyfinSources.append(source)
            save()
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
        do {
            let token = try await JellyfinClient.authenticate(baseAddress: raw, username: username,
                                                                password: password)
            let added = await addJellyfin(address: raw, token: token)
            if added, let index = jellyfinSources.indices.last {
                jellyfinSources[index].username = username
                jellyfinSources[index].usesTokenLogin = false
                save()
            }
            return added
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
                            items[itemIndex].stateUpdatedAt = remote.remoteStateDate ?? Date()
                        }
                    } else {
                        var item = MediaItem(title: remote.name,
                                             location: .jellyfinItem(sourceID: id, itemID: remote.id),
                                             identity: remote.identity)
                        item.duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
                        item.position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
                        item.watched = remote.userData?.played ?? false
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

    func openJellyfinItem(sourceID: UUID, remote: JellyfinItem) -> MediaItem {
        if let existing = items.first(where: {
            if case .jellyfinItem(let id, let itemID) = $0.location {
                return id == sourceID && itemID == remote.id
            }
            return false
        }) { return existing }
        var item = MediaItem(title: remote.name,
                             location: .jellyfinItem(sourceID: sourceID, itemID: remote.id),
                             identity: remote.identity)
        item.duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
        item.position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
        item.watched = remote.userData?.played ?? false
        item.stateUpdatedAt = remote.remoteStateDate ?? Date()
        item.serverSummary = remote.overview
        item.serverPosterKey = remote.imageTags?.primary
        item.serverFileExtension = remote.fileExtension
        items.insert(item, at: 0)
        save()
        return item
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
            let user = try await JellyfinClient.currentUser(baseAddress: jellyfinSources[index].baseAddress,
                                                             token: token)
            guard user.id.caseInsensitiveCompare(jellyfinSources[index].userID) == .orderedSame else {
                errorMessage = "登录用户与原服务器用户不同，请新建一个连接。"
                return false
            }
            try KeychainPasswordStore.setJellyfinToken(token, for: id)
            jellyfinSources[index].username = user.name ?? jellyfinSources[index].username
            offlineJellyfinSources.remove(id)
            save()
            return true
        } catch {
            errorMessage = "无法更新 Jellyfin 令牌：\(error.localizedDescription)"
            return false
        }
    }

    func addEmby(address: String, token: String, userID: String, kind: EmbyServerKind = .emby) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host),
              !token.isEmpty, !userID.isEmpty else {
            errorMessage = "请输入有效的 \(kind.title) 地址、访问令牌和用户 ID。"
            return false
        }
        let normalized = Self.embyAPIAddress(raw)
        do {
            let username = try await EmbyClient.validateUser(baseAddress: normalized, token: token, userID: userID)
            guard !embySources.contains(where: {
                $0.baseAddress == normalized && $0.userID.caseInsensitiveCompare(userID) == .orderedSame
            }) else {
                errorMessage = "这个服务器用户已添加。"
                return false
            }
            var source = EmbySource(baseAddress: normalized, userID: userID)
            source.serverKind = kind
            source.username = username
            source.usesTokenLogin = true
            try KeychainPasswordStore.setEmbyToken(token, for: source.id)
            embySources.append(source)
            save()
            return true
        } catch {
            errorMessage = "连接 \(kind.title) 失败：\(error.localizedDescription)"
            return false
        }
    }

    func addEmby(address: String, username: String, password: String, kind: EmbyServerKind = .emby) async -> Bool {
        let raw = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = url.host,
              url.user == nil, url.password == nil,
              scheme == "https" || Self.isLocalHost(host),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入有效的 \(kind.title) 地址与用户名。"
            return false
        }
        let normalized = Self.embyAPIAddress(raw)
        do {
            let login = try await EmbyClient.authenticate(baseAddress: normalized, username: username,
                                                           password: password)
            let added = await addEmby(address: raw, token: login.token, userID: login.userID, kind: kind)
            if added, let index = embySources.indices.last {
                embySources[index].username = login.username
                embySources[index].usesTokenLogin = false
                save()
            }
            return added
        } catch {
            errorMessage = "\(kind.title) 登录失败：\(error.localizedDescription)"
            return false
        }
    }

    func synchronizePlexHome(sourceID: UUID) async throws {
        guard let source = plexSources.first(where: { $0.id == sourceID }),
              let token = try KeychainPasswordStore.plexToken(for: sourceID) else { throw ServerCatalogSync.Failure.requestFailed }
        let keys = items.compactMap { value -> String? in
            if case .plexItem(let id, let key, _) = value.location, id == sourceID { return key }; return nil
        }
        guard !keys.isEmpty else { return }
        var remote: [String: PlexItem] = [:]
        // Bounded concurrency prevents refresh from flooding a NAS with metadata requests.
        for start in stride(from: 0, to: keys.count, by: 4) {
            let batch = Array(keys[start..<min(start + 4, keys.count)])
            let values = try await withThrowingTaskGroup(of: (String, PlexItem?).self) { group in
                for key in batch { group.addTask { (key, try await PlexClient.cachedItem(source: source, token: token, ratingKey: key)) } }
                var result: [String: PlexItem] = [:]
                for try await (key, item) in group { if let item { result[key] = item } }
                return result
            }
            remote.merge(values) { _, new in new }
        }
        try Task.checkCancellation()
        guard plexSources.contains(where: { $0.id == sourceID && $0.baseAddress == source.baseAddress }) else { return }
        let requested = Set(keys)
        var removed = Set<UUID>()
        for index in items.indices {
            guard case .plexItem(let id, let key, _) = items[index].location, id == sourceID, requested.contains(key) else { continue }
            guard let value = remote[key] else {
                if downloadedURL(for: items[index]) == nil { removed.insert(items[index].id) }
                else { items[index].missingSince = items[index].missingSince ?? Date() }
                continue
            }
            items[index].title = value.title; items[index].identity = value.identity
            items[index].serverSummary = value.summary; items[index].serverPosterKey = value.thumb
            items[index].missingSince = nil
            if let part = value.partKey { items[index].location = .plexItem(sourceID: sourceID, ratingKey: key, partKey: part) }
            if let duration = value.duration { items[index].duration = duration / 1000 }
        }
        items.removeAll { removed.contains($0.id) }
        for index in collections.indices { collections[index].itemIDs.removeAll { removed.contains($0) } }
        save()
    }

    func synchronizeServerHome(sourceID: UUID, emby: Bool, displayedItems: [JellyfinItem]) async throws {
        try Task.checkCancellation()
        let remote = displayedItems
        let cached = displayedItems.map(\.id)
        guard !cached.isEmpty else { return }
        let byID = Dictionary(remote.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let requested = Set(cached)
        var removed = Set<UUID>()
        for index in items.indices {
            let key: String
            switch items[index].location {
            case .embyItem(let id, let remoteID) where emby && id == sourceID: key = remoteID
            case .jellyfinItem(let id, let remoteID) where !emby && id == sourceID: key = remoteID
            default: continue
            }
            guard requested.contains(key) else { continue }
            guard let value = byID[key] else {
                // Keep downloaded bytes and progress; do not erase user downloads on server deletion.
                if downloadedURL(for: items[index]) == nil { removed.insert(items[index].id) }
                else { items[index].missingSince = items[index].missingSince ?? Date() }
                continue
            }
            items[index].missingSince = nil
            items[index].title = value.name; items[index].identity = value.identity
            items[index].serverSummary = value.overview; items[index].serverPosterKey = value.imageTags?.primary
            items[index].serverFileExtension = value.fileExtension
            if let ticks = value.runTimeTicks, ticks > 0 { items[index].duration = Double(ticks) / 10_000_000 }
            if let date = value.remoteStateDate, date >= (items[index].stateUpdatedAt ?? .distantPast) {
                items[index].position = Double(value.userData?.playbackPositionTicks ?? 0) / 10_000_000
                items[index].watched = value.userData?.played ?? items[index].watched
                items[index].stateUpdatedAt = date
            }
        }
        items.removeAll { removed.contains($0.id) }
        for index in collections.indices { collections[index].itemIDs.removeAll { removed.contains($0) } }
        save()
    }

    func openEmbyItem(sourceID: UUID, remote: JellyfinItem) -> MediaItem {
        if let index = items.firstIndex(where: {
            if case .embyItem(let id, let itemID) = $0.location {
                return id == sourceID && itemID == remote.id
            }
            return false
        }) {
            return items[index]
        }
        var item = MediaItem(title: remote.name,
                             location: .embyItem(sourceID: sourceID, itemID: remote.id),
                             identity: remote.identity)
        item.duration = remote.runTimeTicks.map { Double($0) / 10_000_000 }
        item.position = Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000
        item.watched = remote.userData?.played ?? false
        item.stateUpdatedAt = remote.remoteStateDate ?? Date()
        item.serverSummary = remote.overview
        item.serverPosterKey = remote.imageTags?.primary
        item.serverFileExtension = remote.fileExtension
        items.insert(item, at: 0)
        save()
        return item
    }

    func removeEmby(id: UUID) {
        embySources.removeAll { $0.id == id }
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
            let username = try await EmbyClient.validateUser(baseAddress: embySources[index].baseAddress,
                                                              token: token, userID: embySources[index].userID)
            try KeychainPasswordStore.setEmbyToken(token, for: id)
            embySources[index].username = username ?? embySources[index].username
            save()
            return true
        } catch {
            errorMessage = "无法更新 Emby 令牌：\(error.localizedDescription)"
            return false
        }
    }

    func updateEmbyLogin(id: UUID, username: String, password: String) async -> Bool {
        guard let source = embySources.first(where: { $0.id == id }),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "请输入 Emby 用户名。"
            return false
        }
        do {
            let login = try await EmbyClient.authenticate(baseAddress: source.baseAddress,
                                                           username: username, password: password)
            guard login.userID.caseInsensitiveCompare(source.userID) == .orderedSame else {
                errorMessage = "登录的 Emby 用户与此服务器原有用户不同，无法保留原播放记录。"
                return false
            }
            try KeychainPasswordStore.setEmbyToken(login.token, for: id)
            if let index = embySources.firstIndex(where: { $0.id == id }) {
                embySources[index].username = login.username
                embySources[index].usesTokenLogin = false
            }
            save()
            return true
        } catch {
            errorMessage = "Emby 重新登录失败：\(error.localizedDescription)"
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
        do {
            try await PlexClient.validate(baseAddress: normalized, token: token)
            guard !plexSources.contains(where: {
                $0.baseAddress == normalized && (try? KeychainPasswordStore.plexToken(for: $0.id)) == token
            }) else {
                errorMessage = "这个 Plex 连接已添加。"
                return false
            }
            var source = PlexSource(baseAddress: normalized)
            source.username = try? await PlexClient.accountName(token: token)
            try KeychainPasswordStore.setPlexToken(token, for: source.id)
            plexSources.append(source)
            save()
            return true
        } catch {
            errorMessage = "连接 Plex 失败：\(error.localizedDescription)"
            return false
        }
    }

    func resolveServerUsername(id: UUID) async {
        if let index = embySources.firstIndex(where: { $0.id == id }), embySources[index].username == nil,
           let token = try? KeychainPasswordStore.embyToken(for: id), !token.isEmpty,
           let username = try? await EmbyClient.validateUser(baseAddress: embySources[index].baseAddress,
                                                              token: token, userID: embySources[index].userID) {
            embySources[index].username = username
            save()
        } else if let index = jellyfinSources.firstIndex(where: { $0.id == id }),
                  jellyfinSources[index].username == nil,
                  let token = try? KeychainPasswordStore.jellyfinToken(for: id), !token.isEmpty,
                  let user = try? await JellyfinClient.currentUser(baseAddress: jellyfinSources[index].baseAddress,
                                                                    token: token) {
            jellyfinSources[index].username = user.name
            save()
        } else if let index = plexSources.firstIndex(where: { $0.id == id }), plexSources[index].username == nil,
                  let token = try? KeychainPasswordStore.plexToken(for: id), !token.isEmpty,
                  let username = try? await PlexClient.accountName(token: token) {
            plexSources[index].username = username
            save()
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

    func openPlexItem(sourceID: UUID, remote: PlexItem) -> MediaItem? {
        guard let partKey = remote.partKey else { return nil }
        if let existing = items.first(where: {
            if case .plexItem(let id, let key, _) = $0.location {
                return id == sourceID && key == remote.ratingKey
            }
            return false
        }) { return existing }
        var item = MediaItem(title: remote.title,
                             location: .plexItem(sourceID: sourceID, ratingKey: remote.ratingKey,
                                                 partKey: partKey), identity: remote.identity)
        item.duration = remote.duration.map { $0 / 1000 }
        item.position = (remote.viewOffset ?? 0) / 1000
        item.watched = (remote.viewCount ?? 0) > 0
        item.serverSummary = remote.summary
        item.serverPosterKey = remote.thumb
        items.insert(item, at: 0)
        save()
        return item
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
        guard let index = plexSources.firstIndex(where: { $0.id == id }), !token.isEmpty else { return false }
        do {
            try await PlexClient.validate(baseAddress: plexSources[index].baseAddress, token: token)
            let username = try? await PlexClient.accountName(token: token)
            if let current = plexSources[index].username, let username,
               current.caseInsensitiveCompare(username) != .orderedSame {
                errorMessage = "登录用户与原服务器用户不同，请新建一个连接。"
                return false
            }
            try KeychainPasswordStore.setPlexToken(token, for: id)
            plexSources[index].username = username ?? plexSources[index].username
            offlinePlexSources.remove(id)
            save()
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
            _ = try await CloudDriveClient.contents(source: source, token: access, directoryID: "")
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
            setFileSourceIncluded(false, id: source.id)
            save()
            return true
        } catch {
            errorMessage = "云盘连接失败：\(error.localizedDescription)"
            return false
        }
    }

    func scanCloud(id: UUID) {
        for scope in fileSources where scope.storageID == id && scope.enabled && !scope.needsConfirmation { scanFileScope(scope.id) }
    }

    func updateCloudToken(id: UUID, token: String) async -> Bool {
        guard let source = cloudSources.first(where: { $0.id == id }), !token.isEmpty else { return false }
        do {
            _ = try await CloudDriveClient.contents(source: source, token: token, directoryID: "")
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
            _ = try await CloudDriveClient.contents(source: source, token: token.accessToken, directoryID: "")
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
            try Task.checkCancellation()
            guard cloudSources.contains(where: { $0.id == source.id }) else { throw LibraryScopeError.unavailable }
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
                var item = MediaItem(title: parsed.title, location: location(path), identity: parsed.identity)
                item.catalogPath = displayPath(path)
                additions.append(item)
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

    /// Save observations from the active decoder; no background probing or network read.
    func recordPlaybackMedia(id: UUID, features: PlaybackMediaFeatures, duration: Double, streams: Data?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        switch items[index].location { case .embyItem, .jellyfinItem, .plexItem: return; default: break }
        let old = items[index].technicalInfo
        let dimensions = (features.resolution ?? "").split(whereSeparator: { $0 == "×" || $0 == "x" }).compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        let width = dimensions.count == 2 ? dimensions[0] : old?.width ?? 0
        let height = dimensions.count == 2 ? dimensions[1] : old?.height ?? 0
        guard width > 0, height > 0, let codec = features.videoCodec ?? old?.videoCodec else { return }
        var rows = (old.flatMap { try? JSONSerialization.jsonObject(with: $0.streamData) } as? [[String: Any]]) ?? []
        if let streams, let incoming = try? JSONSerialization.jsonObject(with: streams) as? [[String: Any]] {
            // Stream indices belong to a demuxer. Replace observed track types
            // on engine changes instead of accumulating AVTrack/FFmpeg IDs.
            let types = Set(incoming.compactMap { $0["Type"] as? String })
            let previous = rows
            rows.removeAll { types.contains($0["Type"] as? String ?? "") }
            for row in incoming {
                let key = "\(row["Type"] ?? ""):\(row["Index"] ?? 0)"
                if let i = rows.firstIndex(where: { "\($0["Type"] ?? ""):\($0["Index"] ?? 0)" == key }) {
                    rows[i].merge(row) { _, new in new }
                } else if let oldRow = previous.first(where: { "\($0["Type"] ?? ""):\($0["Index"] ?? 0)" == key }) {
                    rows.append(oldRow.merging(row) { _, new in new })
                } else { rows.append(row) }
            }
        }
        if let i = rows.firstIndex(where: { $0["Type"] as? String == "Video" }) {
            rows[i]["Codec"] = codec; rows[i]["Width"] = width; rows[i]["Height"] = height
            if let tag = features.videoCodecTag { rows[i]["CodecTag"] = tag }
        } else {
            var video: [String:Any] = ["Type":"Video","Index":0,"Codec":codec,"Width":width,"Height":height]
            video["CodecTag"] = features.videoCodecTag
            rows.insert(video, at:0)
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options:.sortedKeys) else { return }
        var info = LocalMediaTechnicalInfo(probedAt: old?.probedAt ?? Date(),
            duration: duration.isFinite && duration > 0 ? duration.rounded() : old?.duration ?? 0,
            container: features.container ?? old?.container, width:width, height:height, videoCodec:codec,
            dynamicRange: features.dynamicRange ?? old?.dynamicRange ?? "unknown", streamData:data)
        guard info != old else { return }
        info.probedAt = Date()
        items[index].technicalInfo = info
        items[index].technicalProbeError = nil
        if info.duration > 0 { items[index].duration = info.duration }
        save()
    }

    func updateProgress(id: UUID, position: Double, duration: Double?) {
        guard let index = items.firstIndex(where: { $0.id == id }), position.isFinite, position >= 0 else { return }
        let wasWatched = items[index].watched
        if let duration, duration.isFinite, duration > 0 {
            items[index].duration = duration
            if items[index].technicalInfo?.duration == 0 { items[index].technicalInfo?.duration = duration.rounded() }
        }
        switch PlaybackProgressPolicy.current.state(position: position, duration: items[index].duration) {
        case .unavailable: return // Wait for a duration; never replace a good checkpoint with loading clocks.
        case .beginning: items[index].position = 0
        case .resumable(let seconds): items[index].position = wasWatched ? 0 : seconds
        case .completed: items[index].position = 0; items[index].watched = true
        }
        if position > 0 { items[index].lastPlayedAt = Date() }
        items[index].stateUpdatedAt = Date()
        let justCompleted = !wasWatched && items[index].watched
        if justCompleted { markWatched(id: id) }
        if justCompleted || Date().timeIntervalSince(lastServerReport[id] ?? .distantPast) >= 10 {
            lastServerReport[id] = Date()
            reportServerProgress(item: items[index], stopped: false)
        }
        if let database {
            database.enqueueItem(items[index], profileID: activeProfileID) { [weak self] failure in
                Task { @MainActor in self?.errorMessage = "无法保存观看进度：\(failure)" }
            }
            scheduleSync()
        } else { save() }
    }

    func markUnwatched(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].position = 0
        items[index].watched = false
        items[index].stateUpdatedAt = Date()
        if isDefaultProfile, let key = Self.traktKey(for: items[index]) {
            pendingTraktUnwatched.insert(key)
        }
        reportServerProgress(item: items[index], stopped: true)
        save()
        scheduleTraktSync()
    }

    func markWatched(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].watched = true
        items[index].position = 0
        items[index].stateUpdatedAt = Date()
        if let key = Self.traktKey(for: items[index]) {
            pendingTraktUnwatched.remove(key)
        }
        reportServerProgress(item: items[index], stopped: true)
        save()
        scheduleTraktSync()
    }

    func toggleFavorite(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].favorite = !items[index].isFavorite
        items[index].favoriteUpdatedAt = Date()
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

    private func resumeServerStateSync() async {
        await serverOutbox.resume { [weak self] value in try await self?.deliverServerState(value) }
        guard isDefaultProfile else { return }
        // One-time migration of the pre-outbox restricted-network queue.
        // Keep its recovery key until the new queue has durably accepted every entry.
        let legacyKey = "lucent.network.pendingServerStates"
        guard let legacy = UserDefaults.standard.stringArray(forKey: legacyKey) else { return }
        do {
            for raw in legacy {
                guard let id = UUID(uuidString: raw), let item = items.first(where: { $0.id == id }) else { continue }
                let record = ServerStateOutbox.Record(item: item, stopped: true, revision: Date())
                try await serverOutbox.submit(record) { [weak self] value in try await self?.deliverServerState(value) }
            }
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } catch { errorMessage = "无法迁移待同步观看状态：\(error.localizedDescription)" }
    }

    private func reportServerProgress(item: MediaItem, stopped: Bool) {
        guard isDefaultProfile else { return }
        switch item.location { case .embyItem, .jellyfinItem, .plexItem: break; default: return }
        let record = ServerStateOutbox.Record(item: item, stopped: stopped, revision: Date())
        Task { [self] in
            do { try await serverOutbox.submit(record) { [weak self] value in try await self?.deliverServerState(value) } }
            catch { errorMessage = "无法保存待同步观看状态：\(error.localizedDescription)" }
        }
    }

    private func deliverServerState(_ record: ServerStateOutbox.Record) async throws {
        guard NetworkUsagePolicy.syncPermitted(on: NetworkUsagePolicy.shared.route, allowed: NetworkUsagePolicy.allowsSync) else { throw URLError(.notConnectedToInternet) }
        let item = record.item
        switch item.location {
        case .embyItem(let id, let remoteID):
            guard let source = embySources.first(where: { $0.id == id }) else { return }
            guard let token = try KeychainPasswordStore.embyToken(for: id) else { throw URLError(.userAuthenticationRequired) }
            try await EmbyClient.updateUserData(source: source, token: token, itemID: remoteID, position: item.position, played: item.watched)
        case .jellyfinItem(let id, let remoteID):
            guard let source = jellyfinSources.first(where: { $0.id == id }) else { return }
            guard let token = try KeychainPasswordStore.jellyfinToken(for: id) else { throw URLError(.userAuthenticationRequired) }
            try await JellyfinClient.updateUserData(source: source, token: token, itemID: remoteID, position: item.position, played: item.watched)
        case .plexItem(let id, let remoteID, _):
            guard let source = plexSources.first(where: { $0.id == id }) else { return }
            guard let token = try KeychainPasswordStore.plexToken(for: id) else { throw URLError(.userAuthenticationRequired) }
            try await PlexClient.markPlayed(source: source, token: token, ratingKey: remoteID, played: item.watched)
            try await PlexClient.reportProgress(source: source, token: token, ratingKey: remoteID, position: item.position, duration: item.duration, stopped: record.stopped)
        default: return
        }
    }

    func applyMetadata(id: UUID, title: String, metadata: MediaMetadata) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        if items[index].metadata?.posterPath != metadata.posterPath { clearPoster(index: index) }
        if items[index].identity?.seriesName == nil { items[index].title = title }
        items[index].metadata = metadata
        if let series = items[index].identity?.seriesName, localLibraryItems.contains(where: { $0.id == id }) {
            let groupIDs = Set(localLibraryItems.filter { $0.identity?.seriesName == series }.map(\.id))
            for sibling in items.indices where groupIDs.contains(items[sibling].id) {
                items[sibling].metadata = metadata
                items[sibling].metadataRetryAfter = nil
                items[sibling].catalogEpisode = nil
            }
        }
        items[index].metadataRetryAfter = nil
        items[index].catalogEpisode = nil
        items[index].stateUpdatedAt = Date()
        catalogMetadataCache.removeAll()
        save()
        scheduleMetadataEnrichment()
    }

    private var pendingCatalogItems: [MediaItem] {
        localLibraryItems.filter { item in
            item.missingSince == nil && (item.metadataRetryAfter ?? .distantPast) <= Date() &&
                (item.metadata?.catalogVersion != 2 || item.metadata?.originCountries == nil || (item.needsCatalogEpisode && item.catalogEpisode == nil))
        }
    }

    /// Refresh translations by stable TMDB identity; never rematch or clear user data.
    func refreshLocalizedMetadata() async {
        guard isDefaultProfile, !enrichingMetadata,
              let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else { return }
        let languageID = LocalizationPreferences.current.contentID
        let groups = Dictionary(grouping: localLibraryItems.filter {
            $0.missingSince == nil && $0.metadata != nil && ($0.metadata?.localizationKey != languageID || ($0.needsCatalogEpisode && $0.catalogEpisode?.localizationKey != languageID))
        }, by: { "\($0.metadata?.catalogKind?.rawValue ?? ($0.identity?.seriesName == nil ? "movie" : "tv")):\($0.metadata!.providerID)" })
        guard !groups.isEmpty else { return }
        enrichingMetadata = true
        defer { enrichingMetadata = false; catalogProcessingStatus = nil; save() }
        for files in groups.values {
            guard !Task.isCancelled, LocalizationPreferences.current.contentID == languageID,
                  let first = files.first, let old = first.metadata else { return }
            catalogProcessingStatus = "正在更新本地化资料：\(first.title)"
            do {
                let television = old.catalogKind == .tv || first.identity?.seriesName != nil
                let translated = try await TMDBService.catalog(id: old.providerID, television: television, token: token)
                guard !Task.isCancelled, LocalizationPreferences.current.contentID == languageID else { return }
                for file in files {
                    var episode: CatalogEpisode?
                    if case .episode(_, let season, let number, _) = file.identity, number > 0 {
                        episode = try? await TMDBService.catalogEpisode(id: old.providerID, season: season, number: number, token: token)
                    }
                    guard !Task.isCancelled, LocalizationPreferences.current.contentID == languageID else { return }
                    if let index = items.firstIndex(where: { $0.id == file.id && $0.metadata?.providerID == old.providerID }) {
                        items[index].metadata = translated
                        if let episode { items[index].catalogEpisode = episode }
                        if !television { items[index].title = translated.localizedTitle ?? items[index].title }
                    }
                }
                save()
                try await Task.sleep(for: .milliseconds(300))
            } catch { return } // Keep existing metadata on outage; a later refresh can retry.
        }
        catalogMetadataCache.removeAll()
        scheduleCatalogArtwork()
    }

    func enrichMissingMetadata(showResult: Bool = true) async {
        guard isDefaultProfile, !enrichingMetadata else { return }
        scheduleTechnicalProbes()
        let token: String
        do { token = try KeychainPasswordStore.metadataToken() ?? "" }
        catch { catalogProcessingStatus = "无法读取 TMDB 令牌"; return }
        guard !token.isEmpty else { catalogProcessingStatus = mediaProbeEnabled ? "请在设置中配置 TMDB 令牌，媒体探测仍会继续" : "请在设置中配置 TMDB 令牌"; return }
        enrichingMetadata = true
        metadataEnrichmentFailed = false
        defer { enrichingMetadata = false }
        var matched = 0
        let localizationID = LocalizationPreferences.current.contentID
        let recognizer = TMDBCatalogRecognizer(token: token)
        for item in Array(pendingCatalogItems.prefix(30)) {
            guard !Task.isCancelled, localLibraryItems.contains(where: { $0.id == item.id }),
                  let initial = items.firstIndex(where: { $0.id == item.id }),
                  (items[initial].metadataRetryAfter ?? .distantPast) <= Date() else { continue }
            let input = CatalogRecognitionInput(item: item)
            let query = input.names.first ?? item.title
            catalogProcessingStatus = "正在获取影片资料：\(query)"
            items[initial].metadataAttemptedAt = Date()
            do {
                let metadata: MediaMetadata
                if item.metadata?.catalogVersion == 2, item.metadata?.originCountries != nil, let value = item.metadata {
                    metadata = value
                } else {
                    guard let result = try await recognizer.recognize(input) else {
                        // A show's episodes share one lookup; never overwrite a manual match
                        // made while that request was suspended.
                        let activeIDs = Set(localLibraryItems.map(\.id))
                        for index in items.indices where activeIDs.contains(items[index].id) && items[index].metadata == nil && CatalogRecognitionInput(item: items[index]) == input {
                            items[index].metadataMatchStatus = "全部识别步骤均未匹配：\(query)"
                            items[index].metadataRetryAfter = Date().addingTimeInterval(86400)
                        }
                        continue
                    }
                    let lookup = "\(LocalizationPreferences.current.contentID)|\(result.kind.rawValue):\(result.id)"
                    if let cached = catalogMetadataCache[lookup] { metadata = cached }
                    else {
                        let value = try await TMDBService.catalog(id: result.id, television: result.kind == .tv, token: token)
                        catalogMetadataCache[lookup] = value
                        metadata = value
                    }
                }
                guard !Task.isCancelled, LocalizationPreferences.current.contentID == localizationID, localLibraryItems.contains(where: { $0.id == item.id }),
                      let index = items.firstIndex(where: { $0.id == item.id }),
                      items[index].metadata?.providerID == item.metadata?.providerID else { continue }
                let television = metadata.catalogKind == .tv || (metadata.catalogKind == nil && item.identity?.seriesName != nil)
                items[index].metadata = metadata
                items[index].metadataMatchStatus = "已匹配"
                if television, item.metadata == nil, item.catalogRecognitionIdentity.seriesName != nil {
                    items[index].identity = item.catalogRecognitionIdentity
                }
                if television && item.identity?.seriesName == nil {
                    items[index].identity = .episode(series: query, season: input.season ?? 1, number: 0, name: nil)
                }
                items[index].metadataRetryAfter = nil
                if !television { items[index].title = metadata.localizedTitle ?? items[index].title }
                // Original series names remain identity keys; localized titles are presentation metadata.
                if case .episode(_, let season, let number, _) = items[index].identity, number > 0, item.catalogEpisode == nil {
                    do {
                        let coordinates = try await recognizer.coordinates(group: input.episodeGroup, season: season, episode: number)
                        let episode = try await TMDBService.catalogEpisode(id: metadata.providerID, season: coordinates.season, number: coordinates.episode, token: token)
                        if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].catalogEpisode = episode }
                    } catch is CancellationError { throw CancellationError() }
                    catch {
                        if let index = items.firstIndex(where: { $0.id == item.id }) {
                            items[index].metadataRetryAfter = Date().addingTimeInterval(3600)
                            items[index].metadataMatchStatus = "剧集已匹配，单集资料获取失败"
                        }
                    }
                }
                matched += 1
                save()
                scheduleCatalogArtwork()
                try await Task.sleep(for: .milliseconds(300))
            } catch is CancellationError { break }
            catch {
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    items[index].metadataMatchStatus = "刮削失败，可重试"
                    items[index].metadataRetryAfter = Date().addingTimeInterval(900)
                }
                metadataEnrichmentFailed = true
                catalogProcessingStatus = "\(error.localizedDescription) 已保留文件和已有资料，可重试。"
                break
            }
        }
        save()
        if !metadataEnrichmentFailed, !Task.isCancelled { updateCatalogCompletionStatus() }
        if showResult { diagnosticMessage = "本批次已匹配 \(matched) 个文件。\(catalogProcessingStatus ?? "")" }
    }

    private func updateCatalogCompletionStatus() {
        let present = localLibraryItems.filter { $0.missingSince == nil }
        let unmatched = present.filter { $0.metadata == nil }
        let incomplete = present.filter { $0.metadata != nil && ($0.metadata?.catalogVersion != 2 || ($0.needsCatalogEpisode && $0.catalogEpisode == nil)) }.count
        let pending = pendingCatalogItems.count
        if pending > 0 {
            catalogProcessingStatus = "仍有 \(pending) 个文件等待刮削"
        } else if !unmatched.isEmpty {
            let titles = Set(unmatched.map { $0.identity?.seriesName ?? $0.title }).count
            catalogProcessingStatus = "本轮已结束，\(titles) 部影片/节目（\(unmatched.count) 个文件）仍未匹配；请检查名称或手动匹配，也可立即重试。"
        } else if incomplete > 0 {
            catalogProcessingStatus = "影片已匹配，\(incomplete) 个文件的详细资料未获取成功，可重试补全。"
        } else {
            catalogProcessingStatus = "影片资料获取完成，全部文件已匹配"
        }
    }

    private func scheduleCatalogArtwork() {
        guard catalogArtworkTask == nil else { return }
        catalogArtworkTask = Task {
            defer { catalogArtworkTask = nil }
            // Warm the first screen; further posters use the same persistent cache on demand.
            let urls = Set(localCatalogCards.prefix(24).compactMap { $0.metadata?.posterURL }).subtracting(warmedCatalogArtwork)
            for url in urls {
                guard !Task.isCancelled else { break }
                do {
                    _ = try await LocalMediaCache.shared.imageData(key: "tmdb|\(url.absoluteString)") {
                        var request = URLRequest(url: url); request.timeoutInterval = 12
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 15_000_000 else { throw URLError(.badServerResponse) }
                        return data
                    }
                    warmedCatalogArtwork.insert(url)
                } catch { /* Artwork failures never block catalog or technical indexing. */ }
            }
        }
    }

    private func scheduleMetadataEnrichment() {
        guard isDefaultProfile else { return }
        scheduleTechnicalProbes()
        scheduleCatalogArtwork()
        guard !metadataCoordinator.isRunning else { return }
        guard let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else {
            catalogProcessingStatus = mediaProbeEnabled ? "请在设置中配置 TMDB 令牌，媒体探测仍会继续" : "请在设置中配置 TMDB 令牌"; return
        }
        metadataCoordinator.start { [self] in
            while !Task.isCancelled {
                if enrichingMetadata { try? await Task.sleep(for: .milliseconds(500)); continue }
                if metadataRetryRequested {
                    metadataRetryRequested = false
                    resetLocalLibraryProcessingRetries()
                }
                let count = pendingCatalogItems.count
                guard count > 0 else { updateCatalogCompletionStatus(); break }
                await enrichMissingMetadata(showResult: false)
                // A retry requested during a suspended network request must run after that
                // batch, so the previous result cannot overwrite the reset cooldowns.
                if metadataRetryRequested { continue }
                if metadataEnrichmentFailed || pendingCatalogItems.count >= count { break }
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
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
        let route = NetworkUsagePolicy.shared.route
        guard route != .unknown, route != .cellular || NetworkUsagePolicy.allowsDownloads else { return }
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

    @discardableResult
    func installSubtitle(id: UUID, data: Data, filename: String) -> Bool {
        let suffix = (filename as NSString).pathExtension.lowercased()
        guard SubtitleParser.supportedExtensions.contains(suffix), data.count <= 5_000_000,
              let index = items.firstIndex(where: { $0.id == id }) else {
            errorMessage = "字幕格式无效或超过 5 MB。"
            return false
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
            return true
        } catch { errorMessage = "无法保存字幕：\(error.localizedDescription)"; return false }
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
        _ = await NetworkUsagePolicy.shared.readyRoute()
        do { try NetworkUsagePolicy.shared.requireDownloadAllowed() }
        catch { errorMessage = error.localizedDescription; return }
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
                do {
                    try await withTaskCancellationHandler { try await transfer.value } onCancel: { transfer.cancel() }
                } catch {
                    if error is NetworkUsageError { pausedSMBDownloads.insert(id) }
                    throw error
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
            if error is NetworkUsageError || (!NetworkUsagePolicy.allowsDownloads && NetworkUsagePolicy.shared.route == .cellular) {
                userPausedDownloadIDs.insert(id.uuidString)
                errorMessage = NetworkUsageError.downloadsRestricted.localizedDescription
            } else if !Task.isCancelled && !cancelledDownloads.contains(id) && !(error is CancellationError) {
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
        let route = await NetworkUsagePolicy.shared.readyRoute()
        guard NetworkUsagePolicy.syncPermitted(on: route, allowed: NetworkUsagePolicy.allowsSync) else {
            traktStatus = "等待 Wi-Fi 同步"; return
        }
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

    func updateSkipTimes(id: UUID, introEnd: Double?, creditsDuration: Double?, applyToSeason: Bool) {
        guard let target = items.first(where: { $0.id == id }) else { return }
        func source(_ location: MediaLocation) -> String {
            switch location {
            case .folderFile(let id, _): "folder:\(id)"
            case .smbFile(let id, _): "smb:\(id)"
            case .webDAVFile(let id, _): "dav:\(id)"
            case .embyItem(let id, _): "emby:\(id)"
            case .jellyfinItem(let id, _): "jellyfin:\(id)"
            case .plexItem(let id, _, _): "plex:\(id)"
            case .cloudFile(let id, _, _): "cloud:\(id)"
            case .remote, .bookmark: "local"
            }
        }
        for index in items.indices {
            let sameSeason: Bool
            if applyToSeason, case .episode(_, let season, _, _) = target.identity,
               case .episode(_, let candidateSeason, _, _) = items[index].identity {
                sameSeason = season == candidateSeason && target.catalogGroupID == items[index].catalogGroupID && source(target.location) == source(items[index].location)
            } else { sameSeason = false }
            guard items[index].id == id || sameSeason else { continue }
            items[index].skipIntroEnd = introEnd
            items[index].skipCreditsDuration = creditsDuration
            items[index].skipCreditsStart = nil
        }
        save()
    }

    func updateDetails(id: UUID, title: String, identity: MediaIdentity,
                       skipIntroEnd: Double? = nil, skipCreditsStart: Double? = nil) {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].title = value
        items[index].identity = identity
        items[index].skipIntroEnd = skipIntroEnd
        if items[index].skipCreditsStart != skipCreditsStart { items[index].skipCreditsDuration = nil }
        items[index].skipCreditsStart = skipCreditsStart
        items[index].stateUpdatedAt = Date()
        save()
    }

    func remove(id: UUID) {
        removeItemsAndAssets { $0.id == id }
        save()
    }

    func flushPersistence() async { await database?.flush() }

    private func save() {
        catalogStructureRevision = UUID()
        let currentNetworkConfiguration = networkConfiguration()
        if currentNetworkConfiguration != lastNetworkConfiguration {
            libraryConfigUpdatedAt = Date()
            lastNetworkConfiguration = currentNetworkConfiguration
        }
        if let database {
            database.enqueue(snapshot()) { [weak self] failure in
                Task { @MainActor in self?.errorMessage = "无法保存媒体库：\(failure)" }
            }
        } else {
            LibraryRepository.saveJSON(snapshot(), to: fileURL) { [weak self] failure in
                Task { @MainActor in self?.errorMessage = "无法保存媒体库：\(failure)" }
            }
        }
        if syncing { syncRequestedDuringRun = true }
        else { scheduleSync() }
    }

    private func networkConfiguration() -> NetworkSourceConfiguration {
        var smb = smbSources.filter { $0.syncAllowed != false }
        var webDAV = webDAVSources.filter { $0.syncAllowed != false }
        var jellyfin = jellyfinSources
        var emby = embySources
        var plex = plexSources
        var cloud = cloudSources
        var dlna = dlnaSources
        for index in smb.indices { smb[index].lastScannedAt = nil }
        for index in webDAV.indices { webDAV[index].lastScannedAt = nil }
        for index in jellyfin.indices { jellyfin[index].lastScannedAt = nil }
        for index in emby.indices { emby[index].lastScannedAt = nil }
        for index in plex.indices { plex[index].lastScannedAt = nil }
        for index in cloud.indices { cloud[index].lastScannedAt = nil }
        for index in dlna.indices { dlna[index].lastScannedAt = nil; dlna[index].mediaIDs = [] }
        return NetworkSourceConfiguration(smb: smb, webDAV: webDAV,
                                          jellyfin: jellyfin, emby: emby, plex: plex, cloud: cloud,
                                          dlna: dlna)
    }

    func syncNow() async {
        guard iCloudSyncEnabled, !syncing else { return }
        let route = await NetworkUsagePolicy.shared.readyRoute()
        guard NetworkUsagePolicy.syncPermitted(on: route, allowed: NetworkUsagePolicy.allowsSync) else {
            syncStatus = "等待 Wi-Fi 同步"; return
        }
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
            guard iCloudSyncEnabled, !Task.isCancelled else { return }
            var changed = false
            for index in items.indices {
                guard let key = CloudPlaybackSync.key(for: items[index], library: self),
                      let state = remote[key] else { continue }
                let favoriteDate = state.favoriteUpdatedAt ?? state.updatedAt
                if favoriteDate > (items[index].favoriteUpdatedAt ?? items[index].stateUpdatedAt ?? .distantPast) {
                    items[index].favorite = state.favorite
                    items[index].favoriteUpdatedAt = favoriteDate
                    changed = true
                }
                // A server owns playback progress; iCloud must not replace it.
                switch items[index].location {
                case .embyItem, .jellyfinItem, .plexItem: continue
                default: break
                }
                let playbackDate = state.playbackUpdatedAt ?? state.updatedAt
                guard playbackDate > (items[index].stateUpdatedAt ?? .distantPast) else { continue }
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
                items[index].stateUpdatedAt = playbackDate
                changed = true
            }
            let remoteConfiguration = try await CloudPlaybackSync.fetchConfiguration()
            guard iCloudSyncEnabled, !Task.isCancelled else { return }
            if let remoteConfiguration,
               remoteConfiguration.updatedAt > (libraryConfigUpdatedAt ?? .distantPast) {
                let allowedNames = Set(remoteConfiguration.collectionNames)
                collections.removeAll { !allowedNames.contains($0.name) }
                for name in remoteConfiguration.collectionNames where
                    !collections.contains(where: { $0.name == name }) {
                    collections.append(MediaCollection(name: name))
                }
                smartPlaylists = remoteConfiguration.smartPlaylists
                if let preferences = remoteConfiguration.preferences {
                    CloudUserPreferences.apply(preferences)
                    lastUserPreferences = CloudUserPreferences.capture()
                }
                if let sources = remoteConfiguration.networkSources {
                    let localSMB = smbSources.filter { $0.syncAllowed == false }
                    let localWebDAV = webDAVSources.filter { $0.syncAllowed == false }
                    smbSources = sources.smb.filter { remote in !localSMB.contains { $0.id == remote.id } } + localSMB
                    webDAVSources = sources.webDAV.filter { remote in !localWebDAV.contains { $0.id == remote.id } } + localWebDAV
                    jellyfinSources = sources.jellyfin
                    embySources = sources.emby
                    plexSources = sources.plex
                    cloudSources = sources.cloud
                    if let dlna = sources.dlna { dlnaSources = dlna }
                    lastNetworkConfiguration = networkConfiguration()
                }
                libraryConfigUpdatedAt = remoteConfiguration.updatedAt
                changed = true
            }
            if changed { save() }
            var uploads: [CloudPlaybackState] = []
            for item in items {
                guard let key = CloudPlaybackSync.key(for: item, library: self),
                      let updatedAt = [item.stateUpdatedAt, item.favoriteUpdatedAt].compactMap({ $0 }).max(),
                      updatedAt > (remote[key]?.updatedAt ?? .distantPast) else { continue }
                uploads.append(CloudPlaybackState(
                    key: key, updatedAt: updatedAt, favorite: item.isFavorite,
                    watched: item.watched, position: item.position, duration: item.duration,
                    title: item.title, metadata: item.metadata,
                    collectionNames: collections.filter { $0.itemIDs.contains(item.id) }.map(\.name),
                    favoriteUpdatedAt: item.favoriteUpdatedAt,
                    playbackUpdatedAt: item.stateUpdatedAt
                ))
            }
            if !uploads.isEmpty { try await CloudPlaybackSync.saveMany(uploads) }
            if libraryConfigUpdatedAt == nil,
               !collections.isEmpty || !smartPlaylists.isEmpty ||
               !smbSources.isEmpty || !webDAVSources.isEmpty || !jellyfinSources.isEmpty ||
               !embySources.isEmpty || !plexSources.isEmpty || !cloudSources.isEmpty ||
               !dlnaSources.isEmpty || !lastUserPreferences.isEmpty {
                libraryConfigUpdatedAt = Date()
                save()
            }
            if let libraryConfigUpdatedAt,
               libraryConfigUpdatedAt > (remoteConfiguration?.updatedAt ?? .distantPast) {
                try await CloudPlaybackSync.saveConfiguration(
                    CloudLibraryConfiguration(updatedAt: libraryConfigUpdatedAt,
                                              collectionNames: collections.map(\.name),
                                              smartPlaylists: smartPlaylists,
                                              networkSources: networkConfiguration(),
                                              preferences: CloudUserPreferences.capture()))
            }
            syncStatus = String.lucentFormat("上次同步：%@", Date().lucentFormatted())
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

// MARK: - Aggregate library: storage connections and independent directory scopes
extension LibraryStore {
    var libraryStorages: [LibraryStorage] {
        folders.map { .init(id: $0.id, name: $0.name, subtitle: "本地文件夹", kind: .local) } +
        smbSources.map { .init(id: $0.id, name: $0.name, subtitle: "SMB · \($0.host)/\($0.share)", kind: .smb) } +
        webDAVSources.map { .init(id: $0.id, name: $0.name, subtitle: "WebDAV", kind: .webDAV) } +
        cloudSources.map { .init(id: $0.id, name: $0.name, subtitle: $0.provider.title, kind: .cloud) } +
        dlnaSources.map { .init(id: $0.id, name: $0.name, subtitle: "DLNA", kind: .dlna) }
    }

    private func migrateLegacyFileSourcesIfNeeded() {
        // Snapshot presence is the migration marker; an intentionally empty list stays empty.
        guard let stored = try? database?.load(), stored.fileSources == nil else { return }
        for storage in libraryStorages {
            let excluded = excludedFileSourceIDs.contains(storage.id)
            let ids = Set(items.filter { legacyStorageID(for: $0) == storage.id }.map(\.id))
            var scope = LibraryFileSource(storageID: storage.id, name: storage.name, directoryID: "", path: "")
            scope.enabled = !excluded
            scope.needsConfirmation = excluded
            scope.itemIDs = ids
            scope.lastScannedAt = folders.first { $0.id == storage.id }?.lastScannedAt ??
                smbSources.first { $0.id == storage.id }?.lastScannedAt ??
                webDAVSources.first { $0.id == storage.id }?.lastScannedAt ??
                cloudSources.first { $0.id == storage.id }?.lastScannedAt ??
                dlnaSources.first { $0.id == storage.id }?.lastScannedAt
            scope.importedAt = scope.lastScannedAt
            fileSources.append(scope)
        }
        save()
    }

    private func legacyStorageID(for item: MediaItem) -> UUID? {
        switch item.location {
        case .folderFile(let id, _), .smbFile(let id, _), .webDAVFile(let id, _), .cloudFile(let id, _, _): return id
        case .remote: return dlnaSources.first { $0.mediaIDs.contains(item.id) }?.id
        default: return nil
        }
    }

    func storageContents(_ storageID: UUID, directory: StorageDirectory = .root) async throws -> [StorageDirectory] {
        do {
            let result = try await readStorageContents(storageID, directory: directory)
            storageConnectionStates[storageID] = "可访问"
            return result
        } catch is CancellationError { throw CancellationError() }
        catch { storageConnectionStates[storageID] = "连接失败"; throw error }
    }

    private func readStorageContents(_ storageID: UUID, directory: StorageDirectory) async throws -> [StorageDirectory] {
        try Task.checkCancellation()
        let entries: [StorageDirectory]
        #if !os(tvOS)
        if let source = folders.first(where: { $0.id == storageID }) {
            let path = directory.identifier
            let values = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.contents(bookmark: source.bookmark, relativePath: path)
            }.value
            entries = values.map { .init(identifier: $0.relativePath, name: $0.name, path: $0.relativePath, isDirectory: $0.isDirectory) }
            return entries.sorted { a, b in
                if a.isDirectory != b.isDirectory { return a.isDirectory }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        }
        #endif
        if let source = smbSources.first(where: { $0.id == storageID }) {
            let password = try KeychainPasswordStore.get(for: storageID) ?? ""
            let path = directory.identifier
            let values = try await Task.detached(priority: .userInitiated) {
                try SMBScanner.contents(source: source, password: password, path: path)
            }.value
            entries = values.map { .init(identifier: $0.path, name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }
        } else if let source = webDAVSources.first(where: { $0.id == storageID }) {
            let password = try KeychainPasswordStore.webDAVPassword(for: storageID) ?? ""
            entries = try await WebDAVClient.contents(source: source, password: password, path: directory.identifier)
                .map { .init(identifier: $0.path, name: $0.name, path: $0.path, isDirectory: $0.isDirectory) }
        } else if let source = cloudSources.first(where: { $0.id == storageID }) {
            let token = try await validCloudToken(source: source)
            entries = try await CloudDriveClient.contents(source: source, token: token, directoryID: directory.identifier)
                .map { .init(identifier: $0.identifier, name: $0.name,
                             path: [directory.path, $0.name].filter { !$0.isEmpty }.joined(separator: "/"), isDirectory: $0.isDirectory) }
        } else if let source = dlnaSources.first(where: { $0.id == storageID }), let url = URL(string: source.descriptionAddress) {
            let device = try await DLNAClient.connect(descriptionURL: url)
            entries = try await DLNAClient.contents(device: device, objectID: directory.identifier)
                .map { .init(identifier: $0.identifier, name: $0.name,
                             path: [directory.path, $0.name].filter { !$0.isEmpty }.joined(separator: "/"),
                             isDirectory: $0.isDirectory, playbackURL: $0.playbackURL) }
        } else { throw LibraryScopeError.unavailable }
        try Task.checkCancellation()
        return entries.sorted { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    func scopeOverlap(storageID: UUID, directory: StorageDirectory) -> LibraryFileSource? {
        fileSources.first { $0.storageID == storageID && ($0.directoryID == directory.identifier || LibraryScopePath.overlaps($0.path, directory.path)) }
    }

    func importDirectories(storageID: UUID, directories: [(StorageDirectory, String)], scanImmediately: Bool) async throws {
        guard libraryStorages.contains(where: { $0.id == storageID }), !directories.isEmpty else { throw LibraryScopeError.unavailable }
        var additions: [LibraryFileSource] = []
        for (directory, name) in directories {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard directory.isDirectory, !name.isEmpty, !directory.path.split(separator: "/").contains("..") else { throw LibraryScopeError.invalidDirectory }
            if let existing = scopeOverlap(storageID: storageID, directory: directory) { throw LibraryScopeError.overlap(existing.name) }
            if let existing = additions.first(where: { $0.directoryID == directory.identifier || LibraryScopePath.overlaps($0.path, directory.path) }) { throw LibraryScopeError.overlap(existing.name) }
            additions.append(.init(storageID: storageID, name: name, directoryID: directory.identifier, path: directory.path))
        }
        let original = fileSources
        fileSources.append(contentsOf: additions)
        do {
            if let database { try await database.saveAsync(snapshot()) }
            else { try JSONEncoder().encode(snapshot()).write(to: fileURL, options: .atomic) }
        } catch { fileSources = original; throw error }
        if scanImmediately { for source in additions { scanFileScope(source.id) } }
    }

    func removeFileScope(_ id: UUID) {
        cancelScopeScan(id)
        fileSources.removeAll { $0.id == id }
        scopeScanStates.removeValue(forKey: id)
        // Keep MediaItem IDs, playback history and downloads. Membership controls visibility.
        save()
    }

    func removeLibraryStorage(_ id: UUID) {
        for scope in fileSources.filter({ $0.storageID == id }) { removeFileScope(scope.id) }
        folders.removeAll { $0.id == id }
        smbSources.removeAll { $0.id == id }
        webDAVSources.removeAll { $0.id == id }
        cloudSources.removeAll { $0.id == id }
        cloudRefreshTasks.removeValue(forKey: id)?.cancel()
        UserDefaults.standard.removeObject(forKey: "lucent.cloud.expiry.\(id.uuidString)")
        storageConnectionStates.removeValue(forKey: id)
        // Preserve old DLNA ownership until remote item membership is recorded.
        if let source = dlnaSources.first(where: { $0.id == id }) {
            for itemID in source.mediaIDs { storageFileIdentities["\(id.uuidString):legacy:\(itemID.uuidString)"] = itemID }
        }
        dlnaSources.removeAll { $0.id == id }
        KeychainPasswordStore.remove(for: id)
        KeychainPasswordStore.removeWebDAVPassword(for: id)
        KeychainPasswordStore.removeCloudToken(for: id)
        KeychainPasswordStore.removeCloudRefreshToken(for: id)
        KeychainPasswordStore.removeCloudClientSecret(for: id)
        save()
    }

    func renameLibraryStorage(_ id: UUID, name: String) {
        if let index = dlnaSources.firstIndex(where: { $0.id == id }) {
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { dlnaSources[index].name = name; save() }
        } else { renameFileSource(id: id, name: name) }
    }

    func scannedStorageItem(storageID: UUID, entry: StorageDirectory) -> MediaItem? {
        guard !entry.isDirectory else { return nil }
        let key = storageID.uuidString + ":" + entry.identifier
        if let id = storageFileIdentities[key], let index = items.firstIndex(where: { $0.id == id }) {
            if let url = entry.playbackURL { items[index].location = .remote(url) }
            return items[index]
        }
        let item: MediaItem?
        if cloudSources.contains(where: { $0.id == storageID }) {
            item = items.first { value in
                if case .cloudFile(let id, let identifier, _) = value.location { return id == storageID && identifier == entry.identifier }
                return false
            } ?? {
                let parsed = MediaNameParser.parse(relativePath: entry.path)
                let value = MediaItem(title: parsed.title, location: .cloudFile(sourceID: storageID, identifier: entry.identifier, filename: entry.name), identity: parsed.identity)
                items.append(value); return value
            }()
        } else if let url = entry.playbackURL {
            item = items.first { $0.location == .remote(url) } ?? {
                let parsed = MediaNameParser.parse(filename: entry.name)
                let value = MediaItem(title: parsed.title, location: .remote(url), identity: parsed.identity)
                items.append(value); return value
            }()
        } else { item = browsedFileItem(sourceID: storageID, path: entry.identifier) }
        if let item { storageFileIdentities[key] = item.id; save() }
        return item
    }

    /// Build lookup tables once and publish one batch, rather than saving/rebuilding
    /// the entire media index for each file in a large NAS directory.
    private func reconcileScopeFiles(storageID: UUID, entries: [StorageDirectory]) -> Set<UUID> {
        var updated = items
        var identities = storageFileIdentities
        var byID = Dictionary(uniqueKeysWithValues: updated.enumerated().map { ($0.element.id, $0.offset) })
        var legacy: [String: UUID] = [:]
        for item in updated {
            switch item.location {
            case .folderFile(let id, let path), .smbFile(let id, let path), .webDAVFile(let id, let path):
                if id == storageID { legacy[path] = item.id }
            case .cloudFile(let id, let identifier, _):
                if id == storageID { legacy[identifier] = item.id }
            case .remote(let url): legacy[url.absoluteString] = item.id
            default: break
            }
        }
        var result = Set<UUID>()
        for entry in entries {
            let key = storageID.uuidString + ":" + entry.identifier
            let existing = identities[key] ?? legacy[entry.identifier] ?? entry.playbackURL.flatMap { legacy[$0.absoluteString] }
            if let existing, let index = byID[existing] {
                if let url = entry.playbackURL { updated[index].location = .remote(url) }
                updated[index].missingSince = nil
                updated[index].catalogPath = entry.path
                identities[key] = existing; result.insert(existing)
                continue
            }
            let location: MediaLocation
            if folders.contains(where: { $0.id == storageID }) { location = .folderFile(sourceID: storageID, relativePath: entry.identifier) }
            else if smbSources.contains(where: { $0.id == storageID }) { location = .smbFile(sourceID: storageID, relativePath: entry.identifier) }
            else if webDAVSources.contains(where: { $0.id == storageID }) { location = .webDAVFile(sourceID: storageID, relativePath: entry.identifier) }
            else if cloudSources.contains(where: { $0.id == storageID }) { location = .cloudFile(sourceID: storageID, identifier: entry.identifier, filename: entry.name) }
            else if let url = entry.playbackURL { location = .remote(url) }
            else { continue }
            let parsed = MediaNameParser.parse(relativePath: entry.path)
            var item = MediaItem(title: parsed.title, location: location, identity: parsed.identity)
            item.catalogPath = entry.path
            byID[item.id] = updated.count
            updated.append(item)
            identities[key] = item.id; result.insert(item.id)
        }
        storageFileIdentities = identities
        items = updated
        return result
    }

    func stopFileScopeScan(_ id: UUID) { cancelScopeScan(id); save(); pumpScopeScans() }

    private func cancelScopeScan(_ id: UUID) {
        scanCoordinator.cancel(id)
        scopeScanStates[id] = "已停止"
    }

    func scanFileScope(_ id: UUID) {
        guard fileSources.contains(where: { $0.id == id && $0.enabled && !$0.needsConfirmation }),
              !pendingScopeScans.contains(id) else { return }
        if let task = scopeScanTasks[id], !task.isCancelled { return }
        pendingScopeScans.append(id)
        scopeScanStates[id] = "等待扫描"
        save()
        pumpScopeScans()
    }

    private func updateScanProgress(id: UUID, count: Int) {
        scopeScanStates[id] = "已发现 \(count) 个视频"
    }

    private func pumpScopeScans() {
        pendingScopeScans.removeAll { id in !fileSources.contains { $0.id == id && $0.enabled && !$0.needsConfirmation } }
        let occupied = Set(fileSources.filter { scopeScanTasks[$0.id] != nil }.map(\.storageID))
        guard scopeScanTasks.count < scanCoordinator.concurrency,
              let next = pendingScopeScans.firstIndex(where: { id in
                  fileSources.contains { $0.id == id && $0.enabled && !occupied.contains($0.storageID) }
              }) else { return }
        let id = pendingScopeScans.remove(at: next)
        guard let scope = fileSources.first(where: { $0.id == id }) else { return }
        scopeScanStates[id] = "正在读取目录"
        scopeScanTasks[id] = Task { [self] in
            defer {
                scopeScanTasks.removeValue(forKey: id)
                save()
                pumpScopeScans()
            }
            do {
                let root = StorageDirectory(identifier: scope.directoryID, name: scope.name, path: scope.path, isDirectory: true)
                let files = try await LibraryScanCoordinator.discover(root: root, read: { [weak self] current in
                    guard let self else { throw CancellationError() }
                    return try await self.storageContents(scope.storageID, directory: current)
                }, progress: { [weak self] count in
                    await self?.updateScanProgress(id: id, count: count)
                })
                try Task.checkCancellation()
                guard let index = fileSources.firstIndex(where: { $0.id == id && $0.enabled }) else { return }
                // Reconciliation starts only after a complete successful traversal.
                let previousIDs = fileSources[index].itemIDs
                let foundIDs = reconcileScopeFiles(storageID: scope.storageID, entries: files)
                var reconciled = items
                for itemIndex in reconciled.indices {
                    if foundIDs.contains(reconciled[itemIndex].id) { reconciled[itemIndex].missingSince = nil }
                    else if previousIDs.contains(reconciled[itemIndex].id) { reconciled[itemIndex].missingSince = reconciled[itemIndex].missingSince ?? Date() }
                }
                items = reconciled
                fileSources[index].itemIDs = foundIDs.union(previousIDs)
                fileSources[index].lastScannedAt = Date()
                scopeScanStates[id] = "扫描完成"
                save()
                scheduleMetadataEnrichment()
            } catch is CancellationError {
                if fileSources.contains(where: { $0.id == id }) { scopeScanStates[id] = "已停止" }
            } catch {
                if fileSources.contains(where: { $0.id == id }) { scopeScanStates[id] = "失败：\(error.localizedDescription)" }
            }
        }
        pumpScopeScans()
    }
}

extension LibraryStore {
    var pendingTechnicalItems: [MediaItem] {
        localLibraryItems.filter { $0.missingSince == nil && $0.technicalInfo == nil &&
            ($0.technicalProbeAttemptedAt ?? .distantPast) < Date().addingTimeInterval(-3600) }
    }

    func setMediaProbeEnabled(_ enabled: Bool) {
        guard mediaProbeEnabled != enabled else { return }
        mediaProbeEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "lucent.library.mediaProbeEnabled")
        if catalogProcessingStatus?.hasPrefix("请在设置中配置 TMDB 令牌") == true {
            catalogProcessingStatus = enabled ? "请在设置中配置 TMDB 令牌，媒体探测仍会继续" : "请在设置中配置 TMDB 令牌"
        }
        if !enabled {
            // LocalLibraryProbe forwards task cancellation to FFmpeg's ProbeCancellation.
            technicalProbeTask?.cancel()
            processingItemTitle = nil
        } else {
            let previous = technicalProbeTask
            Task {
                // A quick off/on must wait for the previous reader and proxy to close.
                await previous?.value
                guard mediaProbeEnabled else { return }
                scheduleTechnicalProbes()
            }
        }
    }

    private func resetInterruptedProbe(_ id: UUID) {
        if let index = items.firstIndex(where: { $0.id == id }), items[index].technicalInfo == nil {
            items[index].technicalProbeAttemptedAt = nil
        }
        save()
    }

    private func scheduleTechnicalProbes() {
        guard isDefaultProfile, mediaProbeEnabled, technicalProbeTask == nil else { return }
        technicalProbeTask = Task {
            defer { technicalProbeTask = nil; processingItemTitle = nil }
            while mediaProbeEnabled && !Task.isCancelled, let item = pendingTechnicalItems.first {
                guard let index = items.firstIndex(where: { $0.id == item.id }) else { break }
                items[index].technicalProbeAttemptedAt = Date()
                processingItemTitle = item.catalogDisplayTitle
                save()
                do {
                    let info = try await probeLibraryItem(item)
                    guard mediaProbeEnabled, !Task.isCancelled else { resetInterruptedProbe(item.id); break }
                    guard localLibraryItems.contains(where: { $0.id == item.id }),
                          let index = items.firstIndex(where: { $0.id == item.id }) else { continue }
                    items[index].technicalInfo = info
                    items[index].technicalProbeError = nil
                    if info.duration.isFinite && info.duration > 0 { items[index].duration = info.duration }
                } catch is CancellationError { resetInterruptedProbe(item.id); break }
                catch {
                    guard mediaProbeEnabled, !Task.isCancelled else { resetInterruptedProbe(item.id); break }
                    if let index = items.firstIndex(where: { $0.id == item.id }) {
                        items[index].technicalProbeError = PlaybackDiagnosticPrivacy.removingMediaURLs(from: error.localizedDescription)
                    }
                }
                save()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func probeLibraryItem(_ item: MediaItem) async throws -> LocalMediaTechnicalInfo {
        var server: RangeHTTPServer?
        var securityRoot: URL?
        defer { server?.stop(); securityRoot?.stopAccessingSecurityScopedResource() }
        let url: URL
        let container: String?
        if let downloaded = downloadedURL(for: item) {
            url = downloaded; container = downloaded.pathExtension
        } else {
            switch item.location {
            case .remote(let remote): url = remote; container = remote.pathExtension
            #if !os(tvOS)
            case .bookmark(let data):
                let root = try resolveBookmark(data)
                guard root.startAccessingSecurityScopedResource() else { throw LibraryScopeError.unavailable }
                securityRoot = root; url = root; container = root.pathExtension
            case .folderFile(let id, let path):
                guard let source = folders.first(where: { $0.id == id }), !path.split(separator: "/").contains("..") else { throw LibraryScopeError.unavailable }
                let root = try resolveBookmark(source.bookmark)
                guard root.startAccessingSecurityScopedResource() else { throw LibraryScopeError.unavailable }
                securityRoot = root; url = root.appendingPathComponent(path); container = url.pathExtension
            #endif
            case .smbFile(let id, let path):
                guard let source = smbSources.first(where: { $0.id == id }) else { throw LibraryScopeError.unavailable }
                let proxy = RangeHTTPServer(source: source, password: try KeychainPasswordStore.get(for: id), path: path)
                server = proxy; url = try await proxy.start(); container = (path as NSString).pathExtension
            case .webDAVFile(let id, let path):
                guard let source = webDAVSources.first(where: { $0.id == id }) else { throw LibraryScopeError.unavailable }
                let password = try KeychainPasswordStore.webDAVPassword(for: id)
                let proxy = RangeHTTPServer(fileExtension: (path as NSString).pathExtension, maxReadAttempts: 1,
                    readRange: { offset, length in
                        try WebDAVClient.readRange(source: source, password: password, path: path, offset: offset, length: length)
                    })
                server = proxy; url = try await proxy.start(); container = (path as NSString).pathExtension
            case .cloudFile(let id, let identifier, let filename):
                guard let source = cloudSources.first(where: { $0.id == id }) else { throw LibraryScopeError.unavailable }
                let token = try await validCloudToken(source: source)
                let proxy = RangeHTTPServer(fileExtension: (filename as NSString).pathExtension,
                    asyncReadRange: { offset, length in
                        try await CloudDriveClient.readRangeAsync(source: source, token: token, identifier: identifier, offset: offset, length: length)
                    })
                server = proxy; url = try await proxy.start(); container = (filename as NSString).pathExtension
            default: throw LibraryScopeError.unavailable
            }
        }
        if ["strm", "m3u", "m3u8"].contains(container?.lowercased() ?? ""), url.isFileURL {
            guard let target = try PlaylistResolver.entries(in: url).first?.url else { throw LibraryScopeError.invalidDirectory }
            return try await LocalLibraryProbe.read(url: target, container: target.pathExtension)
        }
        return try await LocalLibraryProbe.read(url: url, container: container)
    }

    func retryLocalLibraryProcessing() {
        guard isDefaultProfile else {
            catalogProcessingStatus = "请切换到主用户后重试获取影片资料"
            return
        }
        if metadataCoordinator.isRunning || enrichingMetadata {
            metadataRetryRequested = true
            catalogProcessingStatus = "已安排重试，将在当前批次结束后重新获取未完成的资料"
        } else {
            resetLocalLibraryProcessingRetries()
            catalogProcessingStatus = "正在准备重新获取未完成的资料"
        }
        scheduleMetadataEnrichment()
    }

    private func resetLocalLibraryProcessingRetries() {
        let active = Set(localLibraryItems.map(\.id))
        for index in items.indices where active.contains(items[index].id) {
            items[index].metadataRetryAfter = nil
            if items[index].technicalInfo == nil { items[index].technicalProbeAttemptedAt = nil }
        }
        catalogMetadataCache.removeAll()
        save()
    }

    var localCatalogCards: [MediaItem] { LocalCatalogIndex(files: localLibraryItems).cards }

}
