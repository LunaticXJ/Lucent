import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers

struct LibraryView: View {
    private enum SortOrder { case newest, title }
    private enum MediaFilter { case all, unwatched, favorites }
    #if os(iOS)
    private enum MobileTab { case home, sources, search }
    @State private var mobileTab: MobileTab = .home
    #endif
    #if os(tvOS)
    @State private var tvShowLibrary = false
    #endif
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var smbDiscovery = SMBDiscovery()
    @State private var search = ""
    @State private var address = ""
    @State private var showAddAddress = false
    @State private var showFileImporter = false
    @State private var showFolderImporter = false
    @State private var showBrowserUpload = false
    @State private var browserUploadURL: URL?
    @State private var browserUploadServer: BrowserUploadServer?
    @State private var showSMB = false
    @State private var showWebDAV = false
    @State private var webDAVIs123Pan = false
    @State private var showJellyfin = false
    @State private var showEmby = false
    @State private var showPlex = false
    @State private var showCloud = false
    @State private var showDLNA = false
    @State private var showNetworkFolder = false
    @State private var networkFolderAddress = ""
    @State private var networkFolderUsername = ""
    @State private var networkFolderPassword = ""
    @State private var editingNetworkFolder: VLCNetworkSource?
    @State private var scanningNetworkFolder = false
    @State private var networkFolderMessage: String?
    @State private var dlnaAddress = ""
    @State private var scanningDLNA = false
    @State private var dlnaMessage: String?
    @State private var dlnaDevices: [DLNAClient.Device] = []
    @State private var discoveringDLNA = false
    @State private var cloudProvider: CloudProvider = .dropbox
    @State private var cloudName = ""
    @State private var cloudToken = ""
    @State private var cloudClientID = ""
    @State private var cloudRefreshToken = ""
    @State private var cloudClientSecret = ""
    @State private var baiduDeviceCode: CloudTokenRefresher.BaiduDeviceCode?
    @State private var open115Authorization: CloudTokenRefresher.Open115Authorization?
    @State private var dropboxAuthorization: CloudTokenRefresher.Authorization?
    @State private var dropboxAuthorizationCode = ""
    @State private var dropboxAuthorizationMessage: String?
    @State private var addingCloud = false
    @State private var editingCloud: CloudSource?
    @State private var plexAddress = ""
    @State private var plexToken = ""
    @State private var plexPIN: PlexPIN?
    @State private var plexAuthTask: Task<Void, Never>?
    @State private var requestingPlexPIN = false
    @State private var addingPlex = false
    @State private var jellyfinAddress = ""
    @State private var jellyfinToken = ""
    @State private var jellyfinUsername = ""
    @State private var jellyfinPassword = ""
    @State private var jellyfinUsesToken = false
    @State private var addingJellyfin = false
    @State private var embyAddress = ""
    @State private var embyToken = ""
    @State private var embyUserID = ""
    @State private var embyUsername = ""
    @State private var embyPassword = ""
    @State private var embyUsesToken = false
    @State private var addingEmby = false
    @State private var webDAVAddress = ""
    @State private var webDAVUsername = ""
    @State private var webDAVPassword = ""
    @State private var editingWebDAV: WebDAVSource?
    @State private var editedWebDAVUsername = ""
    @State private var editedWebDAVPassword = ""
    @State private var replaceWebDAVPassword = false
    @State private var showAddCollection = false
    @State private var showAddSmartPlaylist = false
    @State private var collectionName = ""
    @State private var smartName = ""
    @State private var smartTitle = ""
    @State private var smartSeries = ""
    @State private var smartFavorites = false
    @State private var smartUnwatched = false
    @State private var smartRecentDays = 0
    @State private var smartMinimumRating = 0.0
    @State private var showProfiles = false
    @State private var showTrakt = false
    @State private var traktClientID = UserDefaults.standard.string(forKey: "lucent.trakt.clientID") ?? ""
    @State private var traktClientSecret = ""
    @State private var traktDeviceCode: TraktClient.DeviceCode?
    @State private var traktAuthTask: Task<Void, Never>?
    @State private var traktMessage: String?
    @State private var showProfileUnlock = false
    @State private var pendingProfileID: UUID?
    @State private var profileUnlockPIN = ""
    @State private var newProfileName = ""
    @State private var newProfileIsChild = false
    @State private var newProfilePIN = ""
    @State private var smbHost = ""
    @State private var smbShare = ""
    @State private var smbUsername = ""
    @State private var smbPassword = ""
    @State private var editingSMB: SMBSource?
    @State private var editingJellyfin: JellyfinSource?
    @State private var editingEmby: EmbySource?
    @State private var browsingEmby: EmbySource?
    @State private var editingPlex: PlexSource?
    @State private var replacementToken = ""
    @State private var replacingToken = false
    @State private var editedSMBUsername = ""
    @State private var editedSMBPassword = ""
    @State private var replaceSMBPassword = false
    @State private var selectedItem: MediaItem?
    @State private var editingItem: MediaItem?
    @State private var sortOrder: SortOrder = .newest
    @State private var mediaFilter: MediaFilter = .all

    private var filtered: [MediaItem] {
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let available = library.visibleItems.filter { item in
            if case .embyItem = item.location {
                return library.downloadedURL(for: item) != nil
            }
            return item.missingSince == nil || library.downloadedURL(for: item) != nil
        }
        let searched = term.isEmpty ? available : available.filter {
            $0.title.localizedCaseInsensitiveContains(term) ||
            ($0.identity?.seriesName?.localizedCaseInsensitiveContains(term) ?? false)
        }
        let candidates: [MediaItem]
        switch mediaFilter {
        case .all: candidates = searched
        case .unwatched: candidates = searched.filter { !$0.watched }
        case .favorites: candidates = searched.filter(\.isFavorite)
        }
        switch sortOrder {
        case .newest: return candidates.sorted { $0.addedAt > $1.addedAt }
        case .title: return candidates.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    var body: some View {
        Group {
            #if os(iOS)
            mobileShell
            #elseif os(tvOS)
            if tvShowLibrary {
                navigationBody
            } else {
                TVHomeView(showLibrary: { tvShowLibrary = true })
                    .environmentObject(library)
            }
            #else
            navigationBody
            #endif
        }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    library.refreshFolders()
                    Task { await library.syncNow() }
                } else {
                    #if !os(tvOS)
                    if showBrowserUpload { showBrowserUpload = false; stopBrowserUpload() }
                    #endif
                }
            }
            .task {
                library.restoreInterruptedDownloads()
                library.refreshFolders()
                await library.syncNow()
                library.scheduleTraktSync()
            }
    }

    #if os(iOS)
    private var mobileShell: some View {
        Group {
            switch mobileTab {
            case .home:
                MobileHomeView(showSources: { mobileTab = .sources })
                    .environmentObject(library)
            case .sources:
                navigationBody
            case .search:
                MobileSearchView().environmentObject(library)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            HStack(spacing: 2) {
                mobileTabButton(.home, title: "首页", symbol: "play.rectangle.fill")
                mobileTabButton(.sources, title: "片源", symbol: "externaldrive.fill")
                mobileTabButton(.search, title: "搜索", symbol: "magnifyingglass")
            }
            .padding(6)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.6), lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
            .padding(.top, 8)
            .padding(.bottom, 6)
            .frame(maxWidth: .infinity)
        }
    }

    private func mobileTabButton(_ tab: MobileTab, title: String, symbol: String) -> some View {
        Button { mobileTab = tab } label: {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(mobileTab == tab ? Color.white : Color.primary)
                .frame(width: 78)
                .frame(height: 42)
                .background(mobileTab == tab ? Color.blue : Color.clear, in: Capsule())
        }
        .accessibilityLabel(title)
    }
    #endif

    private var navigationBody: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if library.items.isEmpty && library.folders.isEmpty && library.smbSources.isEmpty &&
                        library.webDAVSources.isEmpty && library.jellyfinSources.isEmpty &&
                        library.embySources.isEmpty && library.plexSources.isEmpty &&
                        library.cloudSources.isEmpty && library.dlnaSources.isEmpty &&
                        library.vlcNetworkSources.isEmpty {
                        emptyLibrary
                    } else {
                        let visible = filtered
                        let continuing = visible.filter(\.isInProgress)
                        if !continuing.isEmpty {
                            section("继续观看", items: continuing)
                        }
                        let downloads = visible.filter { library.downloadedURL(for: $0) != nil }
                        if !downloads.isEmpty { section("已下载", items: downloads) }
                        if mediaFilter == .all {
                            let favorites = visible.filter(\.isFavorite)
                            if !favorites.isEmpty { section("收藏", items: favorites) }
                        }
                        let recent = Array(visible.sorted { $0.addedAt > $1.addedAt }.prefix(12))
                        if !recent.isEmpty { section("最近添加", items: recent) }
                        let episodesBySeries = Dictionary(grouping: visible.filter { $0.identity?.seriesName != nil }) {
                            $0.identity?.seriesName ?? ""
                        }
                        if !episodesBySeries.isEmpty { seriesSection(episodesBySeries) }
                        if !library.collections.isEmpty { collectionsSection(visible) }
                        if !library.smartPlaylists.isEmpty { smartPlaylistsSection(visible) }
                        section("电影与其他视频", items: visible.filter { $0.identity?.seriesName == nil })
                        if library.activeProfile?.isChild != true {
                            if !library.smbSources.isEmpty { smbSection }
                            if !library.webDAVSources.isEmpty { webDAVSection }
                            if !library.jellyfinSources.isEmpty { jellyfinSection }
                            if !library.embySources.isEmpty { embySection }
                        if !library.plexSources.isEmpty { plexSection }
                        if !library.cloudSources.isEmpty { cloudSection }
                        if !library.dlnaSources.isEmpty { dlnaSection }
                        if !library.vlcNetworkSources.isEmpty { vlcNetworkSection }
                            #if !os(tvOS)
                            if !library.folders.isEmpty { foldersSection }
                            #endif
                        }
                    }
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Lucent")
            #if !os(tvOS)
            .searchable(text: $search, prompt: "搜索媒体库")
            #endif
            .toolbar {
                #if os(tvOS)
                ToolbarItem(placement: .automatic) {
                    Button("首页", systemImage: "house.fill") { tvShowLibrary = false }
                }
                #endif
                ToolbarItem(placement: .automatic) {
                    Menu(library.activeProfile?.name ?? "资料", systemImage: "person.crop.circle") {
                        ForEach(library.viewerProfiles) { profile in
                            Button(profile.name) {
                                if library.activeProfile?.isChild == true && !profile.isChild {
                                    pendingProfileID = profile.id
                                    profileUnlockPIN = ""
                                    showProfileUnlock = true
                                } else {
                                    _ = library.switchViewerProfile(id: profile.id)
                                }
                            }
                        }
                        if library.activeProfile?.isChild == false {
                            Divider()
                            Button("管理资料") { showProfiles = true }
                        }
                    }
                }
                if library.activeProfile?.isChild != true {
                    ToolbarItem(placement: .automatic) {
                        Menu("iCloud", systemImage: "icloud") {
                            Toggle("同步播放状态和收藏", isOn: $library.iCloudSyncEnabled)
                            Button("立即同步") { Task { await library.syncNow() } }
                                .disabled(!library.iCloudSyncEnabled || library.syncing)
                            if let status = library.syncStatus { Text(status) }
                        }
                    }
                    ToolbarItem(placement: .automatic) {
                        Button("Trakt", systemImage: "arrow.triangle.2.circlepath") { showTrakt = true }
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Menu("筛选", systemImage: "line.3.horizontal.decrease") {
                        Button("全部") { mediaFilter = .all }
                        Button("未看完") { mediaFilter = .unwatched }
                        Button("收藏") { mediaFilter = .favorites }
                    }
                }
                ToolbarItem(placement: .automatic) {
                    Menu("排序", systemImage: "arrow.up.arrow.down") {
                        Button("最近添加") { sortOrder = .newest }
                        Button("标题") { sortOrder = .title }
                    }
                }
                if library.activeProfile?.isChild != true {
                ToolbarItem(placement: .automatic) {
                    Button("自动补全资料", systemImage: "sparkles") {
                        Task { await library.enrichMissingMetadata() }
                    }
                    .disabled(library.enrichingMetadata)
                }
                ToolbarItem(placement: .automatic) {
                    Button("清理失效影片", systemImage: "trash", role: .destructive) {
                        library.purgeMissingItems()
                    }
                    .disabled(!library.items.contains { $0.missingSince != nil })
                }
                ToolbarItem(placement: .automatic) {
                    Menu {
                        Button("添加网络地址", systemImage: "link") { showAddAddress = true }
                        Button("添加 SMB 片源", systemImage: "externaldrive.connected.to.line.below") { showSMB = true }
                        Button("添加 WebDAV 片源", systemImage: "network") {
                            webDAVIs123Pan = false; showWebDAV = true
                        }
                        Button("连接 123 云盘（WebDAV）", systemImage: "externaldrive.badge.icloud") {
                            webDAVIs123Pan = true; showWebDAV = true
                        }
                        Button("连接 Jellyfin", systemImage: "server.rack") { showJellyfin = true }
                        Button("连接 Emby", systemImage: "server.rack") { showEmby = true }
                        Button("连接 Plex", systemImage: "play.tv") { showPlex = true }
                        Button("连接云盘", systemImage: "externaldrive.badge.icloud") { showCloud = true }
                        Button("导入 DLNA 媒体", systemImage: "dot.radiowaves.left.and.right") { showDLNA = true }
                        Button("浏览 FTP/SFTP/NFS", systemImage: "network") { showNetworkFolder = true }
                        Button("新建合集", systemImage: "square.stack.3d.up") { showAddCollection = true }
                        Button("新建智能播放列表", systemImage: "line.3.horizontal.decrease.circle") {
                            showAddSmartPlaylist = true
                        }
                        #if !os(tvOS)
                        Button("添加本地文件", systemImage: "folder") { showFileImporter = true }
                        Button("添加文件夹", systemImage: "folder.badge.plus") { showFolderImporter = true }
                        Button("通过浏览器上传", systemImage: "square.and.arrow.up.on.square") {
                            showBrowserUpload = true
                        }
                        #endif
                    } label: {
                        Label("添加影片", systemImage: "plus")
                    }
                }
                }
            }
            .sheet(isPresented: $showAddAddress) { addAddressSheet }
            .sheet(isPresented: $showSMB) { smbSheet }
            .sheet(item: $editingSMB) { source in smbCredentialsSheet(source) }
            .sheet(item: $editingJellyfin) { source in jellyfinTokenSheet(source) }
            .sheet(item: $editingEmby) { source in embyTokenSheet(source) }
            .sheet(item: $browsingEmby) { source in
                EmbyBrowserView(source: source).environmentObject(library)
            }
            .sheet(item: $editingPlex) { source in plexTokenSheet(source) }
            .sheet(isPresented: $showWebDAV) { webDAVSheet }
            .sheet(item: $editingWebDAV) { source in webDAVCredentialsSheet(source) }
            .sheet(isPresented: $showJellyfin) { jellyfinSheet }
            .sheet(isPresented: $showEmby) { embySheet }
            .sheet(isPresented: $showPlex) { plexSheet }
            .sheet(isPresented: $showCloud) { cloudSheet }
            .sheet(isPresented: $showDLNA) { dlnaSheet }
            .sheet(isPresented: $showNetworkFolder) { networkFolderSheet }
            .sheet(item: $editingNetworkFolder) { source in networkCredentialsSheet(source) }
            .sheet(item: $editingCloud) { source in cloudTokenSheet(source) }
            .sheet(isPresented: $showAddCollection) { collectionSheet }
            .sheet(isPresented: $showAddSmartPlaylist) { smartPlaylistSheet }
            .sheet(isPresented: $showProfiles) { profilesSheet }
            .sheet(isPresented: $showTrakt, onDismiss: { traktAuthTask?.cancel(); traktAuthTask = nil }) {
                traktSheet
            }
            .sheet(isPresented: $showProfileUnlock) { profileUnlockSheet }
            #if !os(tvOS)
            .sheet(isPresented: $showBrowserUpload, onDismiss: stopBrowserUpload) {
                NavigationStack {
                    VStack(spacing: 20) {
                        Text("在同一 Wi-Fi 网络中的电脑或手机浏览器打开：")
                        if let browserUploadURL {
                            Text(browserUploadURL.absoluteString)
                                .font(.title3.monospaced())
                                .textSelection(.enabled)
                        } else {
                            ProgressView("正在启动上传服务…")
                        }
                        Text("此地址仅在本页面打开时有效。关闭页面后停止接收。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .navigationTitle("浏览器上传")
                    .toolbar {
                        Button("完成") { showBrowserUpload = false }
                    }
                    .task { await startBrowserUpload() }
                }
            }
            #endif
            .sheet(item: $selectedItem) { item in
                MediaDetailView(itemID: item.id)
                    .environmentObject(library)
            }
            .sheet(item: $editingItem) { item in
                MediaEditView(item: item)
                    .environmentObject(library)
            }
            .alert("无法完成操作", isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )) {
                Button("好") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "未知错误")
            }
            .alert("片源测速", isPresented: Binding(
                get: { library.diagnosticMessage != nil },
                set: { if !$0 { library.diagnosticMessage = nil } }
            )) {
                Button("好") { library.diagnosticMessage = nil }
            } message: {
                Text(library.diagnosticMessage ?? "")
            }
            #if !os(tvOS)
            .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url):
                    let allowed = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm",
                                   "m2ts", "mts", "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"]
                    if allowed.contains(url.pathExtension.lowercased()) {
                        library.addFile(url)
                    } else {
                        library.errorMessage = "请选择视频文件。"
                    }
                case .failure(let error):
                    library.errorMessage = error.localizedDescription
                }
            }
            .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): library.addFolder(url)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            #endif
        }
    }

    #if !os(tvOS)
    private func startBrowserUpload() async {
        guard browserUploadServer == nil else { return }
        let store = library
        let server = BrowserUploadServer(destination: store.uploadDirectory) { url in
            Task { @MainActor in store.addUploadedFile(url) }
        }
        browserUploadServer = server
        do { browserUploadURL = try await server.start() }
        catch {
            browserUploadServer = nil
            showBrowserUpload = false
            library.errorMessage = "无法启动浏览器上传：\(error.localizedDescription)"
        }
    }

    private func stopBrowserUpload() {
        browserUploadServer?.stop()
        browserUploadServer = nil
        browserUploadURL = nil
    }
    #endif

    private var traktSheet: some View {
        NavigationStack {
            Form {
                Section("Trakt 应用") {
                    TextField("Client ID", text: $traktClientID)
                    SecureField("Client Secret（留空则沿用已保存值）", text: $traktClientSecret)
                    Text("在 Trakt 创建应用后填写凭据；Secret 保存在本机 Keychain。")
                        .font(.footnote)
                }
                Section("账户") {
                    if let code = traktDeviceCode {
                        Text("打开 \(code.verificationURL.absoluteString) 并输入：")
                        Text(code.userCode).font(.title.monospaced())
                    }
                    if TraktClient.connected {
                        Button("立即同步观看状态") { Task { await library.syncTrakt() } }
                            .disabled(library.traktSyncing)
                        Button("断开 Trakt", role: .destructive) {
                            do { try TraktClient.disconnect(); traktDeviceCode = nil }
                            catch { traktMessage = error.localizedDescription }
                        }
                    } else {
                        Button("连接 Trakt") { beginTraktConnection() }
                            .disabled(traktAuthTask != nil || traktClientID.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let traktMessage { Text(traktMessage).foregroundStyle(.secondary) }
                    if let status = library.traktStatus { Text(status).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Trakt")
            .toolbar { Button("完成") { showTrakt = false } }
        }
    }

    private func beginTraktConnection() {
        let id = traktClientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let secret = traktClientSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        do {
            UserDefaults.standard.set(id, forKey: "lucent.trakt.clientID")
            if !secret.isEmpty { try KeychainPasswordStore.setTraktSecret(secret, account: "clientSecret") }
            guard let savedSecret = try KeychainPasswordStore.traktSecret("clientSecret"), !savedSecret.isEmpty else {
                traktMessage = "请填写 Client Secret。"; return
            }
            traktAuthTask = Task {
                do {
                    let code = try await TraktClient.beginDeviceAuthorization(clientID: id)
                    traktDeviceCode = code
                    try await TraktClient.completeDeviceAuthorization(code: code, clientID: id,
                                                                      clientSecret: savedSecret)
                    traktDeviceCode = nil
                    traktMessage = "Trakt 已连接。"
                    await library.syncTrakt()
                } catch {
                    if !Task.isCancelled { traktMessage = error.localizedDescription }
                }
                traktAuthTask = nil
            }
        } catch { traktMessage = error.localizedDescription }
    }

    private func seriesSection(_ episodesBySeries: [String: [MediaItem]]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("剧集").font(.title2.bold())
            ForEach(episodesBySeries.keys.sorted(), id: \.self) { series in
                Group {
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 12) {
                    Text(series).font(.headline)
                    seriesContent(episodesBySeries[series] ?? [])
                }
                #else
                DisclosureGroup(series) { seriesContent(episodesBySeries[series] ?? []) }
                #endif
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func seriesContent(_ episodes: [MediaItem]) -> some View {
        let seasons = Dictionary(grouping: episodes) { item -> Int in
            if case .some(.episode(_, let season, _, _)) = item.identity { return season }
            return 0
        }
        return ForEach(seasons.keys.sorted(), id: \.self) { season in
            Text("第\(season)季").font(.headline).padding(.top, 8)
            ForEach((seasons[season] ?? []).sorted { ($0.identity?.episodeLabel ?? "") < ($1.identity?.episodeLabel ?? "") }) { item in
                itemRow(item)
            }
        }
    }

    private func collectionsSection(_ visible: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("合集").font(.title2.bold())
            ForEach(library.collections) { collection in
                Group {
                #if os(tvOS)
                VStack(alignment: .leading, spacing: 12) {
                    Text(collection.name).font(.headline)
                    collectionContent(collection, visible: visible)
                }
                #else
                DisclosureGroup(collection.name) { collectionContent(collection, visible: visible) }
                #endif
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func collectionContent(_ collection: MediaCollection, visible: [MediaItem]) -> some View {
        let memberIDs = Set(collection.itemIDs)
        let members = visible.filter { memberIDs.contains($0.id) }
        return VStack(alignment: .leading, spacing: 8) {
            if members.isEmpty { Text("合集为空").foregroundStyle(.secondary) }
            ForEach(members) { item in itemRow(item) }
            Button("删除合集", role: .destructive) { library.removeCollection(id: collection.id) }
        }
    }

    private func smartPlaylistsSection(_ visible: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("智能播放列表").font(.title2.bold())
            ForEach(library.smartPlaylists) { playlist in
                Group {
                    #if os(tvOS)
                    VStack(alignment: .leading, spacing: 12) {
                        Text(playlist.name).font(.headline)
                        smartPlaylistContent(playlist, visible: visible)
                    }
                    #else
                    DisclosureGroup(playlist.name) {
                        smartPlaylistContent(playlist, visible: visible)
                    }
                    #endif
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private func smartPlaylistContent(_ playlist: SmartPlaylist, visible: [MediaItem]) -> some View {
        let members = visible.filter { playlist.includes($0) }
        return VStack(alignment: .leading, spacing: 8) {
            if members.isEmpty { Text("暂无匹配影片").foregroundStyle(.secondary) }
            ForEach(members) { item in itemRow(item) }
            Button("删除智能播放列表", role: .destructive) {
                library.removeSmartPlaylist(id: playlist.id)
            }
        }
    }

    private var cloudSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("云盘").font(.title2.bold())
            ForEach(library.cloudSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.icloud")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(source.provider.title) · \(source.name)").font(.headline)
                        Text(library.offlineCloudSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningCloudSources.contains(source.id) {
                        ProgressView()
                    } else {
                        Button("刷新") { library.scanCloud(id: source.id) }
                    }
                    Menu {
                        Button("更新授权") {
                            cloudToken = ""
                            cloudClientID = source.oauthClientID ?? ""
                            cloudRefreshToken = ""
                            editingCloud = source
                        }
                        Button("移除云盘及其影片", role: .destructive) { library.removeCloud(id: source.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var dlnaSheet: some View {
        NavigationStack {
            Form {
                TextField("http://设备地址:端口/description.xml", text: $dlnaAddress)
                Button(discoveringDLNA ? "正在查找设备…" : "查找局域网设备") {
                    discoveringDLNA = true
                    Task {
                        let addresses = await SSDPDiscovery.discover()
                        var found: [DLNAClient.Device] = []
                        for address in addresses {
                            if let device = try? await DLNAClient.connect(descriptionURL: address) {
                                found.append(device)
                            }
                        }
                        dlnaDevices = found
                        dlnaMessage = found.isEmpty ? "未找到 DLNA 设备，可手动输入描述地址。" : nil
                        discoveringDLNA = false
                    }
                }.disabled(discoveringDLNA)
                ForEach(dlnaDevices, id: \.descriptionURL) { device in
                    Button("\(device.name) · \(device.descriptionURL.host ?? "")") {
                        dlnaAddress = device.descriptionURL.absoluteString
                    }
                }
                Text("选择发现的设备或填写描述地址，Lucent 会保存片源并读取 ContentDirectory。")
                    .font(.footnote).foregroundStyle(.secondary)
                if scanningDLNA { ProgressView("正在浏览媒体目录…") }
                if let dlnaMessage { Text(dlnaMessage).foregroundStyle(.secondary) }
            }
            .navigationTitle("导入 DLNA 媒体")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDLNA = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        guard let url = URL(string: dlnaAddress) else { return }
                        scanningDLNA = true
                        Task {
                            do {
                                let device = try await DLNAClient.connect(descriptionURL: url)
                                let videos = try await DLNAClient.scan(device: device)
                                let added = library.addDLNA(device: device, videos: videos)
                                dlnaMessage = "\(device.name)：导入 \(added) 个视频。"
                            } catch { dlnaMessage = error.localizedDescription }
                            scanningDLNA = false
                        }
                    }
                    .disabled(scanningDLNA || dlnaAddress.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 250)
    }

    private var dlnaSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("DLNA 设备").font(.title2.bold())
            ForEach(library.dlnaSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlineDLNASources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningDLNASources.contains(source.id) { ProgressView() }
                    else { Button("刷新") { library.scanDLNA(id: source.id) } }
                    Menu {
                        Button("移除设备及其影片", role: .destructive) { library.removeDLNA(id: source.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var vlcNetworkSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FTP / SFTP / NFS").font(.title2.bold())
            ForEach(library.vlcNetworkSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "network")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlineVLCNetworkSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningVLCNetworkSources.contains(source.id) { ProgressView() }
                    else { Button("刷新") { library.scanVLCNetwork(id: source.id) } }
                    Menu {
                        Button("更新登录信息") {
                            networkFolderUsername = source.username
                            networkFolderPassword = ""
                            editingNetworkFolder = source
                        }
                        Button("移除目录及其影片", role: .destructive) {
                            library.removeVLCNetwork(id: source.id)
                        }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var networkFolderSheet: some View {
        NavigationStack {
            Form {
                TextField("sftp://nas.local/Movies/", text: $networkFolderAddress)
                TextField("用户名（可留空）", text: $networkFolderUsername)
                SecureField("密码（可留空）", text: $networkFolderPassword)
                Text("可浏览 FTP、FTPS、SFTP 或 NFS 目录。凭据保存在本机 Keychain。")
                    .font(.footnote).foregroundStyle(.secondary)
                if scanningNetworkFolder { ProgressView("正在浏览远程目录…") }
                if let networkFolderMessage { Text(networkFolderMessage).foregroundStyle(.secondary) }
            }
            .navigationTitle("浏览网络目录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { showNetworkFolder = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") {
                        guard let url = URL(string: networkFolderAddress) else { return }
                        scanningNetworkFolder = true
                        Task {
                            do {
                                let videos = try await VLCNetworkBrowser.browse(
                                    root: url, username: networkFolderUsername,
                                    password: networkFolderPassword.isEmpty ? nil : networkFolderPassword)
                                let added = library.addVLCNetworkSource(
                                    root: url, username: networkFolderUsername,
                                    password: networkFolderPassword, videos: videos)
                                networkFolderMessage = "导入 \(added) 个视频。"
                            } catch { networkFolderMessage = error.localizedDescription }
                            scanningNetworkFolder = false
                        }
                    }
                    .disabled(scanningNetworkFolder || networkFolderAddress.isEmpty)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 250)
    }

    private func networkCredentialsSheet(_ source: VLCNetworkSource) -> some View {
        NavigationStack {
            Form {
                TextField("用户名", text: $networkFolderUsername)
                SecureField("新密码（留空则匿名）", text: $networkFolderPassword)
            }
            .navigationTitle("更新网络目录登录信息")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingNetworkFolder = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        library.updateVLCNetworkCredentials(id: source.id,
                                                            username: networkFolderUsername,
                                                            password: networkFolderPassword)
                        editingNetworkFolder = nil
                    }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 220)
    }

    private var cloudSheet: some View {
        NavigationStack {
            Form {
                Picker("服务", selection: $cloudProvider) {
                    ForEach(CloudProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                TextField("名称", text: $cloudName)
                SecureField("OAuth 访问令牌", text: $cloudToken)
                TextField(cloudProvider == .pan123 ? "123 开放平台 clientID" : "OAuth 应用 ID（可选）",
                          text: $cloudClientID)
                SecureField(cloudProvider == .pan123 ? "123 开放平台 clientSecret" : "刷新令牌（可选）",
                            text: $cloudRefreshToken)
                if cloudProvider == .baiduPan {
                    SecureField("百度开放平台 SecretKey", text: $cloudClientSecret)
                    Button("获取百度授权码") {
                        addingCloud = true
                        Task {
                            do {
                                baiduDeviceCode = try await CloudTokenRefresher.beginBaidu(clientID: cloudClientID)
                            } catch { dropboxAuthorizationMessage = error.localizedDescription }
                            addingCloud = false
                        }
                    }
                    .disabled(cloudClientID.isEmpty || addingCloud)
                    if let device = baiduDeviceCode,
                       let url = URL(string: device.verificationURL) {
                        Link("打开百度授权页", destination: url)
                        Text("授权码：\(device.userCode)")
                            .font(.headline.monospaced())
                        Button("授权完成，获取令牌") {
                            addingCloud = true
                            Task {
                                do {
                                    if let token = try await CloudTokenRefresher.exchangeBaidu(
                                        clientID: cloudClientID, clientSecret: cloudClientSecret,
                                        deviceCode: device.deviceCode) {
                                        cloudToken = token.accessToken
                                        cloudRefreshToken = token.refreshToken ?? ""
                                        dropboxAuthorizationMessage = "授权成功，可以连接云盘。"
                                    } else {
                                        dropboxAuthorizationMessage = "尚未完成授权，请在百度页面确认后重试。"
                                    }
                                } catch { dropboxAuthorizationMessage = error.localizedDescription }
                                addingCloud = false
                            }
                        }
                        .disabled(cloudClientSecret.isEmpty || addingCloud)
                    }
                    if let dropboxAuthorizationMessage {
                        Text(dropboxAuthorizationMessage).foregroundStyle(.secondary)
                    }
                }
                if cloudProvider == .pan115 {
                    Button("获取 115 授权二维码") {
                        addingCloud = true
                        Task {
                            do {
                                open115Authorization = try await CloudTokenRefresher.begin115(clientID: cloudClientID)
                                dropboxAuthorizationMessage = nil
                            } catch { dropboxAuthorizationMessage = error.localizedDescription }
                            addingCloud = false
                        }
                    }
                    .disabled(cloudClientID.isEmpty || addingCloud)
                    if let authorization = open115Authorization {
                        CloudAuthorizationQRCode(content: authorization.qrCode)
                            .frame(width: 210, height: 210)
                        Text("使用 115 客户端扫码授权")
                        Button("已授权，获取令牌") {
                            addingCloud = true
                            Task {
                                do {
                                    let token = try await CloudTokenRefresher.exchange115(authorization)
                                    cloudToken = token.accessToken
                                    cloudRefreshToken = token.refreshToken ?? ""
                                    dropboxAuthorizationMessage = "授权成功，可以连接云盘。"
                                } catch { dropboxAuthorizationMessage = error.localizedDescription }
                                addingCloud = false
                            }
                        }
                        .disabled(addingCloud)
                    }
                    if let dropboxAuthorizationMessage {
                        Text(dropboxAuthorizationMessage).foregroundStyle(.secondary)
                    }
                }
                if cloudProvider == .dropbox {
                    Button("获取 Dropbox 授权地址") {
                        do {
                            dropboxAuthorization = try CloudTokenRefresher.beginDropbox(
                                clientID: cloudClientID.trimmingCharacters(in: .whitespacesAndNewlines))
                            dropboxAuthorizationMessage = nil
                        } catch { dropboxAuthorizationMessage = error.localizedDescription }
                    }
                    .disabled(cloudClientID.isEmpty)
                    if let authorization = dropboxAuthorization {
                        Text(authorization.url.absoluteString)
                            .font(.caption.monospaced())
                        Link("打开 Dropbox 授权页", destination: authorization.url)
                        TextField("授权页显示的授权码", text: $dropboxAuthorizationCode)
                        Button("换取刷新令牌") {
                            addingCloud = true
                            Task {
                                do {
                                    let token = try await CloudTokenRefresher.exchangeDropbox(
                                        clientID: authorization.clientID, code: dropboxAuthorizationCode,
                                        verifier: authorization.verifier)
                                    cloudClientID = authorization.clientID
                                    cloudToken = token.accessToken
                                    cloudRefreshToken = token.refreshToken ?? ""
                                    dropboxAuthorizationMessage = "授权成功，可以连接云盘。"
                                } catch { dropboxAuthorizationMessage = error.localizedDescription }
                                addingCloud = false
                            }
                        }
                        .disabled(addingCloud || dropboxAuthorizationCode.isEmpty)
                    }
                    if let dropboxAuthorizationMessage {
                        Text(dropboxAuthorizationMessage).foregroundStyle(.secondary)
                    }
                }
                Text(cloudProvider == .dropbox || cloudProvider == .googleDrive
                     ? "可填写访问令牌；若提供应用 ID 和刷新令牌，Lucent 会自动续期。令牌仅保存在本机 Keychain。"
                     : cloudProvider == .pan123
                     ? "填写开放平台 clientID 和 clientSecret 可自动获取及续期令牌；也可手动填写访问令牌。clientSecret 保存在本机 Keychain。"
                     : cloudProvider == .baiduPan
                     ? "填写百度开放平台 AppKey 和 SecretKey，完成设备码授权；访问令牌与 SecretKey 保存在本机 Keychain。"
                     : cloudProvider == .pan115
                     ? "填写 115 开放平台应用 ID，扫码授权后自动保存并续期令牌。"
                     : cloudProvider == .guangyaPan
                     ? "填写光鸭访问令牌即可扫描与播放；也可填写刷新令牌自动续期。接口依据第三方 guangyaclient 项目，可能随服务端更新变化；令牌只保存在本机 Keychain。"
                     : "请填写该网盘的访问令牌；令牌只保存在本机 Keychain。")
                    .font(.footnote).foregroundStyle(.secondary)
                if addingCloud { ProgressView() }
            }
            .navigationTitle("连接云盘")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showCloud = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        addingCloud = true
                        Task {
                            let added = await library.addCloud(provider: cloudProvider, name: cloudName,
                                                               token: cloudToken, clientID: cloudClientID,
                                                               refreshToken: cloudRefreshToken,
                                                               clientSecret: cloudClientSecret)
                            addingCloud = false
                            if added {
                                cloudName = ""; cloudToken = ""; cloudClientID = ""
                                cloudRefreshToken = ""; dropboxAuthorization = nil
                                cloudClientSecret = ""; baiduDeviceCode = nil; open115Authorization = nil
                                dropboxAuthorizationCode = ""; showCloud = false
                            }
                        }
                    }
                    .disabled(addingCloud || cloudName.isEmpty ||
                              (cloudToken.isEmpty && (cloudRefreshToken.isEmpty ||
                                 (cloudProvider != .pan115 && cloudProvider != .guangyaPan && cloudClientID.isEmpty))))
                }
            }
        }
        .frame(minWidth: 350, minHeight: 250)
    }

    private func cloudTokenSheet(_ source: CloudSource) -> some View {
        NavigationStack {
            Form {
                SecureField("新访问令牌", text: $cloudToken)
                TextField(source.provider == .pan123 ? "123 开放平台 clientID" : "OAuth 应用 ID",
                          text: $cloudClientID)
                SecureField(source.provider == .pan123 ? "123 开放平台 clientSecret" : "刷新令牌",
                            text: $cloudRefreshToken)
                if source.provider == .baiduPan {
                    SecureField("百度开放平台 SecretKey", text: $cloudClientSecret)
                }
                if addingCloud { ProgressView() }
            }
            .navigationTitle("更新 \(source.name) 凭据")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingCloud = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        addingCloud = true
                        Task {
                            let saved: Bool
                            if !cloudRefreshToken.isEmpty {
                                saved = await library.updateCloudAuthorization(
                                    id: source.id, clientID: cloudClientID,
                                    refreshToken: cloudRefreshToken,
                                    clientSecret: cloudClientSecret)
                            } else {
                                saved = await library.updateCloudToken(id: source.id, token: cloudToken)
                            }
                            addingCloud = false
                            if saved { cloudToken = ""; editingCloud = nil }
                        }
                    }
                    .disabled(addingCloud || (cloudToken.isEmpty &&
                              (cloudRefreshToken.isEmpty ||
                               (source.provider != .pan115 && source.provider != .guangyaPan &&
                                cloudClientID.isEmpty))))
                }
            }
        }
    }

    private var emptyLibrary: some View {
        VStack(spacing: 18) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            Text("开始建立你的媒体库")
                .font(.title2.bold())
            Text("添加你拥有的视频文件或网络播放地址。")
                .foregroundStyle(.secondary)
            Button("添加网络地址") { showAddAddress = true }
                .buttonStyle(.borderedProminent)
            Button("连接 SMB 片源") { showSMB = true }
            #if !os(tvOS)
            Button("选择本地文件") { showFileImporter = true }
            Button("扫描文件夹") { showFolderImporter = true }
            #endif
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }

    private var smbSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SMB 片源").font(.title2.bold())
            ForEach(library.smbSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlineSMBSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningSMBSources.contains(source.id) {
                        ProgressView().accessibilityLabel("正在扫描\(source.name)")
                    } else {
                        Button("刷新") { library.scanSMB(id: source.id) }
                    }
                    Menu {
                        Button("更新登录凭据") {
                            editedSMBUsername = source.username
                            editedSMBPassword = ""
                            replaceSMBPassword = false
                            editingSMB = source
                        }
                        Button("移除片源及其影片", role: .destructive) { library.removeSMB(id: source.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("\(source.name)的更多操作")
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var webDAVSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WebDAV 片源").font(.title2.bold())
            ForEach(library.webDAVSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "network")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlineWebDAVSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningWebDAVSources.contains(source.id) {
                        ProgressView()
                    } else {
                        Button("刷新") { library.scanWebDAV(id: source.id) }
                    }
                    Menu {
                        Button("更新登录凭据") {
                            editedWebDAVUsername = source.username
                            editedWebDAVPassword = ""
                            replaceWebDAVPassword = false
                            editingWebDAV = source
                        }
                        Button("移除片源及其影片", role: .destructive) { library.removeWebDAV(id: source.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var jellyfinSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Jellyfin 服务器").font(.title2.bold())
            ForEach(library.jellyfinSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlineJellyfinSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningJellyfinSources.contains(source.id) {
                        ProgressView()
                    } else {
                        Button("刷新") { library.scanJellyfin(id: source.id) }
                    }
                    Menu {
                        Button("更新访问令牌") {
                            replacementToken = ""
                            editingJellyfin = source
                        }
                        Button("移除服务器及其影片", role: .destructive) { library.removeJellyfin(id: source.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var embySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Emby 服务器").font(.title2.bold())
            ForEach(library.embySources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                    Button { browsingEmby = source } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(source.name).font(.headline)
                            Text("浏览服务器目录").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    Button("浏览", systemImage: "chevron.right") { browsingEmby = source }
                    Menu {
                        Button("更新访问令牌") {
                            replacementToken = ""
                            editingEmby = source
                        }
                        Button("移除服务器及播放记录", role: .destructive) { library.removeEmby(id: source.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    private var plexSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plex 服务器").font(.title2.bold())
            ForEach(library.plexSources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "play.tv")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlinePlexSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningPlexSources.contains(source.id) {
                        ProgressView()
                    } else {
                        Button("刷新") { library.scanPlex(id: source.id) }
                    }
                    Menu {
                        Button("更新访问令牌") {
                            replacementToken = ""
                            editingPlex = source
                        }
                        Button("移除服务器及其影片", role: .destructive) { library.removePlex(id: source.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }

    #if !os(tvOS)
    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文件夹片源").font(.title2.bold())
            ForEach(library.folders) { source in
                HStack(spacing: 12) {
                    Image(systemName: "folder")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text(library.offlineFolders.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { "上次扫描：\($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未扫描")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if library.scanningFolders.contains(source.id) {
                        ProgressView().accessibilityLabel("正在扫描\(source.name)")
                    } else {
                        Button("刷新") { library.scanFolder(id: source.id) }
                    }
                    Menu {
                        Button("移除片源及其影片", role: .destructive) { library.removeFolder(id: source.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("\(source.name)的更多操作")
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
    }
    #endif

    private func section(_ title: String, items: [MediaItem]) -> some View {
        LazyVStack(alignment: .leading, spacing: 12) {
            Text(title).font(.title2.bold())
            if items.isEmpty {
                Text("没有匹配的影片")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 24)
            }
            ForEach(items) { item in
                itemRow(item)
            }
        }
    }

    private func itemRow(_ item: MediaItem) -> some View {
                HStack(spacing: 16) {
                    Button { selectedItem = item } label: {
                        HStack(spacing: 16) {
                            Group {
                                if let url = library.posterURL(for: item) {
                                    LocalPosterView(url: url)
                                } else if let url = item.metadata?.posterURL {
                                    AsyncImage(url: url) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: {
                                        Image(systemName: "film")
                                    }
                                } else {
                                    Image(systemName: "film")
                                }
                            }
                            .font(.title2)
                            .frame(width: 48, height: 48)
                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 6) {
                                Text([item.identity?.episodeLabel, item.title].compactMap { $0 }.joined(separator: " · "))
                                    .font(.headline).lineLimit(2)
                                Text(item.watched ? "已看完" : item.isInProgress ? "继续播放" : "未观看")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if item.progress > 0 {
                                    ProgressView(value: item.progress)
                                }
                            }
                            Spacer(minLength: 8)
                            if item.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                            Image(systemName: "chevron.right")
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    Menu {
                        Button("编辑资料") { editingItem = item }
                        Button("测试读取速度") { library.testNetwork(item: item) }
                        Button(item.isFavorite ? "取消收藏" : "收藏") { library.toggleFavorite(id: item.id) }
                        if item.watched {
                            Button("标记为未观看") { library.markUnwatched(id: item.id) }
                        } else {
                            Button("标记为已看完") { library.markWatched(id: item.id) }
                        }
                        Button("从媒体库移除", role: .destructive) { library.remove(id: item.id) }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("\(item.title)的更多操作")
                }
                .padding(14)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var smbSheet: some View {
        NavigationStack {
            Form {
                TextField("服务器地址或 IP", text: $smbHost)
                if !smbDiscovery.hosts.isEmpty {
                    Section("发现的服务器") {
                        ForEach(smbDiscovery.hosts, id: \.self) { host in
                            Button(host) { smbHost = host }
                        }
                    }
                }
                TextField("共享名称", text: $smbShare)
                TextField("用户名（访客可留空）", text: $smbUsername)
                SecureField("密码（访客可留空）", text: $smbPassword)
                Text("凭据保存在本机钥匙串。添加后会扫描共享中的视频。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("添加 SMB 片源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showSMB = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if library.addSMB(host: smbHost, share: smbShare,
                                          username: smbUsername, password: smbPassword) {
                            smbHost = ""
                            smbShare = ""
                            smbUsername = ""
                            smbPassword = ""
                            showSMB = false
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 350)
        .onAppear { smbDiscovery.start() }
        .onDisappear { smbDiscovery.stop() }
    }

    private var webDAVSheet: some View {
        NavigationStack {
            Form {
                if webDAVIs123Pan {
                    Text("在 123 云盘的 WebDAV 授权管理中获取专属地址和第三方应用密码。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                TextField(webDAVIs123Pan ? "123 云盘提供的 WebDAV 地址" : "https://server.example/videos/",
                          text: $webDAVAddress)
                TextField(webDAVIs123Pan ? "123 云盘账号" : "用户名（访客可留空）",
                          text: $webDAVUsername)
                SecureField(webDAVIs123Pan ? "第三方应用密码" : "密码（访客可留空）",
                            text: $webDAVPassword)
                Text("公网地址需要 HTTPS。凭据保存在本机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle(webDAVIs123Pan ? "连接 123 云盘" : "添加 WebDAV 片源")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showWebDAV = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if library.addWebDAV(address: webDAVAddress, username: webDAVUsername,
                                             password: webDAVPassword) {
                            webDAVAddress = ""
                            webDAVUsername = ""
                            webDAVPassword = ""
                            showWebDAV = false
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
    }

    private func webDAVCredentialsSheet(_ source: WebDAVSource) -> some View {
        NavigationStack {
            Form {
                Text(source.name).font(.headline)
                TextField("用户名", text: $editedWebDAVUsername)
                Toggle("更新密码", isOn: $replaceWebDAVPassword)
                if replaceWebDAVPassword {
                    SecureField("新密码", text: $editedWebDAVPassword)
                }
            }
            .navigationTitle("WebDAV 登录凭据")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingWebDAV = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并扫描") {
                        if library.updateWebDAVCredentials(id: source.id, username: editedWebDAVUsername,
                                                           password: replaceWebDAVPassword ? editedWebDAVPassword : nil) {
                            editedWebDAVPassword = ""
                            editingWebDAV = nil
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 260)
    }

    private func smbCredentialsSheet(_ source: SMBSource) -> some View {
        NavigationStack {
            Form {
                Text(source.name).font(.headline)
                TextField("用户名", text: $editedSMBUsername)
                Toggle("更新密码", isOn: $replaceSMBPassword)
                if replaceSMBPassword {
                    SecureField("新密码（留空表示访客访问）", text: $editedSMBPassword)
                }
            }
            .navigationTitle("SMB 登录凭据")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { editingSMB = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并扫描") {
                        if library.updateSMBCredentials(id: source.id, username: editedSMBUsername,
                                                        password: replaceSMBPassword ? editedSMBPassword : nil) {
                            editedSMBPassword = ""
                            editingSMB = nil
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 260)
    }

    private func jellyfinTokenSheet(_ source: JellyfinSource) -> some View {
        NavigationStack {
            Form {
                Text(source.name).font(.headline)
                SecureField("新访问令牌", text: $replacementToken)
                if replacingToken { ProgressView() }
            }
            .navigationTitle("更新 Jellyfin 令牌")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingJellyfin = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并扫描") {
                        replacingToken = true
                        Task {
                            let updated = await library.updateJellyfinToken(id: source.id, token: replacementToken)
                            replacingToken = false
                            if updated { replacementToken = ""; editingJellyfin = nil }
                        }
                    }
                    .disabled(replacingToken || replacementToken.isEmpty)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 220)
    }

    private func embyTokenSheet(_ source: EmbySource) -> some View {
        NavigationStack {
            Form {
                Text(source.name).font(.headline)
                SecureField("新访问令牌", text: $replacementToken)
                if replacingToken { ProgressView() }
            }
            .navigationTitle("更新 Emby 令牌")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingEmby = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并扫描") {
                        replacingToken = true
                        Task {
                            let updated = await library.updateEmbyToken(id: source.id, token: replacementToken)
                            replacingToken = false
                            if updated { replacementToken = ""; editingEmby = nil }
                        }
                    }
                    .disabled(replacingToken || replacementToken.isEmpty)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 220)
    }

    private func plexTokenSheet(_ source: PlexSource) -> some View {
        NavigationStack {
            Form {
                Text(source.name).font(.headline)
                SecureField("新访问令牌", text: $replacementToken)
                if replacingToken { ProgressView() }
            }
            .navigationTitle("更新 Plex 令牌")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingPlex = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存并扫描") {
                        replacingToken = true
                        Task {
                            let updated = await library.updatePlexToken(id: source.id, token: replacementToken)
                            replacingToken = false
                            if updated { replacementToken = ""; editingPlex = nil }
                        }
                    }
                    .disabled(replacingToken || replacementToken.isEmpty)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 220)
    }

    private var jellyfinSheet: some View {
        NavigationStack {
            Form {
                TextField("https://server.example:8096/", text: $jellyfinAddress)
                Toggle("使用访问令牌", isOn: $jellyfinUsesToken)
                if jellyfinUsesToken {
                    SecureField("访问令牌", text: $jellyfinToken)
                } else {
                    TextField("用户名", text: $jellyfinUsername)
                    SecureField("密码", text: $jellyfinPassword)
                }
                Text("凭据用于登录，获得的令牌仅保存在本机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary)
                if addingJellyfin { ProgressView() }
            }
            .navigationTitle("连接 Jellyfin")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showJellyfin = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        addingJellyfin = true
                        Task {
                            let added: Bool
                            if jellyfinUsesToken {
                                added = await library.addJellyfin(address: jellyfinAddress, token: jellyfinToken)
                            } else {
                                added = await library.addJellyfin(address: jellyfinAddress,
                                                                  username: jellyfinUsername,
                                                                  password: jellyfinPassword)
                            }
                            addingJellyfin = false
                            if added {
                                jellyfinAddress = ""
                                jellyfinToken = ""
                                jellyfinUsername = ""
                                jellyfinPassword = ""
                                showJellyfin = false
                            }
                        }
                    }
                    .disabled(addingJellyfin || jellyfinAddress.isEmpty ||
                              (jellyfinUsesToken ? jellyfinToken.isEmpty : jellyfinUsername.isEmpty))
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
    }

    private var embySheet: some View {
        NavigationStack {
            Form {
                TextField("https://server.example:8096/", text: $embyAddress)
                Toggle("使用访问令牌", isOn: $embyUsesToken)
                if embyUsesToken {
                    SecureField("访问令牌", text: $embyToken)
                    TextField("用户 ID", text: $embyUserID)
                } else {
                    TextField("用户名", text: $embyUsername)
                    SecureField("密码", text: $embyPassword)
                }
                Text("凭据用于登录，获得的令牌仅保存在本机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary)
                if addingEmby { ProgressView() }
            }
            .navigationTitle("连接 Emby")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showEmby = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        addingEmby = true
                        Task {
                            let added: Bool
                            if embyUsesToken {
                                added = await library.addEmby(address: embyAddress, token: embyToken,
                                                              userID: embyUserID)
                            } else {
                                added = await library.addEmby(address: embyAddress,
                                                                  username: embyUsername,
                                                                  password: embyPassword)
                            }
                            addingEmby = false
                            if added {
                                embyAddress = ""
                                embyToken = ""
                                embyUserID = ""
                                embyUsername = ""
                                embyPassword = ""
                                showEmby = false
                            }
                        }
                    }
                    .disabled(addingEmby || embyAddress.isEmpty ||
                              (embyUsesToken ? (embyToken.isEmpty || embyUserID.isEmpty) : embyUsername.isEmpty))
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
    }

    private var plexSheet: some View {
        NavigationStack {
            Form {
                TextField("https://server.example:32400/", text: $plexAddress)
                Button(requestingPlexPIN ? "正在请求授权码" : "使用 Plex 账户授权") {
                    requestPlexAuthorization()
                }
                .disabled(requestingPlexPIN)
                if let plexPIN {
                    Text("在手机或电脑打开 plex.tv/link，输入授权码 \(plexPIN.code)。")
                    if plexAuthTask != nil { ProgressView("等待授权") }
                }
                SecureField("服务器访问令牌", text: $plexToken)
                Text("也可以直接输入服务器访问令牌。令牌仅保存在本机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary)
                if addingPlex { ProgressView() }
            }
            .navigationTitle("连接 Plex")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showPlex = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        addingPlex = true
                        Task {
                            let added = await library.addPlex(address: plexAddress, token: plexToken)
                            addingPlex = false
                            if added {
                                plexAddress = ""
                                plexToken = ""
                                showPlex = false
                            }
                        }
                    }
                    .disabled(addingPlex || plexAddress.isEmpty || plexToken.isEmpty)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 300)
        .onChange(of: showPlex) { _, shown in
            if !shown {
                plexAuthTask?.cancel()
                plexAuthTask = nil
                plexPIN = nil
            }
        }
    }

    private func requestPlexAuthorization() {
        plexAuthTask?.cancel()
        requestingPlexPIN = true
        Task {
            do {
                let pin = try await PlexAuthClient.createPIN()
                plexPIN = pin
                requestingPlexPIN = false
                plexAuthTask = Task {
                    do {
                        let token = try await PlexAuthClient.waitForToken(pin: pin)
                        guard !Task.isCancelled else { return }
                        plexToken = token
                        plexPIN = nil
                    } catch {
                        if !Task.isCancelled { library.errorMessage = error.localizedDescription }
                    }
                    plexAuthTask = nil
                }
            } catch {
                requestingPlexPIN = false
                library.errorMessage = error.localizedDescription
            }
        }
    }

    private var collectionSheet: some View {
        NavigationStack {
            Form { TextField("合集名称", text: $collectionName) }
                .navigationTitle("新建合集")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { showAddCollection = false }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("创建") {
                            library.addCollection(name: collectionName)
                            collectionName = ""
                            showAddCollection = false
                        }
                        .disabled(collectionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
        .frame(minWidth: 350, minHeight: 200)
    }

    private var smartPlaylistSheet: some View {
        NavigationStack {
            Form {
                TextField("播放列表名称", text: $smartName)
                TextField("标题包含（可选）", text: $smartTitle)
                TextField("剧集名称包含（可选）", text: $smartSeries)
                Toggle("只显示收藏", isOn: $smartFavorites)
                Toggle("只显示未看完", isOn: $smartUnwatched)
                Picker("最近添加", selection: $smartRecentDays) {
                    Text("不限").tag(0)
                    Text("7 天").tag(7)
                    Text("30 天").tag(30)
                    Text("90 天").tag(90)
                }
                Picker("最低 TMDB 评分", selection: $smartMinimumRating) {
                    Text("不限").tag(0.0)
                    Text("6 分").tag(6.0)
                    Text("7 分").tag(7.0)
                    Text("8 分").tag(8.0)
                }
            }
            .navigationTitle("新建智能播放列表")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddSmartPlaylist = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("创建") {
                        library.addSmartPlaylist(name: smartName, titleContains: smartTitle,
                                                 seriesContains: smartSeries,
                                                 favoritesOnly: smartFavorites,
                                                 unwatchedOnly: smartUnwatched,
                                                 addedWithinDays: smartRecentDays == 0 ? nil : smartRecentDays,
                                                 minimumRating: smartMinimumRating == 0 ? nil : smartMinimumRating)
                        smartName = ""
                        smartTitle = ""
                        smartSeries = ""
                        smartFavorites = false
                        smartUnwatched = false
                        smartRecentDays = 0
                        smartMinimumRating = 0
                        showAddSmartPlaylist = false
                    }
                    .disabled(smartName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    private var profilesSheet: some View {
        NavigationStack {
            Form {
                Section("现有资料") {
                    ForEach(library.viewerProfiles) { profile in
                        HStack {
                            Text(profile.name)
                            if profile.isChild { Text("儿童").foregroundStyle(.secondary) }
                            Spacer()
                            if profile.id != library.activeProfileID,
                               profile.id != library.viewerProfiles.first?.id {
                                Button("删除", role: .destructive) {
                                    library.removeViewerProfile(id: profile.id)
                                }
                            }
                        }
                    }
                }
                Section("新增资料") {
                    TextField("名称", text: $newProfileName)
                    Toggle("儿童资料", isOn: $newProfileIsChild)
                    Button("创建资料") {
                        library.addViewerProfile(name: newProfileName, isChild: newProfileIsChild)
                        newProfileName = ""
                    }
                    .disabled(newProfileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Section("家长 PIN") {
                    SecureField("4–8 位数字", text: $newProfilePIN)
                    Button("设置或更新 PIN") {
                        if library.configureProfilePIN(newProfilePIN) { newProfilePIN = "" }
                    }
                    .disabled(newProfilePIN.isEmpty)
                }
            }
            .navigationTitle("管理观看资料")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showProfiles = false }
                }
            }
        }
        .frame(minWidth: 380, minHeight: 420)
    }

    private var profileUnlockSheet: some View {
        NavigationStack {
            Form {
                SecureField("家长 PIN", text: $profileUnlockPIN)
            }
            .navigationTitle("切换成人资料")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { pendingProfileID = nil; showProfileUnlock = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("切换") {
                        if let pendingProfileID,
                           library.switchViewerProfile(id: pendingProfileID, pin: profileUnlockPIN) {
                            profileUnlockPIN = ""
                            self.pendingProfileID = nil
                            showProfileUnlock = false
                        }
                    }
                    .disabled(profileUnlockPIN.isEmpty)
                }
            }
        }
        .frame(minWidth: 350, minHeight: 220)
    }

    private var addAddressSheet: some View {
        NavigationStack {
            Form {
                TextField("https://example.com/video.mp4", text: $address)
                    .textContentType(.URL)
                    .accessibilityLabel("视频地址")
                Text("支持 HTTPS、局域网 HTTP 直链；FTP/FTPS/SFTP/NFS 直链由 VLC 播放，需填写已知文件地址且不在 URL 中包含密码。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .navigationTitle("添加网络视频")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showAddAddress = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("添加") {
                        if library.addRemote(address) {
                            address = ""
                            showAddAddress = false
                        }
                    }
                }
            }
        }
        .frame(minWidth: 350, minHeight: 230)
    }
}

private struct CloudAuthorizationQRCode: View {
    let content: String

    var body: some View {
        if let image = makeImage() {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel("115 授权二维码")
        } else {
            Text("二维码生成失败").foregroundStyle(.secondary)
        }
    }

    private func makeImage() -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(content.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let enlarged = output.transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        return CIContext().createCGImage(enlarged, from: enlarged.extent)
    }
}
