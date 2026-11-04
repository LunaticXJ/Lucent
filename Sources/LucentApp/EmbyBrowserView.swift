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
            case "mixed", "homevideos": .mixed
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
    @State private var sort: EmbyClient.BrowseSort = .name
    @State private var ascending = true
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
    private var queryKey: String { "\(libraryCacheKey)|\(activeCatalog?.rawValue ?? "generic")|\(section.rawValue)|\(sort.rawValue)|\(ascending)|\(String(describing: facet))" }


    private var activeCatalog: CatalogType? { catalogType ?? detectedCatalog }
    private var isCatalogPage: Bool { activeCatalog != nil }
    private var libraryID: String? { catalogLibraryID ?? parentID }
    private var sections: [Section] {
        switch activeCatalog {
        case .series: [.programs, .genres, .studios, .folders]
        case .movies: [.programs, .genres, .studios, .folders]
        case .mixed: [.programs, .movies, .genres, .folders]
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
        case .mixed: section == .movies ? "Movie" : "Movie,Series,Video"
        case nil: nil
        }
    }

    var body: some View {
        Group {
            if isCatalogPage { catalogPage }
            else { genericPage }
        }
        .background(EmbyBrowserPalette.page)
        .lucentCollectionChrome(title: title, back: { if let onBack { onBack() } else { dismiss() } }) {
            if isCatalogPage { sortMenu }
            else { Color.clear.frame(width: LucentUI.controlSize, height: LucentUI.controlSize) }
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
                    sort = option
                } label: {
                    if sort == option {
                        Label(option.title, systemImage: "checkmark")
                    } else { Text(option.title) }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 19, weight: .medium))
                .frame(width: 44, height: 44)
                .modifier(LucentGlass(shape: Circle()))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("排序：\(sort.title)，\(ascending ? "升序" : "降序")")
    }

    private var catalogPage: some View {
        VStack(spacing: 0) {
            if facet == nil {
                Picker("", selection: $section) {
                    ForEach(sections, id: \.self) { option in
                        Text(LocalizedStringKey(option == .programs ? (activeCatalog == .movies ? "电影" : activeCatalog == .series ? "剧集" : "全部影片") : option.rawValue))
                            .tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)
            }
            browserContent
        }
    }

    private var genericPage: some View { browserContent }

    private var usesPosterGrid: Bool {
        if !isCatalogPage { return entries.contains(where: isPlayable) }
        return section == .programs || section == .movies || facet != nil ||
            (section == .folders && activeCatalog != .series)
    }
    private func isPlayable(_ entry: JellyfinItem) -> Bool {
        entry.type == "Series" || entry.mediaType == "Video" ||
            ["Movie", "Episode", "Video", "MusicVideo"].contains(entry.type)
    }

    private var browserContent: some View {
        GeometryReader { geometry in
            let columns = Array(repeating: GridItem(.flexible(), spacing: 12),
                                count: max(3, Int((geometry.size.width - 40) / 160)))
            ScrollView {
                LazyVStack(spacing: 20) {
                    if entries.isEmpty && !loaded && errorMessage == nil {
                        LazyVGrid(columns: columns, spacing: 22) {
                            ForEach(0..<9, id: \.self) { _ in
                                VStack(alignment: .leading, spacing: 9) {
                                    LucentSkeleton(radius: LucentUI.cardRadius).aspectRatio(2.0 / 3.0, contentMode: .fit)
                                    LucentSkeleton(radius: 3).frame(height: 12)
                                    LucentSkeleton(radius: 3).frame(width: 42, height: 10)
                                }
                            }
                        }.accessibilityLabel("正在读取目录…")
                    } else if usesPosterGrid {
                        LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                            ForEach(entries, id: \.id) { entry in
                                posterLink(entry)
                                    .task { if entry.id == entries.suffix(6).first?.id { await loadNextPage() } }
                            }
                        }
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(entries, id: \.id) { entry in
                                directoryLink(entry)
                                    .task { if entry.id == entries.suffix(6).first?.id { await loadNextPage() } }
                            }
                        }
                    }
                    pageStatus
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .refreshable { await reload(force: true) }
        }
    }

    @ViewBuilder private func posterLink(_ entry: JellyfinItem) -> some View {
        if isPlayable(entry) {
            Button { selectedItemID = library.openEmbyItem(sourceID: source.id, remote: entry).id } label: {
                SeriesPosterTile(source: source, entry: entry, showUnplayed: entry.type == "Series")
            }.buttonStyle(.plain)
        } else {
            Button { openDirectory(entry) } label: {
                SeriesPosterTile(source: source, entry: entry, folder: true)
            }.buttonStyle(.plain)
        }
    }

    private func directoryLink(_ entry: JellyfinItem) -> some View {
        Button {
            if section == .genres || section == .studios {
                withAnimation {
                    selectedDirectory = DirectoryRoute(parentID: libraryID, title: entry.name,
                        libraryID: libraryID, catalog: activeCatalog,
                        facet: section == .genres ? .genre(entry.id) : .studio(entry.id))
                }
            } else { openDirectory(entry) }
        } label: {
            HStack(spacing: 16) {
                Image(systemName: section == .genres ? "tag" : section == .studios ? "building.2" : "folder")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(.secondary).frame(width: 28)
                Text(entry.name).font(.body.weight(.medium)).lineLimit(2)
                Spacer(minLength: 12)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .overlay(alignment: .bottom) { Divider().padding(.leading, 44) }
        }.buttonStyle(.plain)
    }

    private func openDirectory(_ entry: JellyfinItem) {
        withAnimation {
            selectedDirectory = DirectoryRoute(parentID: entry.id, title: entry.name,
                libraryID: isCatalogPage ? libraryID : nil,
                catalog: activeCatalog ?? .from(entry.collectionType))
        }
    }

    @ViewBuilder private var pageStatus: some View {
        if loading && !entries.isEmpty {
            ProgressView().padding(.vertical, 16)
        } else if loaded && nextStartIndex < totalCount {
            Button { Task { await loadNextPage() } } label: {
                Label("加载更多", systemImage: "chevron.down")
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 22).padding(.vertical, 12)
                    .modifier(LucentGlass(shape: Capsule()))
            }.buttonStyle(.plain)
        }
        if let errorMessage {
            VStack(spacing: 10) {
                Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await reload(force: true) } }
            }
            .frame(maxWidth: .infinity).padding(20)
        }
        if loaded && entries.isEmpty && errorMessage == nil {
            LucentStateView(title: "暂无内容", symbol: "square.grid.3x3")
                .frame(maxWidth: .infinity).padding(.top, 60)
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
        }
        if let activeCatalog { EmbyBrowseMemory.collectionTypes[libraryCacheKey] = activeCatalog.rawValue }
        guard !Task.isCancelled else { return }
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
                                                           activeCatalog == .series ? "Series" : "Movie,Series,Video",
                                                       startIndex: nextStartIndex, limit: 48)
            } else if isCatalogPage, section == .folders, facet == nil {
                let all = try await EmbyClient.browse(source: source, token: token,
                                                      parentID: parentID, startIndex: nextStartIndex, limit: 48,
                                                      includeMediaDetails: false)
                fetchedCount = all.items.count
                page = .init(items: all.items.filter { $0.isFolder == true && $0.type != "Series" },
                             totalCount: all.totalCount)
            } else {
                page = try await EmbyClient.browse(source: source, token: token,
                                                   parentID: parentID,
                                                   startIndex: nextStartIndex, limit: 48,
                                                   itemType: itemType,
                                                   sort: sort, ascending: ascending,
                                                   facet: facet, includeMediaDetails: false)
            }
            guard !Task.isCancelled, generation == loadGeneration, key == queryKey else { return }
            if firstPage { entries = page.items }
            else {
                let existing = Set(entries.map(\.id))
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
    let source: EmbySource
    let entry: JellyfinItem
    var folder = false
    var showUnplayed = true
    @State private var artwork: PosterImage?
    private var artworkKey: String { "\(source.id)|\(entry.id)|false" }
    private var displayedArtwork: PosterImage? { artwork ?? ArtworkImageDecoder.cachedImage(key: artworkKey, maximumPixelSize: 525) }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            GeometryReader { geometry in
                ZStack {
                    LucentArtworkPlaceholder(symbol: folder ? "folder" : "film", showsSymbol: displayedArtwork == nil)
                    if let artwork = displayedArtwork {
                        #if os(macOS)
                        Image(nsImage: artwork)
                            .resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        #else
                        Image(uiImage: artwork)
                            .resizable().scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                        #endif
                    }
                    if showUnplayed, !folder,
                       let count = entry.userData?.unplayedItemCount, count > 0 {
                        LucentCountBadge(count: count)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(7)
                    }
                    if !folder, let rating = entry.communityRating, rating > 0 {
                        LucentRatingBadge(rating: rating)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
            }
            .aspectRatio(folder ? 16.0 / 10.0 : 2.0 / 3.0, contentMode: .fit)
            LucentPosterCaption(title: entry.name,
                subtitle: !folder ? entry.productionYear.map { yearLabel(start: $0, endDate: entry.endDate) } : nil,
                lines: 1)
        }
        .accessibilityElement(children: .combine)
        .task(id: "\(source.id)|\(entry.id)") {
            if let cached = displayedArtwork { artwork = cached; return }
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

    private func yearLabel(start: Int, endDate: String?) -> String {
        guard let endDate, endDate.count >= 4,
              let endYear = Int(endDate.prefix(4)), endYear > start else { return String(start) }
        return "\(start) - \(endYear)"
    }
}
