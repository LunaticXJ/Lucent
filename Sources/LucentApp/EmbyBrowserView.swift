import SwiftUI
#if os(macOS)
import AppKit
private typealias PosterImage = NSImage
#else
import UIKit
private typealias PosterImage = UIImage
#endif

private enum EmbyBrowserPalette {
    static var page: Color {
        #if os(tvOS)
        .black
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
    static var panel: Color {
        #if os(tvOS)
        Color(white: 0.15)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemBackground)
        #endif
    }
}

@MainActor
private enum EmbyBrowseMemory {
    struct Page {
        let entries: [JellyfinItem]
        let total: Int
        let next: Int
        let savedAt: Date
    }
    static var pages: [String: Page] = [:]
    static var collectionTypes: [String: String] = [:]
    static func store(_ page: Page, key: String) {
        pages[key] = page
        if pages.count > 24, let oldest = pages.min(by: { $0.value.savedAt < $1.value.savedAt })?.key { pages.removeValue(forKey: oldest) }
    }
}

struct EmbyBrowserView: View {
    let source: EmbySource
    var parentID: String? = nil
    var title: String? = nil
    var embedded = false
    var collectionTypeHint: String? = nil
    var onBack: (() -> Void)? = nil

    var body: some View {
        if embedded {
            EmbyBrowserPageView(source: source, parentID: parentID, title: title ?? source.name, showsDone: false, catalogType: .from(collectionTypeHint), onBack: onBack)
        } else {
            NavigationStack {
                EmbyBrowserPageView(source: source, parentID: parentID, title: title ?? source.name, catalogType: .from(collectionTypeHint), onBack: onBack)
            }
        }
    }
}

private struct EmbyBrowserPageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let source: EmbySource
    let parentID: String?
    let title: String
    var showsDone = true
    var catalogLibraryID: String? = nil
    var catalogType: CatalogType? = nil
    var facet: EmbyClient.BrowseFacet? = nil
    var onBack: (() -> Void)? = nil

    enum CatalogType: String, Hashable {
        case series, movies, mixed
        static func from(_ value: String?) -> Self? {
            switch value?.lowercased() {
            case "tvshows": .series
            case "movies": .movies
            case "mixed", "homevideos", "": .mixed
            default: nil
            }
        }
    }
    private enum Section: String, CaseIterable {
        case programs = "节目", movies = "电影", genres = "风格"
        case studios = "工作室", folders = "文件夹"
    }

    private struct DirectoryRoute: Hashable {
        let parentID: String?
        let title: String
        let libraryID: String?
        let catalog: CatalogType?
        var facet: EmbyClient.BrowseFacet? = nil
    }
    @State private var selectedDirectory: DirectoryRoute?

    @State private var section: Section = .programs
    @State private var sort: EmbyClient.BrowseSort = .added
    @State private var ascending = false
    @State private var sortChosen = false
    private var effectiveSort: EmbyClient.BrowseSort { !sortChosen && itemType == "Series" ? .latestEpisodeAdded : sort }
    @State private var entries: [JellyfinItem] = []
    @State private var totalCount = 0
    @State private var nextStartIndex = 0
    @State private var loaded = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItemID: UUID?
    @State private var detectedCatalog: CatalogType?
    @State private var initialized = false
    @State private var displayedQuery: String?
    @State private var loadGeneration = UUID()
    private var libraryCacheKey: String { "\(source.id)|\(source.baseAddress)|\(source.userID)|\(parentID ?? "root")" }
    private var queryKey: String { "\(libraryCacheKey)|\(activeCatalog?.rawValue ?? "generic")|\(section.rawValue)|\(effectiveSort.rawValue)|\(ascending)|\(String(describing: facet))" }


    private var activeCatalog: CatalogType? { catalogType ?? detectedCatalog }
    private var isCatalogPage: Bool { activeCatalog != nil }
    private var libraryID: String? { catalogLibraryID ?? parentID }
    private var sections: [Section] {
        switch activeCatalog {
        case .series: [.programs, .genres, .studios, .folders]
        case .movies: [.programs, .genres, .studios, .folders]
        case .mixed: [.movies, .programs, .genres, .folders]
        case nil: []
        }
    }
    private var sortOptions: [EmbyClient.BrowseSort] {
        switch activeCatalog {
        case .series: EmbyClient.BrowseSort.seriesOptions
        case .movies: EmbyClient.BrowseSort.movieOptions
        case .mixed: EmbyClient.BrowseSort.mixedOptions
        case nil: []
        }
    }
    private var itemType: String? {
        switch activeCatalog {
        case .series: "Series"
        case .movies: "Movie"
        case .mixed:
            if facet != nil { "Movie,Series" }
            else if section == .movies { "Movie" }
            else if section == .programs { "Series" }
            else { "Movie,Series" }
        case nil: nil
        }
    }

    var body: some View {
        Group {
            if isCatalogPage { catalogPage }
            else { genericPage }
        }
        .background(EmbyBrowserPalette.page)
        .lucentCollectionChrome(title: title) {
            if isCatalogPage && selectedDirectory == nil && selectedItemID == nil { sortMenu }
            else { EmptyView() }
        }
        .task { await initialize() }
        .task(id: "\(initialized)|\(queryKey)") {
            guard initialized else { return }
            await reload()
        }
        .navigationDestination(item: $selectedDirectory) { route in
            EmbyBrowserPageView(source: source, parentID: route.parentID, title: route.title,
                showsDone: false, catalogLibraryID: route.libraryID, catalogType: route.catalog, facet: route.facet,
                onBack: { withAnimation { selectedDirectory = nil } }).lucentSecondaryPage()
        }
        .navigationDestination(item: $selectedItemID) { id in
            Group {
                MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
            }.lucentSecondaryPage()
        }
    }

    private var sortMenu: some View {
        Menu {
            Button {
                ascending.toggle()
            } label: {
                Label(ascending ? "升序" : "降序",
                      systemImage: ascending ? "arrow.up" : "arrow.down")
            }
            Divider()
            ForEach(sortOptions) { option in
                Button {
                    sortChosen = true
                    sort = option
                } label: {
                    if effectiveSort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else { Text(option.title) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 19, weight: .medium))
        }
        .buttonStyle(.automatic)
        .accessibilityLabel("排序：\(sort.title)，\(ascending ? "升序" : "降序")")
    }

    private var catalogPage: some View {
        VStack(spacing: 0) {
            if facet == nil {
                Picker("", selection: $section) {
                    ForEach(sections, id: \.self) { option in
                        Text(LocalizedStringKey(option == .programs ? (activeCatalog == .movies ? "电影" : "剧集") : option.rawValue))
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .padding(.horizontal, LucentUI.pageInset)
                .padding(.bottom, 12)
            }
            browserContent
        }
    }

    private var genericPage: some View { browserContent }

    private var isLibraryOverview: Bool { parentID == nil && catalogLibraryID == nil && facet == nil }
    private var cardAspectRatio: CGFloat { isLibraryOverview ? 16.0 / 9.0 : LucentUI.posterAspectRatio }
    private var showingCategories: Bool { facet == nil && (section == .genres || section == .studios) }
    private func isPlayable(_ entry: JellyfinItem) -> Bool {
        entry.type == "Series" || entry.mediaType == "Video" ||
            ["Movie", "Episode", "Video", "MusicVideo"].contains(entry.type)
    }

    private var browserContent: some View {
        GeometryReader { geometry in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                                count: isLibraryOverview ? LucentUI.libraryOverviewColumnCount : LucentUI.libraryColumnCount)
            ScrollView {
                LazyVStack(spacing: 20) {
                    if entries.isEmpty && !loaded && errorMessage == nil {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(0..<9, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 9) {
                                    LucentSkeleton(radius: LucentUI.cardRadius).aspectRatio(cardAspectRatio, contentMode: .fit)
                                    LucentSkeleton(radius: 3).frame(height: 12)
                                    LucentSkeleton(radius: 3).frame(width: 42, height: 10)
                                }
                            }
                        }.accessibilityLabel("正在读取目录…")
                    } else {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(entries, id: \.id) { entry in
                                Group {
                                    if showingCategories { categoryLink(entry) }
                                    else { posterLink(entry) }
                                }
                                .task { if entry.id == entries.suffix(6).first?.id { await loadNextPage() } }
                            }
                        }
                    }
                    pageStatus
                }
                .padding(.horizontal, LucentUI.pageInset)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await reload(force: true) }
        }
    }

    @ViewBuilder private func posterLink(_ entry: JellyfinItem) -> some View {
        if isPlayable(entry) {
            Button { selectedItemID = library.openEmbyItem(sourceID: source.id, remote: entry).id } label: {
                SeriesPosterTile(source: source, entry: entry)
            }.lucentContentButtonStyle()
        } else {
            Button { openDirectory(entry) } label: {
                SeriesPosterTile(source: source, entry: entry, folder: true, stretchesImage: isLibraryOverview, aspectRatio: cardAspectRatio)
            }.lucentContentButtonStyle()
        }
    }

    private func categoryLink(_ entry: JellyfinItem) -> some View {
        Button {
            withAnimation {
                selectedDirectory = DirectoryRoute(parentID: libraryID, title: entry.name,
                    libraryID: libraryID, catalog: activeCatalog,
                    facet: section == .genres ? .genre(entry.id) : .studio(entry.id))
            }
        } label: {
            SeriesPosterTile(source: source, entry: entry, folder: true,
                             folderSymbol: section == .genres ? "tag" : "building.2")
        }.lucentContentButtonStyle()
    }

    private func openDirectory(_ entry: JellyfinItem) {
        withAnimation {
            selectedDirectory = DirectoryRoute(parentID: entry.id, title: entry.name,
                libraryID: isCatalogPage ? libraryID : nil,
                catalog: activeCatalog ?? .from(entry.collectionType))
        }
    }

    private var hasMorePages: Bool { loaded && !entries.isEmpty && nextStartIndex < totalCount }

    @ViewBuilder private var pageStatus: some View {
        if let errorMessage {
            VStack(spacing: 10) {
                Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await reload(force: true) } }
            }
            .frame(maxWidth: .infinity).padding(20)
        } else if loading {
            if !entries.isEmpty { ProgressView().padding(.vertical, 16) }
        } else if loaded && entries.isEmpty {
            LucentStateView(title: "暂无内容", symbol: "square.grid.3x3")
                .frame(maxWidth: .infinity).padding(.top, 60)
        } else if hasMorePages {
            Button { Task { await loadNextPage() } } label: {
                Label("加载更多", systemImage: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .modifier(LucentGlass(shape: Capsule()))
            }.lucentContentButtonStyle()
        }
    }

    private func initialize() async {
        guard !initialized else { return }
        if catalogType == nil, let stored = EmbyBrowseMemory.collectionTypes[libraryCacheKey] {
            detectedCatalog = CatalogType(rawValue: stored)
        }
        if activeCatalog == nil, catalogLibraryID == nil, let parentID,
           let token = try? KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty,
           let detail = try? await ServerDetailClient.item(baseAddress: source.baseAddress,
                userID: source.userID, itemID: parentID, token: token, fields: "DateCreated") {
            guard !Task.isCancelled else { return }
            detectedCatalog = .from(detail.collectionType)
            if detectedCatalog == nil, detail.type == "CollectionFolder",
               detail.collectionType?.isEmpty != false { detectedCatalog = .mixed }
        }
        if let activeCatalog { EmbyBrowseMemory.collectionTypes[libraryCacheKey] = activeCatalog.rawValue }
        guard !Task.isCancelled else { return }
        if let first = sections.first { section = first }
        initialized = true
    }

    private func reload(force: Bool = false) async {
        if !force, loaded, displayedQuery == queryKey { return }
        loadGeneration = UUID()
        loading = false
        let key = queryKey
        if !force, let cached = EmbyBrowseMemory.pages[key], Date().timeIntervalSince(cached.savedAt) < 90 {
            entries = cached.entries; totalCount = cached.total; nextStartIndex = cached.next
            displayedQuery = key; loaded = true; errorMessage = nil
            return
        }
        if displayedQuery != key { entries = [] }
        displayedQuery = key
        totalCount = 0
        nextStartIndex = 0
        loaded = false
        errorMessage = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        let requestedAt = Date()
        guard !loading, !loaded || nextStartIndex < totalCount else { return }
        let generation = loadGeneration
        let key = queryKey
        let firstPage = nextStartIndex == 0
        loading = true
        defer { if generation == loadGeneration { loading = false } }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                errorMessage = "Emby 令牌已丢失，请重新连接服务器。"
                return
            }
            let page: EmbyClient.BrowsePage
            var fetchedCount: Int?
            if activeCatalog == .movies, sort == .resolution,
               (section == .programs || facet != nil) {
                var all: [JellyfinItem] = []
                var count = 0
                repeat {
                    let batch = try await EmbyClient.browse(source: source, token: token,
                                                            parentID: parentID,
                                                            startIndex: all.count, limit: 200,
                                                            itemType: "Movie", sort: .name,
                                                            facet: facet)
                    count = batch.totalCount
                    guard !batch.items.isEmpty else { break }
                    all.append(contentsOf: batch.items)
                } while all.count < count
                let sorted = all.sorted { lhs, rhs in
                    let a = resolutionPixels(lhs), b = resolutionPixels(rhs)
                    return a == b ? lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending :
                        (ascending ? a < b : a > b)
                }
                page = .init(items: sorted, totalCount: sorted.count)
                fetchedCount = sorted.count
            } else if isCatalogPage, facet == nil, (section == .genres || section == .studios),
               let libraryID {
                page = try await EmbyClient.categories(source: source, token: token,
                                                       parentID: libraryID,
                                                       kind: section == .genres ? "Genres" : "Studios",
                                                       itemType: activeCatalog == .movies ? "Movie" :
                                                           activeCatalog == .series ? "Series" : "Movie,Series",
                                                       startIndex: nextStartIndex, limit: 48)
            } else if isCatalogPage, section == .folders, facet == nil {
                // Filter on the server before it computes the page and total.
                page = try await EmbyClient.browse(source: source, token: token,
                    parentID: parentID, startIndex: nextStartIndex, limit: 48,
                    includeMediaDetails: false, foldersOnly: true)
            } else {
                page = try await EmbyClient.browse(source: source, token: token,
                                                   parentID: parentID,
                                                   startIndex: nextStartIndex, limit: 48,
                                                   itemType: itemType,
                                                   sort: effectiveSort, ascending: ascending,
                                                   facet: facet, includeMediaDetails: false)
            }
            guard !Task.isCancelled, generation == loadGeneration, key == queryKey else { return }
            if firstPage { entries = page.items }
            else {
                let existing = Set(entries.map(\.id))
                library.mergeServerCards(page.items, sourceID: source.id, requestedAt: requestedAt)
                entries.append(contentsOf: page.items.filter { !existing.contains($0.id) })
            }
            let count = fetchedCount ?? page.items.count
            nextStartIndex += count > 0 ? count : max(0, page.totalCount - nextStartIndex)
            totalCount = page.totalCount
            loaded = true
            errorMessage = nil
            if firstPage {
                EmbyBrowseMemory.store(.init(entries: entries, total: totalCount, next: nextStartIndex, savedAt: Date()), key: key)
            }
        } catch {
            guard !Task.isCancelled, generation == loadGeneration, key == queryKey else { return }
            errorMessage = "无法读取 Emby 目录：\(error.localizedDescription)"
        }
    }

    private func resolutionPixels(_ item: JellyfinItem) -> Int {
        item.mediaSources?.flatMap { $0.mediaStreams ?? [] }
            .filter { $0.type?.lowercased() == "video" }
            .map { ($0.width ?? 0) * ($0.height ?? 0) }.max() ?? 0
    }
}

private struct SeriesPosterTile: View {
    @EnvironmentObject private var library: LibraryStore
    let source: EmbySource
    let entry: JellyfinItem
    var folder = false
    var stretchesImage = false
    var aspectRatio: CGFloat = LucentUI.posterAspectRatio
    var folderSymbol = "folder"
    @State private var artwork: PosterImage?
    private var artworkKey: String { "\(source.id)|\(entry.id)|false" }
    private var displayedArtwork: PosterImage? { artwork ?? ArtworkImageDecoder.cachedImage(key: artworkKey, maximumPixelSize: 525) }

    private var metadata: LibraryStore.CardMetadata? {
        library.cardMetadata[LibraryStore.cardKey(sourceID: source.id, itemID: entry.id)]
    }

    var body: some View {
        LucentCatalogPosterLayout {
            GeometryReader { geometry in
                ZStack {
                    LucentArtworkPlaceholder(symbol: folder ? folderSymbol : "film", showsSymbol: displayedArtwork == nil)
                    if let artwork = displayedArtwork {
                        #if os(macOS)
                        Image(nsImage: artwork)
                            .resizable().modifier(LucentArtworkSizing(stretches: stretchesImage))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        #else
                        Image(uiImage: artwork)
                            .resizable().modifier(LucentArtworkSizing(stretches: stretchesImage))
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        #endif
                    }
                    if !folder, let rating = metadata?.rating ?? entry.communityRating, rating > 0 {
                        LucentRatingBadge(rating: rating)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
        } caption: {
            LucentCatalogCaption(title: metadata?.title ?? entry.name, yearText: folder ? nil : metadata?.year ?? entry.displayYearText)
        }
        .task(id: "\(source.id)|\(entry.id)") {
            if let cached = displayedArtwork { artwork = cached; return }
            if folder, folderSymbol != "folder", entry.imageTags?.primary == nil { return }
            guard let token = try? KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty,
                  let data = try? await LocalMediaCache.shared.imageData(
                    key: "emby|\(source.id)|\(entry.id)|false|350", fetch: {
                        try await EmbyClient.artwork(source: source, token: token, itemID: entry.id, backdrop: false, maxWidth: 350)
                    }) else { return }
            let decoded = await ArtworkImageDecoder.image(data: data, key: artworkKey, maximumPixelSize: 525)
            guard !Task.isCancelled else { return }
            artwork = decoded
        }
    }


}
