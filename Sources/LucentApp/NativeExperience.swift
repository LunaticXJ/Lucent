#if !os(iOS)
import SwiftUI
import Combine

enum NativeLayout {
    #if os(tvOS)
    static let pageInset: CGFloat = 60
    static let posterWidth: CGFloat = 230
    static let landscapeWidth: CGFloat = 370
    static let gridMinimum: CGFloat = 220
    static let gridMaximum: CGFloat = 300
    static let gridSpacing: CGFloat = 32
    #else
    static let pageInset: CGFloat = 32
    static let posterWidth: CGFloat = 190
    static let landscapeWidth: CGFloat = 280
    static let gridMinimum: CGFloat = 180
    static let gridMaximum: CGFloat = 280
    static let gridSpacing: CGFloat = 24
    #endif
}

// The page graph is shared; only the navigation chrome differs by input device.
enum NativeAppPage: String, CaseIterable, Identifiable {
    case home, sources, search, settings
    var id: String { rawValue }
    var title: String { switch self { case .home: "首页"; case .sources: "片源"; case .search: "搜索"; case .settings: "设置" } }
    var symbol: String { switch self { case .home: "house"; case .sources: "externaldrive"; case .search: "magnifyingglass"; case .settings: "gearshape" } }
}

struct NativeAppShell<Home: View, Sources: View, Search: View, Settings: View>: View {
    @Binding var page: NativeAppPage
    @ViewBuilder let home: () -> Home
    @ViewBuilder let sources: () -> Sources
    @ViewBuilder let search: () -> Search
    @ViewBuilder let settings: () -> Settings
    var body: some View {
        #if os(macOS)
        NavigationSplitView {
            List(NativeAppPage.allCases, selection: $page) { value in
                Label(LocalizedStringKey(value.title), systemImage: value.symbol).tag(value)
            }.lucentPageTitle("Lucent").navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            switch page {
            case .home: NavigationStack { home() }
            case .sources: sources()
            case .search: NavigationStack { search() }
            case .settings: NavigationStack { settings() }
            }
        }.frame(minWidth: 900, minHeight: 640)
        #else
        TabView(selection: $page) {
            NavigationStack { home() }.tabItem { Label("首页", systemImage: "house") }.tag(NativeAppPage.home)
            sources().tabItem { Label("片源", systemImage: "externaldrive") }.tag(NativeAppPage.sources)
            NavigationStack { search() }.tabItem { Label("搜索", systemImage: "magnifyingglass") }.tag(NativeAppPage.search)
            NavigationStack { settings() }.tabItem { Label("设置", systemImage: "gearshape") }.tag(NativeAppPage.settings)
        }
        #endif
    }
}

struct NativeCatalog: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let asset: String?
    var sourceID: UUID? { id.split(separator: ":").last.flatMap { UUID(uuidString: String($0)) } }
    @MainActor static func all(in library: LibraryStore) -> [Self] {
        [.init(id: "library", name: "聚合媒体库", asset: nil)] +
        library.embySources.map { .init(id: "emby:\($0.id)", name: $0.name, asset: $0.kind.assetName) } +
        library.jellyfinSources.map { .init(id: "jellyfin:\($0.id)", name: $0.name, asset: "JellyfinBrand") } +
        library.plexSources.map { .init(id: "plex:\($0.id)", name: $0.name, asset: "PlexBrand") }
    }
}

struct NativeMediaEntry: Identifiable, Sendable {
    let catalog: NativeCatalog
    let remote: JellyfinItem?
    let plex: PlexItem?
    let local: MediaItem?
    var id: String { catalog.id + ":" + (remote?.id ?? plex?.ratingKey ?? local?.id.uuidString ?? "") }
    var title: String { remote?.name ?? plex?.title ?? local?.catalogDisplayTitle ?? "" }
    var overview: String { remote?.overview ?? local?.metadata?.summary ?? "" }
    var rating: Double? { remote?.communityRating ?? local?.metadata?.rating }
    var year: Int? { remote?.displayYear ?? plex?.year ?? local?.catalogDisplayYear }
    var yearText: String? { remote?.displayYearText ?? local?.catalogDisplayYearText ?? plex?.year.map(String.init) }
    var position: Double {
        if let local { return local.position }
        if let plex { return (plex.viewOffset ?? 0) / 1000 }
        return Double(remote?.userData?.playbackPositionTicks ?? 0) / 10_000_000
    }
    var duration: Double? {
        if let local { return local.duration ?? local.technicalInfo?.duration }
        if let plex { return plex.duration.map { $0 / 1000 } }
        return remote?.runTimeTicks.map { Double($0) / 10_000_000 }
    }
    var progress: Double {
        guard let duration, duration > 0 else { return 0 }
        return min(1, max(0, position / duration))
    }
    @MainActor func open(in library: LibraryStore) -> MediaItem? {
        if let local { return local }
        guard let id = catalog.sourceID else { return nil }
        if let remote {
            return catalog.id.hasPrefix("emby:") ? library.openEmbyItem(sourceID: id, remote: remote) : library.openJellyfinItem(sourceID: id, remote: remote)
        }
        if let plex { return library.openPlexItem(sourceID: id, remote: plex) }
        return nil
    }
    @MainActor func artwork(in library: LibraryStore, landscape: Bool = false) -> URLRequest? {
        if let local {
            let url = library.posterURL(for: local) ?? (landscape ? local.metadata?.backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w1280\($0)") } : nil) ?? local.metadata?.posterURL
            return url.map { URLRequest(url: $0) }
        }
        guard let id = catalog.sourceID else { return nil }
        if let source = library.embySources.first(where: { $0.id == id }), let remote,
           let token = try? KeychainPasswordStore.embyToken(for: id) {
            return EmbyClient.posterRequest(source: source, token: token, itemID: remote.id)
        }
        if let source = library.jellyfinSources.first(where: { $0.id == id }), let remote,
           let token = try? KeychainPasswordStore.jellyfinToken(for: id) {
            return JellyfinClient.posterRequest(source: source, token: token, itemID: remote.id)
        }
        if let source = library.plexSources.first(where: { $0.id == id }), let thumb = plex?.thumb,
           let token = try? KeychainPasswordStore.plexToken(for: id) {
            return PlexClient.posterRequest(source: source, token: token, thumb: thumb)
        }
        return nil
    }
}

struct NativeMediaCard: View {
    @EnvironmentObject private var library: LibraryStore
    let entry: NativeMediaEntry
    var landscape = false
    var showsProgress = true
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LucentRemoteArtwork(request: entry.artwork(in: library, landscape: landscape), cacheKey: "native|\(entry.id)|\(landscape)", maximumPixels: landscape ? 1280 : 750)
                .aspectRatio(landscape ? 16.0 / 9 : 2.0 / 3, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { if let rating = entry.rating { LucentRatingBadge(rating: rating).padding(.trailing, 4).padding(.bottom, landscape ? 44 : 4) } }
                .overlay(alignment: .bottom) {
                    if landscape && showsProgress { LucentPlaybackProgressOverlay(position: entry.position, duration: entry.duration, progress: entry.progress) }
                }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
            LucentPosterCaption(title: entry.title, subtitle: showsProgress && landscape ? nil : entry.yearText, lines: 1)
        }.contentShape(Rectangle())
    }
}

struct NativeShelf: Identifiable, Hashable, Sendable {
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    let id: String
    let title: String
    let entries: [NativeMediaEntry]
    var landscape = false
    var parentID: String? = nil
}

/// One loader for macOS/tvOS, with cancellation and an account-specific, one-day snapshot.
@MainActor final class NativeHomeModel: ObservableObject {
    @Published var shelves: [NativeShelf] = []
    @Published var localShelves: [NativeShelf] = []
    @Published var localProfileID: UUID?
    @Published var loading = false
    @Published var error: String?
    @Published var shelfErrors: [String: String] = [:]
    private struct Snapshot { let date: Date; let shelves: [NativeShelf]; let errors: [String: String]; let rootError: String? }
    private var snapshots: [String: Snapshot] = [:]
    private enum RootResult: Sendable {
        case latest([JellyfinItem]), resume([JellyfinItem]), libraries([JellyfinItem]), failure(String?)
    }
    private var generation = UUID()
    private func contextKey(_ catalog: NativeCatalog, _ library: LibraryStore) -> String {
        let id = catalog.sourceID
        let connection: String
        if let source = library.embySources.first(where: { $0.id == id }) { connection = source.baseAddress + "|" + source.userID }
        else if let source = library.jellyfinSources.first(where: { $0.id == id }) { connection = source.baseAddress + "|" + source.userID }
        else if let source = library.plexSources.first(where: { $0.id == id }) { connection = source.baseAddress }
        else { connection = "" }
        return catalog.id + "|" + connection + "|" + (library.activeProfile?.id.uuidString ?? "default") + "|" + LocalizationPreferences.current.contentLanguage
    }
    func load(catalog: NativeCatalog, library: LibraryStore, force: Bool = false, rootOnly: Bool = false) async {
        let request = UUID(); generation = request
        error = nil; shelfErrors = [:]
        guard catalog.id != "library" else { shelves = []; loading = false; return }
        let cacheKey = contextKey(catalog, library)
        if !force, let saved = snapshots[cacheKey], Date().timeIntervalSince(saved.date) < 86_400 {
            shelves = saved.shelves; shelfErrors = saved.errors; error = saved.rootError
            if saved.rootError == nil && saved.errors.isEmpty && Date().timeIntervalSince(saved.date) < 60 { loading = false; return }
        } else { shelves = [] }
        loading = true
        defer { if generation == request { loading = false } }
        do {
            var result: [NativeShelf] = []
            if let id = catalog.sourceID, let source = library.embySources.first(where: { $0.id == id }) {
                guard let token = try KeychainPasswordStore.embyToken(for: id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                var new: [JellyfinItem] = []
                var continuing: [JellyfinItem] = []
                var libraries: [JellyfinItem] = []
                await withTaskGroup(of: RootResult.self) { group in
                    group.addTask {
                        do { return .latest(try await EmbyClient.latest(source: source, token: token)) }
                        catch { return .failure(Task.isCancelled ? nil : error.localizedDescription) }
                    }
                    group.addTask {
                        do { return .resume(try await EmbyClient.resume(source: source, token: token).items) }
                        catch { return .failure(Task.isCancelled ? nil : error.localizedDescription) }
                    }
                    group.addTask {
                        do { return .libraries(try await EmbyClient.browse(source: source, token: token, parentID: nil).items) }
                        catch { return .failure(Task.isCancelled ? nil : error.localizedDescription) }
                    }
                    for await value in group {
                        guard generation == request, !Task.isCancelled else { group.cancelAll(); return }
                        switch value {
                        case .latest(let values): new = values
                        case .resume(let values): continuing = values
                        case .libraries(let values): libraries = values
                        case .failure(let message): if let message { error = message }
                        }
                        result = [
                            .init(id: "continue", title: "继续观看", entries: continuing.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }, landscape: true),
                            .init(id: "latest", title: "最近入库", entries: new.filter { $0.type != "Episode" }.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }),
                            .init(id: "libraries", title: "我的媒体", entries: libraries.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }, landscape: true)
                        ]
                        shelves = result.filter { !$0.entries.isEmpty }
                    }
                }
                try Task.checkCancellation()
                guard generation == request else { return }
                if rootOnly { return }
                // Bound server concurrency and keep the server's library order.
                var pages: [String: [JellyfinItem]] = [:]
                let roots = result
                shelves = roots + libraries.map { .init(id: $0.id, title: $0.name, entries: [], parentID: $0.id) }
                for start in stride(from: 0, to: libraries.count, by: 4) {
                    let batch = Array(libraries[start..<min(start + 4, libraries.count)])
                    let values = await withTaskGroup(of: (String, [JellyfinItem], String?).self) { group in
                        for view in batch {
                            group.addTask {
                                do {
                                    let page = try await EmbyClient.featured(source: source, token: token, parentID: view.id, itemTypes: EmbyClient.featuredItemTypes(for: view))
                                    return (view.id, page.items, nil)
                                } catch { return (view.id, [], Task.isCancelled ? nil : error.localizedDescription) }
                            }
                        }
                        var values: [String: [JellyfinItem]] = [:]
                        for await (key, entries, message) in group {
                            values[key] = entries
                            if generation == request, let message { shelfErrors[key] = message }
                        }
                        return values
                    }
                    pages.merge(values) { _, new in new }
                    try Task.checkCancellation()
                    guard generation == request else { return }
                    shelves = roots + libraries.map { view in
                        .init(id: view.id, title: view.name,
                            entries: (pages[view.id] ?? []).map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }, parentID: view.id)
                    }
                }
                result += libraries.map { view in .init(id: view.id, title: view.name, entries: (pages[view.id] ?? []).map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }, parentID: view.id) }
                if force {
                    do { try await library.synchronizeServerHome(sourceID: id, emby: true, displayedItems: result.flatMap { $0.entries.compactMap(\.remote) }) }
                    catch { if !Task.isCancelled { self.error = error.localizedDescription } }
                }
            } else if let id = catalog.sourceID, let source = library.jellyfinSources.first(where: { $0.id == id }) {
                guard let token = try KeychainPasswordStore.jellyfinToken(for: id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                let items = try await JellyfinClient.browsePage(source: source, token: token, start: 0)
                if force { try await library.synchronizeServerHome(sourceID: id, emby: false, displayedItems: items) }
                result = [.init(id: "latest", title: "最近入库", entries: items.filter { $0.type != "Episode" }.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) })]
            } else if let id = catalog.sourceID, let source = library.plexSources.first(where: { $0.id == id }) {
                guard let token = try KeychainPasswordStore.plexToken(for: id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                let requestedAt = Date()
                let items = try await PlexClient.catalogPage(source: source, token: token, start: 0)
                library.synchronizePlexHome(sourceID: id, displayedItems: items, requestedAt: requestedAt)
                result = [.init(id: "latest", title: "最近入库", entries: items.filter { $0.type != "episode" }.map { .init(catalog: catalog, remote: nil, plex: $0, local: nil) })]
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            shelves = result.filter { !$0.entries.isEmpty || shelfErrors[$0.id] != nil }
            let active = Set(NativeCatalog.all(in: library).map(\.id))
            snapshots = snapshots.filter { key, value in Date().timeIntervalSince(value.date) < 86_400 && active.contains(String(key.split(separator: "|").first ?? "")) }
            if snapshots.count >= 8, let oldest = snapshots.min(by: { $0.value.date < $1.value.date })?.key { snapshots[oldest] = nil }
            snapshots[cacheKey] = .init(date: Date(), shelves: shelves, errors: shelfErrors, rootError: error)
        } catch is CancellationError { return }
        catch { if generation == request && !Task.isCancelled { self.error = error.localizedDescription } }
        if generation == request { loading = false }
    }
}

struct NativeHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("lucent.home.selectedCatalog") private var selection = "auto"
    @ObservedObject var model: NativeHomeModel
    @State private var selected: NativeEntryRoute?
    @SceneStorage("lucent.home.nativeHeroIndex") private var heroIndex = 0
    @State private var allShelf: NativeShelf?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.contentLocalizationID) private var contentLocalizationID
    @State private var heroArtwork: TMDBService.DetailArtwork?
    let showSources: () -> Void
    private var catalogs: [NativeCatalog] { NativeCatalog.all(in: library) }
    private var catalog: NativeCatalog {
        if selection == "auto", library.localLibraryItems.isEmpty,
           let server = catalogs.first(where: { $0.id != "library" }) { return server }
        return catalogs.first { $0.id == selection } ?? catalogs[0]
    }
    private var localShelves: [NativeShelf] {
        model.localProfileID == library.activeProfile?.id ? model.localShelves : []
    }
    @State private var localRebuild = UUID()
    private func rebuildLocalShelves() async {
        guard catalog.id == "library" else { return }
        let visible = Set(library.visibleItems.map(\.id))
        let files = library.localLibraryItems.filter { $0.missingSince == nil && visible.contains($0.id) }
        let context = catalog
        let profileID = library.activeProfile?.id
        let values = await Task.detached(priority: .utility) {
            let cards = LocalCatalogIndex(files: files).cards
            let categories = [LocalCatalogCollection.continueWatching, .favorites, .unwatched] + LocalCatalogCollection.homeCategories + [.other]
            return categories.compactMap { category -> NativeShelf? in
                let values = category.items(cards: cards, files: files)
                return values.isEmpty ? nil : .init(id: category.rawValue, title: category.title,
                    entries: values.map { .init(catalog: context, remote: nil, plex: nil, local: $0) }, landscape: category == .continueWatching)
            }
        }.value
        guard !Task.isCancelled, catalog.id == context.id, library.activeProfile?.id == profileID else { return }
        model.localShelves = values; model.localProfileID = profileID
    }
    private var shelves: [NativeShelf] { catalog.id == "library" ? localShelves : model.shelves }
    private var heroes: [NativeMediaEntry] { Array((shelves.first(where: { !$0.landscape })?.entries ?? []).prefix(8)) }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if !heroes.isEmpty { hero }
                if catalog.id == "library", !library.localLibraryItems.isEmpty {
                    NavigationLink { LocalCatalogCollectionView(collection: .mediaLibraries, detailPresented: .constant(false)) } label: {
                        Label("我的媒体", systemImage: "square.grid.2x2").font(.title2.bold())
                    }
                }
                if model.loading { LucentLoadingView(title: "正在读取内容").frame(maxWidth: .infinity).padding(50) }
                if let error = model.error { LucentStateView(title: "读取失败", symbol: "wifi.exclamationmark", message: error, actionTitle: "重试") { refresh() } }
                if !model.loading && model.error == nil && shelves.isEmpty {
                    LucentStateView(title: catalog.id == "library" ? "空空如也" : "暂无影片", symbol: "film",
                        actionTitle: catalog.id == "library" ? "配置聚合媒体库" : "添加片源") {
                        if catalog.id == "library" { UserDefaults.standard.set(0, forKey: "lucent.sources.selectedKind") }
                        showSources()
                    }.frame(maxWidth: .infinity, minHeight: 400)
                }
                ForEach(shelves) { shelf in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(LocalizedStringKey(shelf.title)).font(.title2.bold())
                            Spacer()
                            Button("查看全部") { allShelf = shelf }
                        }
                        if let message = model.shelfErrors[shelf.id] {
                            LucentStateView(title: "读取失败", message: message, actionTitle: "重试") { refresh() }
                        } else if shelf.entries.isEmpty && model.loading {
                            ProgressView().frame(maxWidth: .infinity).padding(30)
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 22) {
                                ForEach(shelf.entries.prefix(24)) { entry in
                                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry, landscape: shelf.landscape, showsProgress: shelf.id == "continue").frame(width: cardWidth(shelf.landscape)) }
                                        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle)
                                }
                            }.padding(20)
                        }.focusSection()
                    }
                }
            }.padding(contentInset)
        }.background(LucentUI.page).lucentPageTitle(catalog.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink { LucentFavoritesView().environmentObject(library) } label: {
                    Image(systemName: "heart").accessibilityLabel("收藏")
                }.labelStyle(.iconOnly)
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("首页内容", selection: Binding(get: { catalog.id }, set: { selection = $0 })) {
                        ForEach(catalogs) { value in
                            if let asset = value.asset { Label(value.name, image: asset).tag(value.id) }
                            else { Label(value.name, systemImage: "rectangle.stack").tag(value.id) }
                        }
                    }
                    Button("刷新首页", systemImage: "arrow.clockwise") { refresh() }
                } label: { Image(systemName: "rectangle.stack").accessibilityLabel("首页内容") }
                .labelStyle(.iconOnly)
            }
        }
        .task(id: "\(catalog.id)|\(localRebuild)") { await rebuildLocalShelves() }
        .onReceive(library.$catalogStructureRevision.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in localRebuild = UUID() }
        .onReceive(library.$items.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in localRebuild = UUID() }
        .task(id: catalog.id + "|" + (library.activeProfile?.id.uuidString ?? "default") + "|" + contentLocalizationID) { await model.load(catalog: catalog, library: library) }
        .navigationDestination(item: $selected) { NativeEntryPage(route: $0).environmentObject(library) }
        .navigationDestination(item: $allShelf) { shelf in
            if let context = shelf.entries.first?.catalog,
               let id = context.sourceID, let source = library.embySources.first(where: { $0.id == id }),
               shelf.parentID != nil || shelf.id == "libraries" {
                EmbyBrowserView(source: source, parentID: shelf.parentID, title: shelf.title, embedded: true)
                    .environmentObject(library)
            } else if let context = shelf.entries.first?.catalog, context.id != "library", !["continue", "favorites"].contains(shelf.id) {
                NativeServerBrowser(catalog: context, parentID: shelf.parentID, title: shelf.title).environmentObject(library)
            } else if let collection = LocalCatalogCollection(rawValue: shelf.id) {
                LocalCatalogCollectionView(collection: collection, detailPresented: .constant(false)).environmentObject(library)
            } else { NativeShelfGrid(shelf: shelf).environmentObject(library) }
        }
    }
    private var contentInset: CGFloat {
        #if os(tvOS)
        60
        #else
        28
        #endif
    }
    private func cardWidth(_ landscape: Bool) -> CGFloat {
        #if os(tvOS)
        landscape ? 370 : 230
        #else
        landscape ? 280 : 160
        #endif
    }
    private var hero: some View {
        let entry = heroes[min(heroIndex, heroes.count - 1)]
        return VStack(alignment: .leading, spacing: 16) {
                DetailTitleArtwork(url: heroArtwork?.logoURL, title: heroArtwork?.localizedTitle ?? entry.title).frame(maxWidth: 420, alignment: .leading)
                if let rating = entry.rating { Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill").font(.caption).foregroundStyle(.yellow) }
                Text(entry.overview).font(.footnote).foregroundStyle(.white).lineLimit(3).frame(maxWidth: 720, alignment: .leading)
                HStack {
                    Button("查看详情", systemImage: "play.fill") { selected = entry.destination(in: library) }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("上一部", systemImage: "chevron.left") { heroIndex = (heroIndex + heroes.count - 1) % heroes.count }
                    Text("\(min(heroIndex, heroes.count - 1) + 1) / \(heroes.count)").foregroundStyle(.white).monospacedDigit()
                    Button("下一部", systemImage: "chevron.right") { heroIndex = (heroIndex + 1) % heroes.count }
                }
        }
        .padding(32)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 440, alignment: .bottomLeading)
        .background {
            GeometryReader { geometry in
                NativeHeroBackground(entry: entry)
                    .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                    .overlay { LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom) }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24)).focusSection()
            .transition(.opacity).animation(reduceMotion ? nil : .easeInOut(duration: 0.45), value: heroIndex)
            .task(id: "\(entry.id)|\(contentLocalizationID)") {
                heroArtwork = nil
                guard let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else { return }
                let artwork = try? await TMDBService.detailArtwork(remote: entry.remote, metadata: entry.local?.metadata,
                    title: entry.title, television: entry.remote?.type == "Series" || entry.local?.identity?.seriesName != nil,
                    language: TMDBService.deviceLanguage, token: token, displayWidthPixels: LucentDisplay.maximumArtworkPixels)
                guard !Task.isCancelled else { return }; heroArtwork = artwork
            }
    }
    private func refresh() { Task { await model.load(catalog: catalog, library: library, force: true) }; if catalog.id == "library" { library.refreshFolders() } }
}

struct NativeShelfGrid: View {
    @EnvironmentObject private var library: LibraryStore
    let shelf: NativeShelf
    @State private var selected: NativeEntryRoute?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: shelf.landscape ? NativeLayout.landscapeWidth : NativeLayout.gridMinimum,
                                            maximum: shelf.landscape ? NativeLayout.landscapeWidth + 60 : NativeLayout.gridMaximum), spacing: NativeLayout.gridSpacing)], spacing: 28) {
                ForEach(shelf.entries) { entry in
                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry, landscape: shelf.landscape) }.lucentContentButtonStyle()
                }
            }.padding(NativeLayout.pageInset)
        }.lucentPageTitle(shelf.title).background(LucentUI.page)
            .navigationDestination(item: $selected) { NativeEntryPage(route: $0).environmentObject(library) }
    }
}
#endif

#if !os(iOS)
private struct NativeHeroBackground: View {
    @EnvironmentObject private var library: LibraryStore
    let entry: NativeMediaEntry
    var body: some View {
        if let id = entry.catalog.sourceID,
           let source = library.embySources.first(where: { $0.id == id }), let remote = entry.remote {
            SeriesArtwork(baseAddress: source.baseAddress, token: try? KeychainPasswordStore.embyToken(for: id), itemID: remote.id, backdrop: true, fallback: nil, maximumWidth: 1800)
        } else if let id = entry.catalog.sourceID,
                  let source = library.jellyfinSources.first(where: { $0.id == id }), let remote = entry.remote {
            SeriesArtwork(baseAddress: source.baseAddress, token: try? KeychainPasswordStore.jellyfinToken(for: id), itemID: remote.id, backdrop: true, fallback: nil, maximumWidth: 1800)
        } else {
            LucentRemoteArtwork(request: entry.artwork(in: library, landscape: true), cacheKey: "hero|\(entry.id)", maximumPixels: 1800)
        }
    }
}
#endif
