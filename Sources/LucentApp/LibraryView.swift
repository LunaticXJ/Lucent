import SwiftUI
import CoreImage.CIFilterBuiltins
import UniformTypeIdentifiers
#if os(iOS)
import UIKit

private struct ServerBrandIcon: View {
    let kind: String

    var body: some View {
        ZStack {
            switch kind {
            case "emby":
                Image("EmbyBrand")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 25, height: 25)
            case "fnos", "zspace", "ugreen":
                Image(EmbyServerKind(rawValue: kind)?.assetName ?? "EmbyBrand")
                    .resizable().scaledToFit().frame(width: 25, height: 25)
            case "jellyfin":
                Image("JellyfinBrand")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 25, height: 25)
            case "plex":
                Image("PlexBrand")
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 25, height: 25)
            default:
                Image(systemName: "rectangle.stack.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
            }
        }
        .frame(width: 25, height: 25)
        .accessibilityHidden(true)
    }
}

struct MobileSegmentedTabs<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selection: Value

    var body: some View {
        Picker("", selection: $selection) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Text(LocalizedStringKey(option.0)).tag(option.1)
            }
        }
        .pickerStyle(.segmented)
        .controlSize(.regular)
    }
}


#endif

private struct BrowsingFileSource: Identifiable {
    let id: UUID
    let name: String
}

struct LibraryView: View {
    private enum SortOrder { case newest, title }
    private enum MediaFilter { case all, unwatched, favorites }
    #if os(iOS)
    private enum MobileTab: Hashable { case home, sources, settings, search }
    @State private var mobileTab: MobileTab = .home
    @State private var mobileSearchText = ""
    @State private var mobileSubmittedSearchText = ""
    @State private var embyServerKind: ServerKind = .emby
    @State private var serverDraft = ServerAddressDraft()
    @State private var serverSaving = false
    @AppStorage("lucent.home.selectedCatalog") private var selectedHomeCatalog = "auto"
    @AppStorage("lucent.sources.selectedKind") private var mobileSourceKind = 1
    @State private var homeRefreshID = UUID()
    @State private var showSourceChooser = false
    private enum SourceChooserScope { case servers, library, storage }
    @State private var sourceChooserScope: SourceChooserScope = .library
    @State private var pendingSourceAddition: SourceAddition?
    @State private var pendingSourceRemoval: SourceRemoval?
    @State private var serverChecks: [UUID: ServerCheck] = [:]
    @State private var checkingServers: Set<UUID> = []
    private enum SourceAddition { case folder, smb, webDAV, cloud, dlna, emby, fnos, zspace, ugreen, jellyfin, plex, importDirectories }
    @State private var showStorageManager = false
    @State private var pendingStorageEdit: UUID?
    @State private var addStorageAfterDismiss = false
    private struct SourceRemoval: Identifiable {
        let id: UUID
        let name: String
        let kind: String
    }
    private struct ServerCheck {
        let date: Date
        let connected: Bool
    }

    #endif
    #if !os(iOS)
    @State private var nativePage: NativeAppPage = .home
    @StateObject private var nativeHomeModel = NativeHomeModel()
    #endif
    @State private var renamingServerID: UUID?
    @State private var serverNameDraft = ""
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
    @State private var showJellyfin = false
    @State private var showEmby = false
    @State private var showPlex = false
    @State private var showCloud = false
    @State private var showDLNA = false
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
    @State private var editingFolder: FolderSource?
    @State private var editedFolderName = ""
    @State private var browsingFolderID: UUID?
    @State private var browsingFileSource: BrowsingFileSource?
    @State private var editingSMB: SMBSource?
    @State private var editingJellyfin: JellyfinSource?
    @State private var editingEmby: EmbySource?
    @State private var browsingEmby: EmbySource?
    @State private var editingPlex: PlexSource?
    @State private var replacementToken = ""
    @State private var replacingToken = false
    @State private var embyReplacementUsesToken = false
    @State private var embyReplacementUsername = ""
    @State private var embyReplacementPassword = ""
    @State private var editedSMBUsername = ""
    @State private var editedSMBPassword = ""
    @State private var replaceSMBPassword = false
    @State private var selectedItemID: UUID?
    @State private var mobileLibraryCollectionPresented = false
    @State private var mobileDetailPresented = false
    @State private var serverMediaCounts: [UUID: (movies: Int, series: Int)] = [:]
    @State private var showCacheSettings = false
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
            mobilePresentedShell
            #elseif os(tvOS) || os(macOS)
            nativeShell
            #else
            navigationBody
            #endif
        }
            .onChange(of: scenePhase) {
                if scenePhase == .active {
                    library.refreshFolders()
                    Task { await library.syncNow() }
                } else {
                    ArtworkImageDecoder.clear()
                    Task { await library.flushPersistence() }
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
            .sheet(isPresented: $showCacheSettings) { CacheSettingsView() }
    }

    #if !os(iOS)
    private var nativeShell: some View {
        NativeAppShell(page: $nativePage, home: {
            NativeHomeView(model: nativeHomeModel, showSources: { nativePage = .sources }).environmentObject(library)
        }, sources: { navigationBody }, search: {
            NativeSearchView().environmentObject(library)
        }, settings: { nativeSettings })
        .sheet(isPresented: $showProfiles) { profilesSheet }
        .sheet(isPresented: $showProfileUnlock) { profileUnlockSheet }
        .sheet(isPresented: $showTrakt, onDismiss: { traktAuthTask?.cancel(); traktAuthTask = nil }) { traktSheet }
    }
    private var nativeSettings: some View {
        AppSettingsView(
            sortSelection: Binding(get: { sortOrder == .newest ? "newest" : "title" }, set: { sortOrder = $0 == "title" ? .title : .newest }),
            filterSelection: Binding(get: { switch mediaFilter { case .all: "all"; case .unwatched: "unwatched"; case .favorites: "favorites" } },
                set: { mediaFilter = $0 == "favorites" ? .favorites : ($0 == "unwatched" ? .unwatched : .all) }),
            onAction: { action in
                switch action {
                case .profiles: showProfiles = true
                case .trakt: showTrakt = true
                case .enrichMetadata: Task { await library.enrichMissingMetadata() }
                case .purgeMissing: library.purgeMissingItems()
                }
            }, onSelectProfile: { id in
                if library.activeProfile?.isChild == true && library.viewerProfiles.first(where: { $0.id == id })?.isChild == false {
                    pendingProfileID = id; profileUnlockPIN = ""; showProfileUnlock = true
                } else { _ = library.switchViewerProfile(id: id) }
            }).environmentObject(library)
    }
    #endif

    #if os(iOS)
    private var effectiveHomeCatalog: String {
        if selectedHomeCatalog == "auto" {
            if library.localLibraryItems.isEmpty {
                if let source = library.embySources.first { return "emby:\(source.id.uuidString)" }
                if let source = library.jellyfinSources.first { return "jellyfin:\(source.id.uuidString)" }
                if let source = library.plexSources.first { return "plex:\(source.id.uuidString)" }
            }
            return "library"
        }
        if selectedHomeCatalog == "library" { return "library" }
        let parts = selectedHomeCatalog.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return "library" }
        switch parts[0] {
        case "emby" where library.embySources.contains(where: { $0.id == id }): return selectedHomeCatalog
        case "jellyfin" where library.jellyfinSources.contains(where: { $0.id == id }): return selectedHomeCatalog
        case "plex" where library.plexSources.contains(where: { $0.id == id }): return selectedHomeCatalog
        default: return "library"
        }
    }

    private var homeCatalogTitle: String {
        let key = effectiveHomeCatalog
        if key == "library" { return "聚合媒体库" }
        if let source = library.embySources.first(where: { key == "emby:\($0.id.uuidString)" }) { return source.name }
        if let source = library.jellyfinSources.first(where: { key == "jellyfin:\($0.id.uuidString)" }) { return source.name }
        if let source = library.plexSources.first(where: { key == "plex:\($0.id.uuidString)" }) { return source.name }
        return "聚合媒体库"
    }

    private var homeCatalogKind: String {
        if effectiveHomeCatalog.hasPrefix("emby:") {
            return library.embySources.first(where: { effectiveHomeCatalog == "emby:\($0.id.uuidString)" })?.kind.rawValue ?? "emby"
        }
        if effectiveHomeCatalog.hasPrefix("jellyfin:") { return "jellyfin" }
        if effectiveHomeCatalog.hasPrefix("plex:") { return "plex" }
        return "library"
    }

    private var mobileShell: some View {
        Group {
            if #available(iOS 26.0, *) {
                TabView(selection: $mobileTab) {
                    Tab("首页", systemImage: mobileTab == .home ? "house.fill" : "house",
                        value: MobileTab.home) { mobileHomeTab }
                    Tab("片源", systemImage: mobileTab == .sources ? "externaldrive.fill" : "externaldrive",
                        value: MobileTab.sources) { navigationBody }
                    Tab("设置", systemImage: mobileTab == .settings ? "gearshape.fill" : "gearshape",
                        value: MobileTab.settings) { mobileSettingsShell }
                    Tab(value: MobileTab.search, role: .search) { mobileSearchTab }
                }
                .tabBarMinimizeBehavior(.onScrollDown)
            } else {
                TabView(selection: $mobileTab) {
                    mobileHomeTab
                        .tabItem { Label("首页", systemImage: mobileTab == .home ? "house.fill" : "house") }
                        .tag(MobileTab.home)
                    navigationBody
                        .tabItem { Label("片源", systemImage: mobileTab == .sources ? "externaldrive.fill" : "externaldrive") }
                        .tag(MobileTab.sources)
                    mobileSettingsShell
                        .tabItem { Label("设置", systemImage: mobileTab == .settings ? "gearshape.fill" : "gearshape") }
                        .tag(MobileTab.settings)
                    mobileSearchTab
                        .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                        .tag(MobileTab.search)
                }
            }
        }
        .tint(.primary)
        .fileImporter(isPresented: $showFileImporter, allowedContentTypes: [.movie, .video, .audiovisualContent, .item]) { result in
            switch result {
            case .success(let url): library.addFile(url)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
        .fileImporter(isPresented: $showFolderImporter, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): library.addFolder(url)
            case .failure(let error): library.errorMessage = error.localizedDescription
            }
        }
    }

    /// One presentation owner for all tabs. Sharing a binding between a hidden
    /// tab and the visible tab can dismiss the sheet as soon as it is presented.
    private var mobilePresentedShell: some View {
        mobileShell
            .sheet(isPresented: $showAddAddress) { addAddressSheet }
            .sheet(isPresented: $showSMB) { smbSheet }
            #if os(iOS)
            .sheet(isPresented: $showSourceChooser, onDismiss: performSourceAddition) { sourceChooser }
            .sheet(isPresented: $showStorageManager, onDismiss: finishStorageManagement) {
                NavigationStack {
                    StorageManagementView(add: { addStorageAfterDismiss = true; showStorageManager = false },
                        edit: { pendingStorageEdit = $0; showStorageManager = false })
                }.environmentObject(library).tint(.gray)
            }
            .confirmationDialog("移除 \(pendingSourceRemoval?.name ?? "片源")？",
                                isPresented: Binding(get: { pendingSourceRemoval != nil },
                                                     set: { if !$0 { pendingSourceRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingSourceRemoval) { source in
                Button("移除片源", role: .destructive) { removePendingSource(source) }
                Button("取消", role: .cancel) { pendingSourceRemoval = nil }
            } message: { _ in
                Text("会移除该片源的本机配置与关联媒体记录，存储中的原始文件不会删除。")
            }
            .sheet(item: $editingFolder) { source in folderEditSheet(source) }
            .sheet(isPresented: Binding(get: { browsingFolderID != nil }, set: { if !$0 { browsingFolderID = nil } })) {
                if let id = browsingFolderID {
                    NavigationStack { MobileFolderBrowserView(sourceID: id).environmentObject(library) }
                }
            }
            .sheet(item: $browsingFileSource) { source in
                NavigationStack {
                    MobileScannedSourceBrowserView(sourceID: source.id, sourceName: source.name)
                        .environmentObject(library)
                }
            }
            #endif
            .sheet(item: $editingSMB) { source in smbCredentialsSheet(source) }
            #if os(iOS)
            .sheet(item: $editingJellyfin) { source in
                mobileServerSheet(.jellyfin, existingID: source.id) { editingJellyfin = nil }
            }
            .sheet(item: $editingEmby) { source in
                mobileServerSheet(ServerKind(source.kind), existingID: source.id) { editingEmby = nil }
            }
            #else
            .sheet(item: $editingJellyfin) { source in jellyfinTokenSheet(source) }
            .sheet(item: $editingEmby) { source in embyTokenSheet(source) }
            #endif
            .sheet(isPresented: Binding(get: { renamingServerID != nil },
                                        set: { if !$0 { renamingServerID = nil } })) {
                serverNameSheet
            }
            .sheet(item: $browsingEmby) { source in
                EmbyBrowserView(source: source).environmentObject(library)
            }
            #if os(iOS)
            .sheet(item: $editingPlex) { source in
                mobileServerSheet(.plex, existingID: source.id) { editingPlex = nil }
            }
            #else
            .sheet(item: $editingPlex) { source in plexTokenSheet(source) }
            #endif
            .sheet(isPresented: $showWebDAV) { webDAVSheet }
            .sheet(item: $editingWebDAV) { source in webDAVCredentialsSheet(source) }
            #if os(iOS)
            .sheet(isPresented: $showJellyfin) { mobileServerSheet(.jellyfin) { showJellyfin = false } }
            .sheet(isPresented: $showEmby) { mobileServerSheet(embyServerKind) { showEmby = false } }
            .sheet(isPresented: $showPlex) { mobileServerSheet(.plex) { showPlex = false } }
            #else
            .sheet(isPresented: $showJellyfin) { jellyfinSheet }
            .sheet(isPresented: $showEmby) { embySheet }
            .sheet(isPresented: $showPlex) { plexSheet }
            #endif
            .sheet(isPresented: $showCloud) { cloudSheet }
            .sheet(isPresented: $showDLNA) { dlnaSheet }
            .sheet(item: $editingCloud) { source in cloudTokenSheet(source) }
            .sheet(isPresented: $showAddCollection) { collectionSheet }
            .sheet(isPresented: $showAddSmartPlaylist) { smartPlaylistSheet }
            #if !os(tvOS)
            .sheet(isPresented: $showBrowserUpload, onDismiss: stopBrowserUpload) {
                browserUploadSheet
            }
            #endif
    }

    private var mobileHomeTab: some View {
        NavigationStack {
            Group {
                let catalog = effectiveHomeCatalog
                if catalog == "library" {
                    MobileHomeView(showSources: { mobileSourceKind = 0; mobileTab = .sources }, localLibrary: true,
                                   onCollectionChange: { mobileLibraryCollectionPresented = $0 },
                                   refreshID: homeRefreshID, detailPresented: $mobileDetailPresented)
                } else if catalog.hasPrefix("emby:") {
                    MobileHomeView(showSources: { mobileTab = .sources },
                                   preferredSourceID: UUID(uuidString: String(catalog.dropFirst(5))),
                                   refreshID: homeRefreshID,
                                   showCacheSettings: { showCacheSettings = true },
                                   detailPresented: $mobileDetailPresented,
                                   onScrollStateChange: { _ in })
                } else {
                    MobileServerCatalogView(catalog: catalog, refreshID: homeRefreshID,
                                            detailPresented: $mobileDetailPresented)
                }
            }
            .environmentObject(library)
            .toolbar(.hidden, for: .navigationBar)
            .overlay(alignment: .topLeading) {
                if mobileTab == .home {
                    Menu {
                        Picker("首页内容", selection: Binding(get: { effectiveHomeCatalog },
                                                        set: { selectedHomeCatalog = $0 })) {
                            Label("聚合媒体库", systemImage: "rectangle.stack").tag("library")
                        if !library.embySources.isEmpty || !library.jellyfinSources.isEmpty || !library.plexSources.isEmpty {
                            ForEach(library.embySources) { source in
                                Label(source.name, image: source.kind.assetName)
                                    .tag("emby:\(source.id.uuidString)")
                            }
                            ForEach(library.jellyfinSources) { source in
                                Label(source.name, image: "JellyfinBrand")
                                    .tag("jellyfin:\(source.id.uuidString)")
                            }
                            ForEach(library.plexSources) { source in
                                Label(source.name, image: "PlexBrand")
                                    .tag("plex:\(source.id.uuidString)")
                            }
                        }
                        }
                        if homeCatalogKind != "library" {
                            Divider()
                            Button("刷新首页", systemImage: "arrow.clockwise") { homeRefreshID = UUID() }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            ServerBrandIcon(kind: homeCatalogKind)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(Color.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .modifier(LucentGlass(shape: Capsule()))
                    }
                    .accessibilityLabel("首页片源：\(homeCatalogTitle)")
                    .padding(.leading, 20)
                    .padding(.top, 8)
                }
            }
        }
            .onChange(of: effectiveHomeCatalog) { _, _ in
                mobileLibraryCollectionPresented = false
                mobileDetailPresented = false
            }
    }

    private var mobileSearchTab: some View {
        MobileSearchView(catalog: effectiveHomeCatalog,
                         detailPresented: $mobileDetailPresented,
                         query: $mobileSearchText,
                         submittedQuery: $mobileSubmittedSearchText)
            .environmentObject(library)
    }

    private var mobileSettingsShell: some View {
        NavigationStack {
            AppSettingsView(
                        sortSelection: Binding(get: { sortOrder == .newest ? "newest" : "title" },
                                               set: { sortOrder = $0 == "title" ? .title : .newest }),
                        filterSelection: Binding(get: {
                            switch mediaFilter {
                            case .all: "all"
                            case .unwatched: "unwatched"
                            case .favorites: "favorites"
                            }
                        }, set: {
                            switch $0 {
                            case "unwatched": mediaFilter = .unwatched
                            case "favorites": mediaFilter = .favorites
                            default: mediaFilter = .all
                            }
                        }),
                        onAction: handleAppSettingsAction,
                        onSelectProfile: selectMobileProfile)
                .environmentObject(library)
        }
        .toggleStyle(SwitchToggleStyle(tint: LucentUI.switchTint))
        .tint(.gray)
    }

    private func selectMobileProfile(_ id: UUID) {
        guard library.activeProfile?.id != id else { return }
        if library.activeProfile?.isChild == true,
           library.viewerProfiles.first(where: { $0.id == id })?.isChild == false {
            pendingProfileID = id
            profileUnlockPIN = ""
            showProfileUnlock = true
        } else {
            _ = library.switchViewerProfile(id: id)
        }
    }

    private func handleAppSettingsAction(_ action: AppSettingsAction) {
        switch action {
        case .profiles: showProfiles = true
        case .trakt: showTrakt = true
        case .enrichMetadata: Task { await library.enrichMissingMetadata() }
        case .purgeMissing: library.purgeMissingItems()
        }
    }

    #endif

    #if os(iOS)
    @ViewBuilder
    private var mobileSourcesContent: some View {
        VStack(alignment: .leading, spacing: 20) {
            MobileSegmentedTabs(options: [("影视服务器", 1), ("聚合媒体库", 0)], selection: $mobileSourceKind)
            if mobileSourceKind == 0 {
                AggregateLibraryOverview(manageStorage: { showStorageManager = true }, importSource: { showStorageManager = true })
                    .environmentObject(library)
            } else {
                serverGrid
            }
        }
    }

    private var mobileAddSourceMenu: some View {
        Button { sourceChooserScope = mobileSourceKind == 1 ? .servers : .library; showSourceChooser = true } label: {
            Image(systemName: "plus").font(.system(size: 19, weight: .semibold))
                .frame(width: 44, height: 44)
                .modifier(LucentGlass(shape: Circle()))
                .clipShape(Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(mobileSourceKind == 1 ? "添加影视服务器" : "添加片源")
    }

    private var sourceChooser: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if sourceChooserScope == .servers {
                        additionSection("影视服务器", detail: "直接使用服务器中的海报、分类和观看记录") {
                            additionRow("Emby", detail: "账户密码或访问令牌", brand: "EmbyBrand", icon: "server.rack", choice: .emby)
                            additionRow("Jellyfin", detail: "连接自己的影音服务器", brand: "JellyfinBrand", icon: "server.rack", choice: .jellyfin)
                            additionRow("Plex", detail: "账户授权或访问令牌", brand: "PlexBrand", icon: "server.rack", choice: .plex)
                            additionRow("飞牛私有云", detail: "连接飞牛影视媒体库", brand: "FnOSBrand", icon: "server.rack", choice: .fnos)
                            additionRow("极空间影视", detail: "连接极影视媒体库", brand: "ZSpaceBrand", icon: "server.rack", choice: .zspace)
                            additionRow("绿联云影视", detail: "连接绿联影视中心", brand: "UGREENBrand", icon: "server.rack", choice: .ugreen)
                        }
                    }
                    if sourceChooserScope == .library {
                        additionSection("文件源", detail: "从已连接的存储选择目录，独立命名并扫描入库") {
                            additionRow("从存储导入目录", detail: "支持跨目录多选与批量命名", icon: "folder.badge.plus", choice: .importDirectories)
                        }
                    }
                    if sourceChooserScope != .servers {
                        additionSection("添加存储", detail: "仅建立连接，导入目录后才扫描入库") {
                            additionRow("本地文件夹", detail: "选择“文件”App 中的目录", icon: "folder", choice: .folder)
                            additionRow("SMB 共享", detail: "NAS、电脑与局域网共享", icon: "externaldrive", choice: .smb)
                            additionRow("WebDAV", detail: "连接 WebDAV 存储服务", icon: "network", choice: .webDAV)
                            additionRow("网盘", detail: "115、123、百度及其他已支持的网盘", icon: "cloud", choice: .cloud)
                        }
                        additionSection("局域网设备", detail: "连接 DLNA 设备并浏览真实目录") {
                            additionRow("DLNA", detail: "发现或手动连接媒体设备", icon: "dot.radiowaves.left.and.right", choice: .dlna)
                        }
                    }
                }.padding(LucentUI.pageInset)
            }
            .background(LucentUI.page)
            .navigationTitle(LocalizedStringKey(sourceChooserScope == .servers ? "添加影视服务器" : sourceChooserScope == .storage ? "添加存储" : "添加片源")).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSourceChooser = false } } }
        }
        .tint(.gray)
    }

    private func additionSection<Content: View>(_ title: String, detail: String,
                                                @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(LocalizedStringKey(title)).font(.headline)
            Text(LocalizedStringKey(detail)).font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 2, content: content)
                .padding(6)
                .background(LucentUI.panel, in: RoundedRectangle(cornerRadius: 22))
        }
    }

    private func additionRow(_ title: String, detail: String, brand: String? = nil,
                             icon: String, choice: SourceAddition) -> some View {
        Button { pendingSourceAddition = choice; showSourceChooser = false } label: {
            HStack(spacing: 14) {
                Group {
                    if let brand { Image(brand).resizable().scaledToFit() }
                    else { Image(systemName: icon).font(.system(size: 22, weight: .medium)) }
                }.frame(width: 32, height: 32).padding(8)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringKey(title)).font(.system(size: 16, weight: .semibold))
                    Text(LocalizedStringKey(detail)).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }.padding(8).frame(minHeight: 64).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.primary)
    }

    private func performSourceAddition() {
        guard let choice = pendingSourceAddition else { return }
        pendingSourceAddition = nil
        switch choice {
        case .importDirectories: showStorageManager = true
        case .folder: showFolderImporter = true
        case .smb: showSMB = true
        case .webDAV: showWebDAV = true
        case .cloud:
            cloudProvider = .pan115
            clearCloudAuthorizationDraft()
            showCloud = true
        case .dlna: showDLNA = true
        case .emby: prepareNewServer(.emby); showEmby = true
        case .fnos: prepareNewServer(.fnos); showEmby = true
        case .zspace: prepareNewServer(.zspace); showEmby = true
        case .ugreen: prepareNewServer(.ugreen); showEmby = true
        case .jellyfin: prepareNewServer(.jellyfin); showJellyfin = true
        case .plex: prepareNewServer(.plex); showPlex = true
        }
    }

    private func finishStorageManagement() {
        if addStorageAfterDismiss {
            addStorageAfterDismiss = false
            sourceChooserScope = .storage
            showSourceChooser = true
            return
        }
        guard let id = pendingStorageEdit else { return }
        pendingStorageEdit = nil
        if let source = library.folders.first(where: { $0.id == id }) { editedFolderName = source.name; editingFolder = source }
        else if let source = library.smbSources.first(where: { $0.id == id }) {
            editedSMBUsername = source.username; editedSMBPassword = ""; replaceSMBPassword = false; editingSMB = source
        } else if let source = library.webDAVSources.first(where: { $0.id == id }) {
            editedWebDAVUsername = source.username; editedWebDAVPassword = ""; replaceWebDAVPassword = false; editingWebDAV = source
        } else if let source = library.cloudSources.first(where: { $0.id == id }) {
            cloudToken = ""; cloudClientID = source.oauthClientID ?? ""; cloudRefreshToken = ""; editingCloud = source
        }
    }

    private func clearCloudAuthorizationDraft() {
        cloudToken = ""; cloudRefreshToken = ""; cloudClientID = ""; cloudClientSecret = ""
        cloudName = ""; dropboxAuthorizationCode = ""; dropboxAuthorizationMessage = nil
        dropboxAuthorization = nil; baiduDeviceCode = nil; open115Authorization = nil
    }

    private func removePendingSource(_ source: SourceRemoval) {
        switch source.kind {
        case "folder": library.removeFolder(id: source.id)
        case "smb": library.removeSMB(id: source.id)
        case "webDAV": library.removeWebDAV(id: source.id)
        case "cloud": library.removeCloud(id: source.id)
        case "emby": library.removeEmby(id: source.id)
        case "jellyfin": library.removeJellyfin(id: source.id)
        case "plex": library.removePlex(id: source.id)
        default: break
        }
        serverChecks[source.id] = nil; serverMediaCounts[source.id] = nil
        if selectedHomeCatalog.hasSuffix(source.id.uuidString) { selectedHomeCatalog = "auto" }
        pendingSourceRemoval = nil
    }

    private var serverGrid: some View {
        VStack(alignment: .leading, spacing: 18) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155, maximum: 280), spacing: 12)], spacing: 12) {
                ForEach(library.embySources) { source in
                    serverCard(id: source.id, name: source.name, address: source.baseAddress, kind: "emby",
                               username: source.username ?? source.userID,
                               counts: serverMediaCounts[source.id], brandAsset: source.kind.assetName) {
                        selectedHomeCatalog = "emby:\(source.id.uuidString)"; mobileTab = .home
                    }
                    .task(id: source) {
                        await loadMediaCounts(source)
                        await library.resolveServerUsername(id: source.id)
                    }
                    .contextMenu {
                        Button("刷新连接与统计", systemImage: "arrow.clockwise") {
                            Task { await loadMediaCounts(source, force: true) }
                        }.disabled(checkingServers.contains(source.id))
                        Button("编辑服务器", systemImage: "pencil") {
                            serverDraft = ServerAddressDraft(address: source.baseAddress,
                                                             name: source.displayName ?? "")
                            if serverDraft.path == "/emby/" { serverDraft.path = "" }
                            replacementToken = ""; embyReplacementUsername = source.username ?? ""
                            embyReplacementPassword = ""; embyReplacementUsesToken = source.usesTokenLogin ?? false
                            editingEmby = source
                        }
                        Button("移除服务器", systemImage: "trash", role: .destructive) {
                            pendingSourceRemoval = .init(id: source.id, name: source.name, kind: "emby")
                        }
                    }
                }
                ForEach(library.jellyfinSources) { source in
                    serverCard(id: source.id, name: source.name, address: source.baseAddress, kind: "jellyfin",
                               username: source.username ?? source.userID,
                               counts: serverMediaCounts[source.id]) {
                        selectedHomeCatalog = "jellyfin:\(source.id.uuidString)"; mobileTab = .home
                    }
                    .task(id: source) {
                        await loadMediaCounts(source)
                        await library.resolveServerUsername(id: source.id)
                    }
                    .contextMenu {
                        Button("刷新连接与统计", systemImage: "arrow.clockwise") {
                            Task { await loadMediaCounts(source, force: true) }
                        }.disabled(checkingServers.contains(source.id))
                        Button("编辑服务器", systemImage: "pencil") {
                            serverDraft = ServerAddressDraft(address: source.baseAddress,
                                                             name: source.displayName ?? "")
                            replacementToken = ""; jellyfinUsername = source.username ?? ""; jellyfinPassword = ""
                            jellyfinUsesToken = source.usesTokenLogin ?? false; editingJellyfin = source
                        }
                        Button("移除服务器", systemImage: "trash", role: .destructive) {
                            pendingSourceRemoval = .init(id: source.id, name: source.name, kind: "jellyfin")
                        }
                    }
                }
                ForEach(library.plexSources) { source in
                    serverCard(id: source.id, name: source.name, address: source.baseAddress, kind: "plex",
                               username: source.username ?? "Plex 账户",
                               counts: serverMediaCounts[source.id]) {
                        selectedHomeCatalog = "plex:\(source.id.uuidString)"; mobileTab = .home
                    }
                    .task(id: source) {
                        await loadMediaCounts(source)
                        await library.resolveServerUsername(id: source.id)
                    }
                    .contextMenu {
                        Button("刷新连接与统计", systemImage: "arrow.clockwise") {
                            Task { await loadMediaCounts(source, force: true) }
                        }.disabled(checkingServers.contains(source.id))
                        Button("编辑服务器", systemImage: "pencil") {
                            serverDraft = ServerAddressDraft(address: source.baseAddress,
                                                             name: source.displayName ?? "", defaultPort: "32400")
                            replacementToken = ""; editingPlex = source
                        }
                        Button("移除服务器", systemImage: "trash", role: .destructive) {
                            pendingSourceRemoval = .init(id: source.id, name: source.name, kind: "plex")
                        }
                    }
                }
            }
            if library.embySources.isEmpty && library.jellyfinSources.isEmpty && library.plexSources.isEmpty {
                ContentUnavailableView("尚无影视服务器", systemImage: "server.rack",
                                       description: Text("点击右上角的加号连接 Emby、Jellyfin 或 Plex"))
            }
        }
    }

    private func serverCard(id: UUID, name: String, address: String, kind: String, username: String,
                            counts: (movies: Int, series: Int)?, brandAsset: String? = nil,
                            action: @escaping () -> Void) -> some View {
        let brand: Color = kind == "plex" ? .orange : kind == "jellyfin" ? .purple : .green
        return Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 4) {
                    Text(name)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    Image(brandAsset ?? (kind == "emby" ? "EmbyBrand" : kind == "jellyfin" ? "JellyfinBrand" : "PlexBrand"))
                        .resizable().scaledToFit().frame(width: 34, height: 34)
                }
                Text("电影 \(counts.map { String($0.movies) } ?? "—") · 剧集 \(counts.map { String($0.series) } ?? "—")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.76))
                    .padding(.top, 5)
                Spacer(minLength: 12)
                HStack(spacing: 5) {
                    if checkingServers.contains(id) { ProgressView().controlSize(.mini).tint(.white) }
                    else { Circle().fill(serverChecks[id].map { $0.connected ? Color.green : Color.orange } ?? Color.gray).frame(width: 5, height: 5) }
                    Text(checkingServers.contains(id) ? "正在连接" : serverChecks[id].map { $0.connected ? "连接正常" : "暂不可用 · 长按重试" } ?? "尚未检测")
                    Spacer(minLength: 0)
                    if selectedHomeCatalog == "\(kind):\(id.uuidString)" { Image(systemName: "checkmark.circle.fill") }
                }.font(.system(size: 11)).foregroundStyle(.white.opacity(0.8))
                .padding(.bottom, 7)
                Text("\(URL(string: address)?.host ?? address) · \(username)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .foregroundStyle(.white)
            .padding(15)
            .frame(maxWidth: .infinity, minHeight: 154, alignment: .leading)
            .background(LinearGradient(colors: [Color(white: 0.13), brand.opacity(0.35)],
                                       startPoint: .leading, endPoint: .trailing),
                        in: RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(
                .white.opacity(selectedHomeCatalog == "\(kind):\(id.uuidString)" ? 0.5 : 0.08), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开此服务器首页，长按可编辑、刷新或移除")
    }

    @MainActor
    private func checkServer(_ id: UUID, force: Bool,
                             read: () async throws -> (movies: Int, series: Int)) async {
        guard !checkingServers.contains(id),
              force || serverChecks[id].map({ Date().timeIntervalSince($0.date) > 300 }) != false else { return }
        checkingServers.insert(id)
        defer { checkingServers.remove(id) }
        do {
            let counts = try await read()
            try Task.checkCancellation()
            serverMediaCounts[id] = counts
            serverChecks[id] = .init(date: Date(), connected: true)
        } catch {
            guard !Task.isCancelled else { return }
            serverChecks[id] = .init(date: Date(), connected: false)
        }
    }

    private func loadMediaCounts(_ source: EmbySource, force: Bool = false) async {
        await checkServer(source.id, force: force) {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await EmbyClient.mediaCounts(source: source, token: token)
        }
    }
    private func loadMediaCounts(_ source: JellyfinSource, force: Bool = false) async {
        await checkServer(source.id, force: force) {
            guard let token = try KeychainPasswordStore.jellyfinToken(for: source.id), !token.isEmpty else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await JellyfinClient.mediaCounts(source: source, token: token)
        }
    }
    private func loadMediaCounts(_ source: PlexSource, force: Bool = false) async {
        await checkServer(source.id, force: force) {
            guard let token = try KeychainPasswordStore.plexToken(for: source.id), !token.isEmpty else {
                throw URLError(.userAuthenticationRequired)
            }
            return try await PlexClient.mediaCounts(source: source, token: token)
        }
    }

    private func refreshServerCounts(_ id: UUID) async {
        if let source = library.embySources.first(where: { $0.id == id }) { await loadMediaCounts(source, force: true) }
        else if let source = library.jellyfinSources.first(where: { $0.id == id }) { await loadMediaCounts(source, force: true) }
        else if let source = library.plexSources.first(where: { $0.id == id }) { await loadMediaCounts(source, force: true) }
    }

    private enum ServerKind: String {
        case emby = "Emby", jellyfin = "Jellyfin", plex = "Plex"
        case fnos = "飞牛私有云", zspace = "极空间影视", ugreen = "绿联云影视"
        init(_ kind: EmbyServerKind) {
            switch kind {
            case .emby: self = .emby
            case .fnos: self = .fnos
            case .zspace: self = .zspace
            case .ugreen: self = .ugreen
            }
        }
        var embyKind: EmbyServerKind? {
            switch self {
            case .emby: .emby
            case .fnos: .fnos
            case .zspace: .zspace
            case .ugreen: .ugreen
            default: nil
            }
        }
    }

    private func prepareNewServer(_ kind: ServerKind) {
        serverDraft = ServerAddressDraft()
        if let nas = kind.embyKind, nas != .emby {
            serverDraft.port = nas.defaultPort
            serverDraft.usesHTTPS = nas.usesHTTPS
        }
        embyServerKind = kind
        serverSaving = false
        embyToken = ""; embyUserID = ""; embyUsername = ""; embyPassword = ""
        jellyfinToken = ""; jellyfinUsername = ""; jellyfinPassword = ""
        plexToken = ""; replacementToken = ""
        embyUsesToken = false; jellyfinUsesToken = false
    }

    private var serverAddressFields: some View {
        VStack(spacing: 20) {
            LucentFormField("名称") {
                TextField("选填，默认使用服务器地址", text: $serverDraft.name)
                    .textInputAutocapitalization(.never)
            }
            LucentFormField("协议") {
                Toggle("HTTPS", isOn: $serverDraft.usesHTTPS)
            }
            LucentFormField("服务器地址") {
                TextField("域名、IP 或完整服务器网址", text: $serverDraft.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onChange(of: serverDraft.host) { _, _ in serverDraft.absorbPastedAddress() }
            }
            LucentFormField("路径") {
                TextField("选填，例如 /emby", text: $serverDraft.path)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(nil)
            }
            LucentFormField("端口号") {
                TextField(serverDraft.usesHTTPS ? "选填，默认 443" : "选填，默认 80", text: $serverDraft.port)
                    .keyboardType(.numberPad)
            }
        }
    }

    @ViewBuilder private func serverCredentialFields(_ kind: ServerKind, editing: Bool) -> some View {
        switch kind {
        case .emby, .fnos, .zspace, .ugreen:
            LucentFormField("登录方式") {
                Toggle("使用访问令牌", isOn: editing ? $embyReplacementUsesToken : $embyUsesToken)
            }
            if editing ? embyReplacementUsesToken : embyUsesToken {
                LucentFormField("访问令牌") {
                    SecureField(editing ? "留空则沿用原令牌" : "必填", text: editing ? $replacementToken : $embyToken)
                }
                if !editing {
                    LucentFormField("用户 ID") { TextField("必填", text: $embyUserID) }
                }
            } else {
                LucentFormField("用户名") {
                    TextField(editing ? "原用户名" : "必填",
                              text: editing ? $embyReplacementUsername : $embyUsername)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                }
                serverPasswordField(editing ? $embyReplacementPassword : $embyPassword, editing: editing)
            }
        case .jellyfin:
            LucentFormField("登录方式") { Toggle("使用访问令牌", isOn: $jellyfinUsesToken) }
            if jellyfinUsesToken {
                LucentFormField("访问令牌") {
                    SecureField(editing ? "留空则沿用原令牌" : "必填",
                                text: editing ? $replacementToken : $jellyfinToken)
                }
            } else {
                LucentFormField("用户名") {
                    TextField(editing ? "原用户名" : "必填", text: $jellyfinUsername)
                        .textInputAutocapitalization(.never)
                        .textContentType(.username)
                }
                serverPasswordField($jellyfinPassword, editing: editing)
            }
        case .plex:
            if !editing {
                Button(requestingPlexPIN ? "正在请求授权码" : "使用 Plex 账户授权") {
                    requestPlexAuthorization()
                }
                .buttonStyle(.borderedProminent)
                .disabled(requestingPlexPIN)
                if let plexPIN {
                    Link("打开 Plex 授权网站", destination: URL(string: "https://plex.tv/link")!)
                    Text("授权码：\(plexPIN.code)").font(.headline.monospaced()).textSelection(.enabled)
                    if plexAuthTask != nil { ProgressView("等待授权") }
                }
            }
            LucentFormField("访问令牌") {
                SecureField(editing ? "留空则沿用原令牌" : "必填",
                            text: editing ? $replacementToken : $plexToken)
            }
        }
    }

    private func serverPasswordField(_ password: Binding<String>, editing: Bool) -> some View {
        LucentFormField("密码") {
            LucentPasswordInput(text: password, visible: $serverDraft.showsPassword,
                placeholder: editing ? "账户不变时可留空" : "选填，服务器允许时可留空")
        }
    }

    private func mobileServerSheet(_ kind: ServerKind, existingID: UUID? = nil,
                                   dismiss: @escaping () -> Void) -> some View {
        let editing = existingID != nil
        return NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    serverAddressFields
                    serverCredentialFields(kind, editing: editing)
                    if let address = serverDraft.address {
                        Label(address, systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if editing {
                        Text("同一服务器可添加多个账户。修改用户名将重新登录，原账户的本机数据会被替换；留空密码仅在账户不变时沿用令牌。")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if serverSaving { LucentLoadingView(title: "正在连接服务器") }
                }
                .padding(.horizontal, LucentUI.pageInset)
                .padding(.top, 24)
                .padding(.bottom, 36)
            }
            .background(LucentUI.page)
            .navigationTitle(editing ? "编辑 \(kind.rawValue)" : "添加 \(kind.rawValue)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                LucentEditorToolbar(actionTitle: editing ? "保存" : "添加", busy: serverSaving,
                    canSave: canSaveServer(kind, editing: editing), close: dismiss) {
                    Task { await saveServer(kind, existingID: existingID, dismiss: dismiss) }
                }
            }
        }
        .modifier(LucentSheetStyle(role: .editor))
        .toggleStyle(SwitchToggleStyle(tint: LucentUI.switchTint))
        .tint(.gray)
        .interactiveDismissDisabled(serverSaving)
        .alert("无法连接服务器", isPresented: Binding(
            get: { library.errorMessage != nil },
            set: { if !$0 { library.errorMessage = nil } }
        )) {
            Button("好") { library.errorMessage = nil }
        } message: {
            Text(LocalizedStringKey(library.errorMessage ?? "未知错误"))
        }
        .onDisappear {
            if kind == .plex {
                plexAuthTask?.cancel()
                plexAuthTask = nil
                plexPIN = nil
            }
        }
    }

    private func canSaveServer(_ kind: ServerKind, editing: Bool) -> Bool {
        guard serverDraft.address != nil else { return false }
        if editing { return true }
        switch kind {
        case .emby, .fnos, .zspace, .ugreen: return embyUsesToken ? (!embyToken.isEmpty && !embyUserID.isEmpty) : !embyUsername.isEmpty
        case .jellyfin: return jellyfinUsesToken ? !jellyfinToken.isEmpty : !jellyfinUsername.isEmpty
        case .plex: return !plexToken.isEmpty
        }
    }

    @MainActor private func saveServer(_ kind: ServerKind, existingID: UUID?,
                                       dismiss: @escaping () -> Void) async {
        guard let address = serverDraft.address else { return }
        serverSaving = true
        defer { serverSaving = false }
        let saved: Bool
        if let id = existingID {
            let token: String? = switch kind {
            case .emby, .fnos, .zspace, .ugreen: embyReplacementUsesToken ? replacementToken : nil
            case .jellyfin: jellyfinUsesToken ? replacementToken : nil
            case .plex: replacementToken
            }
            let username: String? = switch kind {
            case .emby, .fnos, .zspace, .ugreen: embyReplacementUsesToken ? nil : embyReplacementUsername
            case .jellyfin: jellyfinUsesToken ? nil : jellyfinUsername
            case .plex: nil
            }
            let password = kind.embyKind != nil ? embyReplacementPassword : jellyfinPassword
            let updatedID = await library.updateServerAddress(id: id, address: address,
                                                               replacementToken: token,
                                                               username: username, password: password)
            saved = updatedID != nil
            if let updatedID {
                if !serverDraft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    library.renameServer(id: updatedID, name: serverDraft.name)
                }
                if updatedID != id, selectedHomeCatalog.hasSuffix(id.uuidString) {
                    selectedHomeCatalog = "\(kind.embyKind != nil ? "emby" : kind.rawValue.lowercased()):\(updatedID.uuidString)"
                }
            }
        } else {
            switch kind {
            case .emby, .fnos, .zspace, .ugreen:
                if embyUsesToken {
                    saved = await library.addEmby(address: address, token: embyToken, userID: embyUserID, kind: kind.embyKind ?? .emby)
                } else {
                    saved = await library.addEmby(address: address, username: embyUsername,
                                                  password: embyPassword, kind: kind.embyKind ?? .emby)
                }
                if saved, let id = library.embySources.last?.id { library.renameServer(id: id, name: serverDraft.name) }
            case .jellyfin:
                if jellyfinUsesToken {
                    saved = await library.addJellyfin(address: address, token: jellyfinToken)
                } else {
                    saved = await library.addJellyfin(address: address, username: jellyfinUsername,
                                                      password: jellyfinPassword)
                }
                if saved, let id = library.jellyfinSources.last?.id { library.renameServer(id: id, name: serverDraft.name) }
            case .plex:
                saved = await library.addPlex(address: address, token: plexToken)
                if saved, let id = library.plexSources.last?.id { library.renameServer(id: id, name: serverDraft.name) }
            }
        }
        if saved {
            if let existingID {
                serverMediaCounts[existingID] = nil; serverChecks[existingID] = nil
                Task { await refreshServerCounts(existingID) }
            }
            dismiss()
        }
    }
    #endif

    private var serverNameSheet: some View {
        NavigationStack {
            Form {
                TextField("服务器名称", text: $serverNameDraft)
            }
            .navigationTitle("编辑服务器名称")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { renamingServerID = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if let id = renamingServerID {
                            library.renameServer(id: id, name: serverNameDraft)
                        }
                        renamingServerID = nil
                    }
                    .disabled(serverNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var sourcePageTitle: String {
        "片源"
    }

    private var navigationBody: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    #if os(iOS)
                    mobileSourcesContent
                    #else
                    NativeSourcesView(addCloud: { showCloud = true }, addDLNA: { showDLNA = true },
                        addFolder: { showFolderImporter = true },
                        editCloud: { id in editingCloud = library.cloudSources.first { $0.id == id } })
                        .environmentObject(library)
                    #endif
                }
                .frame(maxWidth: 1100, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(sourcePageTitle)
            #if os(iOS)
            .background(LucentUI.page)
            .refreshable {
                if mobileSourceKind == 0 {
                    for id in library.fileSourceIDs where library.isFileSourceIncluded(id) { library.refreshFileSource(id) }
                } else {
                    for source in library.embySources { await loadMediaCounts(source, force: true) }
                    for source in library.jellyfinSources { await loadMediaCounts(source, force: true) }
                    for source in library.plexSources { await loadMediaCounts(source, force: true) }
                }
            }
            #endif
            #if !os(tvOS)
            .toggleStyle(SwitchToggleStyle(tint: LucentUI.switchTint))
            #endif
            .tint(.gray)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                if library.activeProfile?.isChild != true {
                    if #available(iOS 26.0, *) {
                        ToolbarItem(placement: .topBarTrailing) { mobileAddSourceMenu }
                            .sharedBackgroundVisibility(.hidden)
                    } else {
                        ToolbarItem(placement: .topBarTrailing) { mobileAddSourceMenu }
                    }
                }
            }

            #endif
            #if !os(iOS)
            .sheet(isPresented: $showAddAddress) { addAddressSheet }
            .sheet(isPresented: $showSMB) { smbSheet }
            #if os(iOS)
            .sheet(isPresented: $showSourceChooser, onDismiss: performSourceAddition) { sourceChooser }
            .sheet(isPresented: $showStorageManager, onDismiss: finishStorageManagement) {
                NavigationStack {
                    StorageManagementView(add: { addStorageAfterDismiss = true; showStorageManager = false },
                        edit: { pendingStorageEdit = $0; showStorageManager = false })
                }.environmentObject(library).tint(.gray)
            }
            .confirmationDialog("移除 \(pendingSourceRemoval?.name ?? "片源")？",
                                isPresented: Binding(get: { pendingSourceRemoval != nil },
                                                     set: { if !$0 { pendingSourceRemoval = nil } }),
                                titleVisibility: .visible, presenting: pendingSourceRemoval) { source in
                Button("移除片源", role: .destructive) { removePendingSource(source) }
                Button("取消", role: .cancel) { pendingSourceRemoval = nil }
            } message: { _ in
                Text("会移除该片源的本机配置与关联媒体记录，存储中的原始文件不会删除。")
            }
            .sheet(item: $editingFolder) { source in folderEditSheet(source) }
            .sheet(isPresented: Binding(get: { browsingFolderID != nil }, set: { if !$0 { browsingFolderID = nil } })) {
                if let id = browsingFolderID {
                    NavigationStack { MobileFolderBrowserView(sourceID: id).environmentObject(library) }
                }
            }
            .sheet(item: $browsingFileSource) { source in
                NavigationStack {
                    MobileScannedSourceBrowserView(sourceID: source.id, sourceName: source.name)
                        .environmentObject(library)
                }
            }
            #endif
            .sheet(item: $editingSMB) { source in smbCredentialsSheet(source) }
            #if os(iOS)
            .sheet(item: $editingJellyfin) { source in
                mobileServerSheet(.jellyfin, existingID: source.id) { editingJellyfin = nil }
            }
            .sheet(item: $editingEmby) { source in
                mobileServerSheet(ServerKind(source.kind), existingID: source.id) { editingEmby = nil }
            }
            #else
            .sheet(item: $editingJellyfin) { source in jellyfinTokenSheet(source) }
            .sheet(item: $editingEmby) { source in embyTokenSheet(source) }
            #endif
            .sheet(isPresented: Binding(get: { renamingServerID != nil },
                                        set: { if !$0 { renamingServerID = nil } })) {
                serverNameSheet
            }
            .sheet(item: $browsingEmby) { source in
                EmbyBrowserView(source: source).environmentObject(library)
            }
            #if os(iOS)
            .sheet(item: $editingPlex) { source in
                mobileServerSheet(.plex, existingID: source.id) { editingPlex = nil }
            }
            #else
            .sheet(item: $editingPlex) { source in plexTokenSheet(source) }
            #endif
            .sheet(isPresented: $showWebDAV) { webDAVSheet }
            .sheet(item: $editingWebDAV) { source in webDAVCredentialsSheet(source) }
            #if os(iOS)
            .sheet(isPresented: $showJellyfin) { mobileServerSheet(.jellyfin) { showJellyfin = false } }
            .sheet(isPresented: $showEmby) { mobileServerSheet(embyServerKind) { showEmby = false } }
            .sheet(isPresented: $showPlex) { mobileServerSheet(.plex) { showPlex = false } }
            #else
            .sheet(isPresented: $showJellyfin) { jellyfinSheet }
            .sheet(isPresented: $showEmby) { embySheet }
            .sheet(isPresented: $showPlex) { plexSheet }
            #endif
            .sheet(isPresented: $showCloud) { cloudSheet }
            .sheet(isPresented: $showDLNA) { dlnaSheet }
            .sheet(item: $editingCloud) { source in cloudTokenSheet(source) }
            .sheet(isPresented: $showAddCollection) { collectionSheet }
            .sheet(isPresented: $showAddSmartPlaylist) { smartPlaylistSheet }
            #if !os(tvOS)
            .sheet(isPresented: $showBrowserUpload, onDismiss: stopBrowserUpload) {
                browserUploadSheet
            }
            #endif
            #endif
            .navigationDestination(item: $selectedItemID) { id in
                Group {
                    MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } })
                        .environmentObject(library)
                }.lucentSecondaryPage()
            }
            .onChange(of: selectedItemID) { _, newValue in
                mobileDetailPresented = newValue != nil
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
                Text(LocalizedStringKey(library.errorMessage ?? "未知错误"))
            }
            #if os(macOS)
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
    private var browserUploadSheet: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let browserUploadURL {
                    Text("用同一 Wi-Fi 下设备的相机扫描二维码")
                        .font(.headline)
                    LucentQRCode(content: browserUploadURL.absoluteString,
                                 accessibilityLabel: "浏览器上传网址二维码")
                        .frame(width: 220, height: 220)
                        .padding(16)
                        .background(.white, in: RoundedRectangle(cornerRadius: 18))
                    Text(browserUploadURL.absoluteString)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .multilineTextAlignment(.center)
                    Link("在本机打开上传页面", destination: browserUploadURL)
                } else {
                    ProgressView("正在启动上传服务…")
                }
                Text("此地址仅在本页面打开时有效，关闭页面后停止接收。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("浏览器上传")
            .toolbar { Button("完成") { showBrowserUpload = false } }
            .task { await startBrowserUpload() }
        }
    }

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
                    if let status = library.traktStatus { Text(LocalizedStringKey(status)).foregroundStyle(.secondary) }
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
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
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
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
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
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
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
                let sourceLabel = HStack(spacing: 12) {
                    Image(systemName: "cloud")
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(source.provider.title) · \(source.name)").font(.headline)
                        Text("\(library.fileSourceItemCount(source.id)) 部影片 · \(library.isFileSourceIncluded(source.id) ? "已加入媒体库" : "未加入媒体库")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(library.offlineCloudSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { String.lucentFormat("上次扫描：%@", $0.lucentFormatted()) } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    sourceLabel
                    Spacer(minLength: 8)
                    Toggle("加入媒体库", isOn: Binding(
                        get: { library.isFileSourceIncluded(source.id) },
                        set: { library.setFileSourceIncluded($0, id: source.id) }))
                        .labelsHidden()
                }
                .padding(14)
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                .contextMenu {
                    Button("编辑授权") { cloudToken = ""; cloudClientID = source.oauthClientID ?? ""; cloudRefreshToken = ""; editingCloud = source }
                    Button("刷新") { library.scanCloud(id: source.id) }
                    Button("移除片源及其影片", role: .destructive) { library.removeCloud(id: source.id) }
                }
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
            .navigationTitle("添加 DLNA 存储")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { showDLNA = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        guard let url = URL(string: dlnaAddress) else { return }
                        scanningDLNA = true
                        Task {
                            do {
                                let device = try await DLNAClient.connect(descriptionURL: url)
                                _ = library.addDLNA(device: device, videos: [])
                                dlnaMessage = "\(device.name)：已连接，请从存储选择目录导入。"
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
                             source.lastScannedAt.map { String.lucentFormat("上次扫描：%@", $0.lucentFormatted()) } ?? "尚未扫描")
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
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
            }
        }
    }

    private var cloudSheet: some View {
        NavigationStack {
            Form {
                Section("选择网盘") {
                Picker("服务", selection: $cloudProvider) {
                    ForEach(CloudProvider.allCases) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .disabled(addingCloud)
                TextField("名称（选填）", text: $cloudName)
                Text("连接网盘后，从存储中选择目录并导入文件源，再扫描加入聚合媒体库。")
                    .font(.caption).foregroundStyle(.secondary)
                }
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
                        LucentQRCode(content: authorization.qrCode,
                                     accessibilityLabel: "115 授权二维码")
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
                ToolbarItem(placement: .cancellationAction) { Button("取消") { showCloud = false }.disabled(addingCloud) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("连接") {
                        addingCloud = true
                        Task {
                            let added = await library.addCloud(provider: cloudProvider,
                                                               name: cloudName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? cloudProvider.title : cloudName,
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
                    .disabled(addingCloud ||
                              (cloudToken.isEmpty && (cloudRefreshToken.isEmpty ||
                                 (cloudProvider != .pan115 && cloudProvider != .guangyaPan && cloudClientID.isEmpty))))
                }
            }
        }
        #if os(iOS)
        .onChange(of: cloudProvider) { _, _ in clearCloudAuthorizationDraft() }
        .interactiveDismissDisabled(addingCloud)
        #endif
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
                let sourceLabel = HStack(spacing: 12) {
                    Image(systemName: "externaldrive")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text("\(library.fileSourceItemCount(source.id)) 部影片 · \(library.isFileSourceIncluded(source.id) ? "已加入媒体库" : "未加入媒体库")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(library.offlineSMBSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { String.lucentFormat("上次扫描：%@", $0.lucentFormatted()) } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    sourceLabel
                    Spacer(minLength: 8)
                    Toggle("加入媒体库", isOn: Binding(
                        get: { library.isFileSourceIncluded(source.id) },
                        set: { library.setFileSourceIncluded($0, id: source.id) }))
                        .labelsHidden()
                }
                .padding(14)
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                .contextMenu {
                    Button("编辑登录凭据") { editedSMBUsername = source.username; editedSMBPassword = ""; replaceSMBPassword = false; editingSMB = source }
                    Button("刷新") { library.scanSMB(id: source.id) }
                    Button("移除片源及其影片", role: .destructive) { library.removeSMB(id: source.id) }
                }
            }
        }
    }

    private var webDAVSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("WebDAV 片源").font(.title2.bold())
            ForEach(library.webDAVSources) { source in
                let sourceLabel = HStack(spacing: 12) {
                    Image(systemName: "network")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text("\(library.fileSourceItemCount(source.id)) 部影片 · \(library.isFileSourceIncluded(source.id) ? "已加入媒体库" : "未加入媒体库")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(library.offlineWebDAVSources.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { String.lucentFormat("上次扫描：%@", $0.lucentFormatted()) } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    sourceLabel
                    Spacer(minLength: 8)
                    Toggle("加入媒体库", isOn: Binding(
                        get: { library.isFileSourceIncluded(source.id) },
                        set: { library.setFileSourceIncluded($0, id: source.id) }))
                        .labelsHidden()
                }
                .padding(14)
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                .contextMenu {
                    Button("编辑登录凭据") { editedWebDAVUsername = source.username; editedWebDAVPassword = ""; replaceWebDAVPassword = false; editingWebDAV = source }
                    Button("刷新") { library.scanWebDAV(id: source.id) }
                    Button("移除片源及其影片", role: .destructive) { library.removeWebDAV(id: source.id) }
                }
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
                        Text(library.offlineJellyfinSources.contains(source.id) ? "当前不可访问" : "直连浏览服务器内容").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                #if os(iOS)
                .onTapGesture { selectedHomeCatalog = "jellyfin:\(source.id.uuidString)"; mobileTab = .home }
                #endif
                .contextMenu {
                    Button("编辑名称") { serverNameDraft = source.name; renamingServerID = source.id }
                    Button("编辑连接") { replacementToken = ""; editingJellyfin = source }
                    Button("移除服务器", role: .destructive) { library.removeJellyfin(id: source.id) }
                }
            }
        }
    }

    private var embySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Emby 服务器").font(.title2.bold())
            ForEach(library.embySources) { source in
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text("直连浏览服务器内容").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                .onTapGesture { browsingEmby = source }
                .contextMenu {
                    Button("编辑名称") { serverNameDraft = source.name; renamingServerID = source.id }
                    Button("编辑连接") { replacementToken = ""; embyReplacementUsername = ""; embyReplacementPassword = ""; embyReplacementUsesToken = false; editingEmby = source }
                    Button("移除服务器", role: .destructive) { library.removeEmby(id: source.id) }
                }
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
                        Text(library.offlinePlexSources.contains(source.id) ? "当前不可访问" : "直连浏览服务器内容").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .contentShape(RoundedRectangle(cornerRadius: 16))
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                #if os(iOS)
                .onTapGesture { selectedHomeCatalog = "plex:\(source.id.uuidString)"; mobileTab = .home }
                #endif
                .contextMenu {
                    Button("编辑名称") { serverNameDraft = source.name; renamingServerID = source.id }
                    Button("编辑连接") { replacementToken = ""; editingPlex = source }
                    Button("移除服务器", role: .destructive) { library.removePlex(id: source.id) }
                }
            }
        }
    }

    #if !os(tvOS)
    #if os(iOS)
    private func folderEditSheet(_ source: FolderSource) -> some View {
        NavigationStack {
            Form { TextField("名称", text: $editedFolderName) }
                .navigationTitle("编辑文件夹")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { editingFolder = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") {
                            library.renameFolder(id: source.id, name: editedFolderName)
                            editingFolder = nil
                        }.disabled(editedFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
    #endif

    private var foldersSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("文件夹片源").font(.title2.bold())
            ForEach(library.folders) { source in
                let sourceLabel = HStack(spacing: 12) {
                    Image(systemName: "folder")
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).font(.headline)
                        Text("\(library.fileSourceItemCount(source.id)) 部影片 · \(library.isFileSourceIncluded(source.id) ? "已加入媒体库" : "未加入媒体库")")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(library.offlineFolders.contains(source.id) ? "当前不可访问" :
                             source.lastScannedAt.map { String.lucentFormat("上次扫描：%@", $0.lucentFormatted()) } ?? "尚未扫描")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 12) {
                    Button { browsingFolderID = source.id } label: {
                        sourceLabel
                        Spacer(minLength: 8)
                    }
                    .buttonStyle(.plain)
                    .contentShape(Rectangle())
                    Toggle("加入媒体库", isOn: Binding(
                        get: { library.isFileSourceIncluded(source.id) },
                        set: { library.setFileSourceIncluded($0, id: source.id) }))
                        .labelsHidden()
                }
                .padding(14)
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
                .contextMenu {
                    Button("编辑名称") { editedFolderName = source.name; editingFolder = source }
                    Button("刷新") { library.scanFolder(id: source.id) }
                    Button("移除片源及其影片", role: .destructive) { library.removeFolder(id: source.id) }
                }
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
                    Button { selectedItemID = item.id } label: {
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
                                Text(LocalizedStringKey(item.watched ? "已看完" : item.isInProgress ? "继续播放" : "未观看"))
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
                .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 16)))
    }

    private var smbSheet: some View {
        #if os(iOS)
        StorageConnectionEditor(kind: .smb, close: { showSMB = false }).environmentObject(library)
        #else
        NavigationStack {
            Form {
                Section("连接地址") {
                    TextField("服务器地址或 IP", text: $smbHost)
                    TextField("共享名称", text: $smbShare)
                }
                if !smbDiscovery.hosts.isEmpty {
                    Section("发现的服务器") {
                        ForEach(smbDiscovery.hosts, id: \.self) { host in
                            Button(host) { smbHost = host }
                        }
                    }
                }
                Section("登录账户") {
                    TextField("用户名（访客可留空）", text: $smbUsername)
                    SecureField("密码（访客可留空）", text: $smbPassword)
                }
                Text("凭据保存在本机钥匙串。连接后可浏览目录，选择并导入文件源后才会扫描入库。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("添加 SMB 共享")
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
            #endif
    }

    private var webDAVSheet: some View {
        #if os(iOS)
        StorageConnectionEditor(kind: .webDAV, close: { showWebDAV = false }).environmentObject(library)
        #else
        NavigationStack {
            Form {
                Section("连接地址") { TextField("https://server.example/videos/", text: $webDAVAddress) }
                Section("登录账户") {
                    TextField("用户名（访客可留空）", text: $webDAVUsername)
                    SecureField("密码（访客可留空）", text: $webDAVPassword)
                }
                Text("公网地址需要 HTTPS。凭据保存在本机钥匙串。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            #if os(iOS)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .navigationTitle("添加 WebDAV")
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
            #endif
    }

    private func webDAVCredentialsSheet(_ source: WebDAVSource) -> some View {
        #if os(iOS)
        StorageConnectionEditor(kind: .webDAV, existingID: source.id, close: { editingWebDAV = nil }).environmentObject(library)
        #else
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
                    Button("保存") {
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
            #endif
    }

    private func smbCredentialsSheet(_ source: SMBSource) -> some View {
        #if os(iOS)
        StorageConnectionEditor(kind: .smb, existingID: source.id, close: { editingSMB = nil }).environmentObject(library)
        #else
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
                    Button("保存") {
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
            #endif
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
                    Button("保存") {
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
                Toggle("使用访问令牌", isOn: $embyReplacementUsesToken)
                if embyReplacementUsesToken {
                    SecureField("新访问令牌", text: $replacementToken)
                } else {
                    TextField("用户名", text: $embyReplacementUsername)
                    SecureField("密码", text: $embyReplacementPassword)
                }
                Text("重新登录后保留此服务器的媒体与播放记录。")
                    .font(.footnote).foregroundStyle(.secondary)
                if replacingToken { ProgressView() }
            }
            .navigationTitle("更新 Emby 登录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { editingEmby = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        replacingToken = true
                        Task {
                            let updated: Bool
                            if embyReplacementUsesToken {
                                updated = await library.updateEmbyToken(id: source.id, token: replacementToken)
                            } else {
                                updated = await library.updateEmbyLogin(id: source.id,
                                    username: embyReplacementUsername, password: embyReplacementPassword)
                            }
                            replacingToken = false
                            if updated {
                                replacementToken = ""
                                embyReplacementPassword = ""
                                editingEmby = nil
                            }
                        }
                    }
                    .disabled(replacingToken || (embyReplacementUsesToken ?
                        replacementToken.isEmpty : embyReplacementUsername.isEmpty))
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
                    Button("保存") {
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
                Text("支持 HTTPS、局域网 HTTP/FTP/NFS 及 SFTP/FTPS 直链；FTP/FTPS/SFTP/NFS 由 MPV 播放，需填写已知文件地址且不在 URL 中包含密码。")
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

private struct LucentQRCode: View {
    let content: String
    let accessibilityLabel: String

    var body: some View {
        if let image = makeImage() {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .accessibilityLabel(accessibilityLabel)
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

#if os(iOS)
private struct MobileScannedSourceBrowserView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let sourceID: UUID
    let sourceName: String
    var directory = ""
    @State private var playingItem: MediaItem?
    @State private var entries: [SourceDirectoryEntry] = []
    @State private var loading = false
    @State private var failure: String?
    @State private var search = ""
    @State private var ascending = true

    private var liveDirectory: Bool {
        library.smbSources.contains { $0.id == sourceID } || library.webDAVSources.contains { $0.id == sourceID }
    }
    private var indexedFiles: [(path: String, item: MediaItem)] {
        library.items.compactMap { item in
            switch item.location {
            case .smbFile(let id, let path) where id == sourceID:
                return (path, item)
            case .webDAVFile(let id, let path) where id == sourceID:
                return (path, item)
            case .cloudFile(let id, _, let name) where id == sourceID:
                return (name, item)
            default: return nil
            }
        }
    }
    private var visibleEntries: [SourceDirectoryEntry] {
        let values: [SourceDirectoryEntry]
        if liveDirectory { values = entries }
        else {
            let prefix = directory.isEmpty ? "" : directory + "/"
            var paths = Set<String>()
            values = indexedFiles.compactMap { entry in
                guard entry.path.hasPrefix(prefix) else { return nil }
                let suffix = String(entry.path.dropFirst(prefix.count))
                let name = String(suffix.split(separator: "/").first ?? "")
                let path = prefix + name
                guard !name.isEmpty, paths.insert(path).inserted else { return nil }
                return .init(name: name, path: path, isDirectory: suffix.contains("/"))
            }
        }
        return values.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            let comparison = $0.name.localizedStandardCompare($1.name)
            return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    var body: some View {
        List {
            Section {
                if loading || library.isScanningFileSource(sourceID) {
                    ProgressView(liveDirectory ? "正在读取目录" : "正在更新文件索引")
                }
                if let failure {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("无法读取目录", systemImage: "wifi.exclamationmark").font(.headline)
                        Text(LocalizedStringKey(failure)).font(.caption).foregroundStyle(.secondary)
                        Button("重新连接") { Task { await loadDirectory() } }
                    }.padding(.vertical, 8)
                }
                if !liveDirectory {
                    Text("显示已扫描的视频；更新文件索引不会改变加入媒体库的开关。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !loading && visibleEntries.isEmpty && failure == nil {
                    ContentUnavailableView(search.isEmpty ? "没有可播放的视频" : "没有匹配的文件",
                                           systemImage: search.isEmpty ? "folder" : "magnifyingglass",
                                           description: Text(LocalizedStringKey(search.isEmpty ? "可刷新目录或检查访问权限" : "试试其他文件名")))
                    if !liveDirectory && search.isEmpty {
                        Button("更新文件索引", systemImage: "arrow.clockwise") { library.refreshFileSource(sourceID) }
                            .disabled(library.isScanningFileSource(sourceID))
                    }
                }
            }
            Section {
                ForEach(visibleEntries) { entry in
                    if entry.isDirectory {
                        NavigationLink {
                            Group {
                                MobileScannedSourceBrowserView(sourceID: sourceID, sourceName: sourceName, directory: entry.path)
                                    .environmentObject(library)
                            }.lucentSecondaryPage()
                        } label: {
                            Label(entry.name, systemImage: "folder.fill").foregroundStyle(.primary)
                        }
                    } else {
                        Button { play(entry) } label: { fileLabel(entry) }
                            .foregroundStyle(.primary)
                            .contextMenu {
                                Button("收藏 / 取消收藏", systemImage: "heart") {
                                    if let item = resolvedItem(entry) { library.toggleFavorite(id: item.id) }
                                }
                                Button("标记为已观看", systemImage: "checkmark.circle") {
                                    if let item = resolvedItem(entry) { library.markWatched(id: item.id) }
                                }
                                Button("标记为未观看", systemImage: "circle") {
                                    if let item = resolvedItem(entry) { library.markUnwatched(id: item.id) }
                                }
                                Button("下载到本机", systemImage: "arrow.down.circle") {
                                    if let item = resolvedItem(entry) { Task { await library.download(id: item.id) } }
                                }
                            }
                    }
                }
            } header: {
                if !visibleEntries.isEmpty { Text("\(visibleEntries.filter(\.isDirectory).count) 个文件夹 · \(visibleEntries.filter { !$0.isDirectory }.count) 个视频") }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $search, prompt: "搜索当前目录")
        .navigationTitle(directory.isEmpty ? sourceName : (directory as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Menu {
                    Button("刷新目录", systemImage: "arrow.clockwise") { Task { await loadDirectory(refreshIndex: true) } }
                        .disabled(loading || library.isScanningFileSource(sourceID))
                    Toggle("名称升序", isOn: $ascending)
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("目录选项")
            }
            if directory.isEmpty {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .tint(.gray)
        .task(id: directory) { await loadDirectory() }
        .refreshable { await loadDirectory(refreshIndex: true) }
        .discPlaybackCover(item: $playingItem) { item in
            PlaybackView(item: item).environmentObject(library)
        }
    }

    private func fileLabel(_ entry: SourceDirectoryEntry) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle").font(.title3).frame(width: 32)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.name).font(.subheadline).lineLimit(2)
                if let item = indexedFiles.first(where: { $0.path == entry.path })?.item {
                    HStack(spacing: 8) {
                        if item.position > 0 { Text("已播放 \(Int(item.position / 60)) 分钟") }
                        if library.downloadedURL(for: item) != nil { Label("已下载", systemImage: "arrow.down.circle.fill") }
                        if library.downloading.contains(item.id) { Text("正在下载") }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }

    private func resolvedItem(_ entry: SourceDirectoryEntry) -> MediaItem? {
        indexedFiles.first { $0.path == entry.path }?.item ?? library.browsedFileItem(sourceID: sourceID, path: entry.path)
    }

    private func play(_ entry: SourceDirectoryEntry) {
        guard let item = resolvedItem(entry) else { return }
        playingItem = item
    }

    @MainActor private func loadDirectory(refreshIndex: Bool = false) async {
        guard !loading else { return }
        loading = true; failure = nil
        defer { loading = false }
        do {
            if let source = library.smbSources.first(where: { $0.id == sourceID }) {
                let password = try KeychainPasswordStore.get(for: sourceID)
                let path = directory
                let result = try await Task.detached(priority: .userInitiated) {
                    try SMBScanner.contents(source: source, password: password, path: path)
                }.value
                try Task.checkCancellation()
                entries = result
            } else if let source = library.webDAVSources.first(where: { $0.id == sourceID }) {
                let password = try KeychainPasswordStore.webDAVPassword(for: sourceID)
                let result = try await WebDAVClient.contents(source: source, password: password, path: directory)
                try Task.checkCancellation()
                entries = result
            } else if library.cloudSources.contains(where: { $0.id == sourceID }) {
                if refreshIndex { library.refreshFileSource(sourceID) }
            } else { failure = "文件源已被移除，请返回片源页面。" }
        } catch {
            if !Task.isCancelled { failure = "请检查片源地址、网络连接和账户权限后重试。" }
        }
    }
}
#endif
