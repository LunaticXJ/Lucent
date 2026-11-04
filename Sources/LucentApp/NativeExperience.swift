#if !os(iOS)
import SwiftUI
import Combine

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
            }.navigationTitle("Lucent").navigationSplitViewColumnWidth(min: 180, ideal: 220)
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
    var year: Int? { remote?.productionYear ?? plex?.year ?? local?.metadata?.year }
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
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            LucentRemoteArtwork(request: entry.artwork(in: library, landscape: landscape), cacheKey: "native|\(entry.id)|\(landscape)", maximumPixels: landscape ? 1280 : 750)
                .aspectRatio(landscape ? 16.0 / 9 : 2.0 / 3, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) { if let rating = entry.rating { LucentRatingBadge(rating: rating).padding(.trailing, 4).padding(.bottom, landscape && entry.progress > 0 ? 18 : 4) } }
                .overlay(alignment: .bottom) { if landscape && entry.progress > 0 { ProgressView(value: entry.progress).tint(.white).padding(10) } }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
            LucentPosterCaption(title: entry.title, subtitle: entry.year.map(String.init))
            if landscape { LucentPlaybackTimeCaption(position: entry.position, duration: entry.duration) }
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
    private struct Snapshot { let date: Date; let shelves: [NativeShelf] }
    private var snapshots: [String: Snapshot] = [:]
    private var generation = UUID()
    func load(catalog: NativeCatalog, library: LibraryStore, force: Bool = false) async {
        let request = UUID(); generation = request
        error = nil
        guard catalog.id != "library" else { shelves = []; loading = false; return }
        let cacheKey = catalog.id + "|" + (library.activeProfile?.id.uuidString ?? "default")
        if !force, let saved = snapshots[cacheKey], Date().timeIntervalSince(saved.date) < 86_400 {
            shelves = saved.shelves; loading = false; return
        }
        shelves = []; loading = true
        do {
            var result: [NativeShelf] = []
            if let id = catalog.sourceID, let source = library.embySources.first(where: { $0.id == id }) {
                guard let token = try KeychainPasswordStore.embyToken(for: id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                if force { try await library.synchronizeServerHome(sourceID: id, emby: true) }
                async let latest = EmbyClient.latest(source: source, token: token)
                async let resume = EmbyClient.resume(source: source, token: token)
                async let views = EmbyClient.browse(source: source, token: token, parentID: nil)
                let (new, continuing, libraries) = try await (latest, resume, views)
                result.append(.init(id: "continue", title: "继续观看", entries: continuing.items.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }, landscape: true))
                result.append(.init(id: "latest", title: "最近入库", entries: new.filter { $0.type != "Episode" }.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }))
                // Bound server concurrency and keep the server's library order.
                var pages: [String: [JellyfinItem]] = [:]
                for start in stride(from: 0, to: libraries.items.count, by: 4) {
                    let batch = Array(libraries.items[start..<min(start + 4, libraries.items.count)])
                    let values = await withTaskGroup(of: (String, [JellyfinItem]).self) { group in
                        for view in batch {
                            group.addTask {
                                let page = try? await EmbyClient.featured(source: source, token: token, parentID: view.id, itemTypes: EmbyClient.featuredItemTypes(for: view))
                                return (view.id, page?.items ?? [])
                            }
                        }
                        var values: [String: [JellyfinItem]] = [:]
                        for await (key, entries) in group { values[key] = entries }
                        return values
                    }
                    pages.merge(values) { _, new in new }
                    try Task.checkCancellation()
                }
                result += libraries.items.map { view in .init(id: view.id, title: view.name, entries: (pages[view.id] ?? []).map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }, parentID: view.id) }
            } else if let id = catalog.sourceID, let source = library.jellyfinSources.first(where: { $0.id == id }) {
                guard let token = try KeychainPasswordStore.jellyfinToken(for: id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                if force { try await library.synchronizeServerHome(sourceID: id, emby: false) }
                let items = try await JellyfinClient.browsePage(source: source, token: token, start: 0)
                result = [.init(id: "latest", title: "最近入库", entries: items.filter { $0.type != "Episode" }.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) })]
            } else if let id = catalog.sourceID, let source = library.plexSources.first(where: { $0.id == id }) {
                guard let token = try KeychainPasswordStore.plexToken(for: id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                if force { try await library.synchronizePlexHome(sourceID: id) }
                let items = try await PlexClient.catalogPage(source: source, token: token, start: 0)
                result = [.init(id: "latest", title: "最近入库", entries: items.filter { $0.type != "episode" }.map { .init(catalog: catalog, remote: nil, plex: $0, local: nil) })]
            }
            try Task.checkCancellation()
            guard generation == request else { return }
            shelves = result.filter { !$0.entries.isEmpty }
            let active = Set(NativeCatalog.all(in: library).map(\.id))
            snapshots = snapshots.filter { key, value in Date().timeIntervalSince(value.date) < 86_400 && active.contains(String(key.split(separator: "|").first ?? "")) }
            if snapshots.count >= 8, let oldest = snapshots.min(by: { $0.value.date < $1.value.date })?.key { snapshots[oldest] = nil }
            snapshots[cacheKey] = .init(date: Date(), shelves: shelves)
        } catch is CancellationError { return }
        catch { if generation == request { self.error = error.localizedDescription } }
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
    @AppStorage("lucent.home.autoplay") private var autoplay = true
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
                    LucentStateView(title: "暂无影片", symbol: "film", actionTitle: "添加片源", action: showSources)
                }
                ForEach(shelves) { shelf in
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            Text(LocalizedStringKey(shelf.title)).font(.title2.bold())
                            Spacer()
                            Button("查看全部") { allShelf = shelf }
                        }
                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 22) {
                                ForEach(shelf.entries.prefix(24)) { entry in
                                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry, landscape: shelf.landscape).frame(width: cardWidth(shelf.landscape)) }
                                        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle)
                                }
                            }.padding(12)
                        }
                    }
                }
            }.padding(contentInset)
        }.background(LucentUI.page).navigationTitle(catalog.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("首页内容", selection: Binding(get: { catalog.id }, set: { selection = $0 })) {
                        ForEach(catalogs) { value in
                            if let asset = value.asset { Label(value.name, image: asset).tag(value.id) }
                            else { Label(value.name, systemImage: "rectangle.stack").tag(value.id) }
                        }
                    }
                    Button("刷新首页", systemImage: "arrow.clockwise") { refresh() }
                } label: { Label("首页内容", systemImage: "rectangle.stack") }
            }
        }
        .task(id: "\(catalog.id)|\(localRebuild)") { await rebuildLocalShelves() }
        .onReceive(library.$catalogStructureRevision.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in localRebuild = UUID() }
        .onReceive(library.$items.debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in localRebuild = UUID() }
        .task(id: catalog.id + "|" + (library.activeProfile?.id.uuidString ?? "default")) { await model.load(catalog: catalog, library: library) }
        .task(id: "\(catalog.id)|\(autoplay)") {
            guard autoplay else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(7)) } catch { return }
                guard heroes.count > 1 else { continue }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.45)) { heroIndex = (heroIndex + 1) % heroes.count }
            }
        }
        .navigationDestination(item: $selected) { NativeEntryPage(route: $0).environmentObject(library) }
        .navigationDestination(item: $allShelf) { shelf in
            if let catalog = shelf.entries.first?.catalog, catalog.id != "library", shelf.id != "continue" {
                NativeServerBrowser(catalog: catalog, parentID: shelf.parentID, title: shelf.title).environmentObject(library)
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
        return ZStack(alignment: .bottomLeading) {
            NativeHeroBackground(entry: entry)
            LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 16) {
                DetailTitleArtwork(url: heroArtwork?.logoURL, title: heroArtwork?.localizedTitle ?? entry.title).frame(maxWidth: 420, alignment: .leading)
                if let rating = entry.rating { Label(rating.formatted(.number.precision(.fractionLength(1))), systemImage: "star.fill").font(.caption).foregroundStyle(.yellow) }
                Text(entry.overview).font(.footnote).lineLimit(3).frame(maxWidth: 720, alignment: .leading)
                HStack {
                    Button("查看详情", systemImage: "play.fill") { selected = entry.destination(in: library) }.buttonStyle(.borderedProminent)
                    Spacer()
                    Button("上一部", systemImage: "chevron.left") { heroIndex = (heroIndex + heroes.count - 1) % heroes.count }
                    Text("\(min(heroIndex, heroes.count - 1) + 1) / \(heroes.count)").monospacedDigit()
                    Button("下一部", systemImage: "chevron.right") { heroIndex = (heroIndex + 1) % heroes.count }
                }
            }.foregroundStyle(.white).padding(32)
        }.frame(height: 440).clipShape(RoundedRectangle(cornerRadius: 24)).id(entry.id)
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
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 260), spacing: 24)], spacing: 28) {
                ForEach(shelf.entries) { entry in
                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry) }.buttonStyle(.bordered)
                }
            }.padding(32)
        }.navigationTitle(shelf.title).background(LucentUI.page)
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
