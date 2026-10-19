import SwiftUI
#if os(macOS)
import AppKit
private typealias PosterImage = NSImage
#else
import UIKit
private typealias PosterImage = UIImage
#endif

private struct SeriesToolbarVisibility: ViewModifier {
    func body(content: Content) -> some View {
        #if os(macOS)
        content
        #else
        content.toolbar(.hidden, for: .navigationBar)
        #endif
    }
}

struct EmbyBrowserView: View {
    let source: EmbySource
    var parentID: String? = nil
    var title: String? = nil

    var body: some View {
        NavigationStack {
            EmbyBrowserPageView(source: source, parentID: parentID, title: title ?? source.name)
        }
    }
}

private struct EmbyBrowserPageView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let source: EmbySource
    let parentID: String?
    let title: String
    var catalogLibraryID: String? = nil
    var catalogType: CatalogType? = nil
    var facet: EmbyClient.BrowseFacet? = nil

    enum CatalogType { case series, movies }
    private enum Section: String, CaseIterable {
        case programs = "节目", genres = "风格", studios = "工作室", folders = "文件夹"
    }

    @State private var section: Section = .programs
    @State private var sort: EmbyClient.BrowseSort = .name
    @State private var ascending = true
    @State private var entries: [JellyfinItem] = []
    @State private var totalCount = 0
    @State private var nextStartIndex = 0
    @State private var loaded = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var detectedCatalog: CatalogType?

    private var activeCatalog: CatalogType? { catalogType ?? detectedCatalog }
    private var isCatalogPage: Bool { activeCatalog != nil }
    private var libraryID: String? { catalogLibraryID ?? parentID }

    var body: some View {
        Group {
            if isCatalogPage { catalogPage }
            else { genericPage }
        }
        .background(Color(red: 0.985, green: 0.984, blue: 0.978))
        .preferredColorScheme(.light)
        .task { await initialize() }
        .sheet(item: $selectedItem) { item in
            MediaDetailView(itemID: item.id).environmentObject(library)
        }
    }

    private var catalogPage: some View {
        VStack(spacing: 0) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 19, weight: .medium))
                        .frame(width: 44, height: 44)
                        .background(.white, in: Circle())
                }
                Spacer()
                Text(title).font(.system(size: 18, weight: .semibold)).lineLimit(1)
                Spacer()
                Menu {
                    Button {
                        ascending.toggle()
                        Task { await reload() }
                    } label: {
                        Label(ascending ? "升序" : "降序",
                              systemImage: ascending ? "arrow.up" : "arrow.down")
                    }
                    Divider()
                    ForEach(activeCatalog == .movies ? EmbyClient.BrowseSort.movieOptions :
                            EmbyClient.BrowseSort.seriesOptions) { option in
                        Button {
                            sort = option
                            Task { await reload() }
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
                        .background(.white, in: Circle())
                }
                .accessibilityLabel("排序：\(sort.title)，\(ascending ? "升序" : "降序")")
                .disabled(loading)
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if facet == nil {
                HStack(spacing: 2) {
                    ForEach(Section.allCases, id: \.self) { option in
                        Button {
                            guard section != option else { return }
                            section = option
                            Task { await reload() }
                        } label: {
                            Text(option == .programs && activeCatalog == .movies ? "电影" : option.rawValue)
                                .font(.system(size: 14, weight: section == option ? .semibold : .regular))
                                .frame(maxWidth: .infinity)
                                .frame(height: 34)
                                .background(section == option ? .white : .clear,
                                            in: Capsule())
                        }
                        .foregroundStyle(.black)
                        .disabled(loading)
                    }
                }
                .padding(3)
                .background(Color.black.opacity(0.055), in: Capsule())
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }

            ScrollView {
                if section == .programs || facet != nil ||
                    (section == .folders && activeCatalog == .movies) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                        GridItem(.flexible(), spacing: 14),
                                        GridItem(.flexible(), spacing: 14)],
                              alignment: .leading, spacing: 19) {
                        ForEach(entries, id: \.id) { entry in
                            if section == .folders && facet == nil {
                                NavigationLink {
                                    EmbyBrowserPageView(source: source, parentID: entry.id,
                                                        title: entry.name,
                                                        catalogLibraryID: libraryID,
                                                        catalogType: activeCatalog)
                                } label: {
                                    SeriesPosterTile(source: source, entry: entry, folder: true)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Button {
                                    selectedItem = library.openEmbyItem(sourceID: source.id, remote: entry)
                                } label: {
                                    SeriesPosterTile(source: source, entry: entry,
                                                     folder: false,
                                                     showUnplayed: activeCatalog == .series)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                } else {
                    LazyVStack(spacing: 9) {
                        ForEach(entries, id: \.id) { entry in
                            NavigationLink {
                                EmbyBrowserPageView(source: source,
                                                    parentID: section == .folders ? entry.id : libraryID,
                                                    title: entry.name,
                                                    catalogLibraryID: libraryID,
                                                    catalogType: activeCatalog,
                                                    facet: section == .genres ? .genre(entry.id) :
                                                        section == .studios ? .studio(entry.id) : nil)
                            } label: {
                                HStack(spacing: 14) {
                                    Image(systemName: section == .folders ? "folder.fill" :
                                          section == .genres ? "tag.fill" : "building.2.fill")
                                        .font(.system(size: 18))
                                        .foregroundStyle(Color(red: 0.27, green: 0.42, blue: 0.56))
                                        .frame(width: 32)
                                    Text(entry.name).font(.system(size: 16, weight: .medium))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                .foregroundStyle(.primary)
                                .padding(16)
                                .background(.white, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                pageStatus
            }
            .contentMargins(.horizontal, 20)
            .refreshable { await reload() }
        }
        .modifier(SeriesToolbarVisibility())
    }

    private var genericPage: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                if entry.type == "Series" || entry.mediaType == "Video" ||
                    ["Movie", "Episode", "Video", "MusicVideo"].contains(entry.type) {
                    Button {
                        selectedItem = library.openEmbyItem(sourceID: source.id, remote: entry)
                    } label: {
                        Label(entry.name, systemImage: entry.type == "Series" ? "tv" : "play.rectangle")
                    }
                } else {
                    NavigationLink {
                        EmbyBrowserPageView(source: source, parentID: entry.id, title: entry.name)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                }
            }
            pageStatus
        }
        .navigationTitle(title)
        .toolbar { ToolbarItem(placement: .cancellationAction) {
            Button("完成") { dismiss() }
        }}
        .refreshable { await reload() }
    }

    @ViewBuilder private var pageStatus: some View {
        if loaded && nextStartIndex < totalCount {
            Button("加载更多") { Task { await loadNextPage() } }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .disabled(loading)
        }
        if loading { ProgressView("正在读取目录…").frame(maxWidth: .infinity).padding(16) }
        if let errorMessage {
            VStack(spacing: 10) {
                Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
                Button("重试") { Task { await reload() } }
            }
            .frame(maxWidth: .infinity).padding(20)
        }
        if loaded && entries.isEmpty && errorMessage == nil {
            ContentUnavailableView("暂无内容", systemImage: "square.grid.3x3")
                .frame(maxWidth: .infinity).padding(.top, 60)
        }
    }

    private func initialize() async {
        if catalogLibraryID == nil, let parentID,
           let token = try? KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty,
           let detail = try? await ServerDetailClient.item(baseAddress: source.baseAddress,
                                                           userID: source.userID,
                                                           itemID: parentID, token: token) {
            switch detail.collectionType?.lowercased() {
            case "tvshows": detectedCatalog = .series
            case "movies": detectedCatalog = .movies
            default: break
            }
        }
        await reload()
    }

    private func reload() async {
        guard !loading else { return }
        entries = []
        totalCount = 0
        nextStartIndex = 0
        loaded = false
        errorMessage = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !loading, !loaded || nextStartIndex < totalCount else { return }
        loading = true
        defer { loading = false }
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
                                                       itemType: activeCatalog == .movies ? "Movie" : "Series",
                                                       startIndex: nextStartIndex)
            } else if isCatalogPage, section == .folders, facet == nil {
                let all = try await EmbyClient.browse(source: source, token: token,
                                                      parentID: parentID, startIndex: nextStartIndex)
                fetchedCount = all.items.count
                page = .init(items: all.items.filter { $0.isFolder == true && $0.type != "Series" },
                             totalCount: all.totalCount)
            } else {
                page = try await EmbyClient.browse(source: source, token: token,
                                                   parentID: parentID,
                                                   startIndex: nextStartIndex,
                                                   itemType: activeCatalog == .movies ? "Movie" :
                                                       activeCatalog == .series ? "Series" : nil,
                                                   sort: sort, ascending: ascending,
                                                   facet: facet)
            }
            entries.append(contentsOf: page.items)
            let count = fetchedCount ?? page.items.count
            nextStartIndex += count > 0 ? count : max(0, page.totalCount - nextStartIndex)
            totalCount = page.totalCount
            loaded = true
            errorMessage = nil
        } catch {
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

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 13)
                        .fill(Color(red: 0.18, green: 0.22, blue: 0.28))
                    if let artwork {
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
                    } else {
                        Image(systemName: "film")
                            .font(.system(size: 28, weight: .light))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    if showUnplayed, !folder,
                       let count = entry.userData?.unplayedItemCount, count > 0 {
                        Text(String(count))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 22)
                            .background(Color(red: 0.02, green: 0.57, blue: 0.94), in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                            .padding(7)
                    }
                    if !folder, let rating = entry.communityRating, rating > 0 {
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 4))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 13))
            }
            .aspectRatio(0.68, contentMode: .fit)
            Text(entry.name)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .padding(.top, 3)
            if !folder, let year = entry.productionYear {
                Text(yearLabel(start: year, endDate: entry.endDate))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .task(id: entry.id) {
            guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                  !token.isEmpty,
                  let data = try? await EmbyClient.artwork(source: source, token: token,
                                                           itemID: entry.id, backdrop: false,
                                                           maxWidth: 360) else { return }
            artwork = PosterImage(data: data)
        }
    }

    private func yearLabel(start: Int, endDate: String?) -> String {
        guard let endDate, endDate.count >= 4,
              let endYear = Int(endDate.prefix(4)), endYear > start else { return String(start) }
        return "\(start) - \(endYear)"
    }
}
