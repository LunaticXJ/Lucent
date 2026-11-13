import SwiftUI

enum LocalCatalogCollection: String, Identifiable, Hashable {
    case all, movies, series, favorites, other, recentMovies, recentSeries, continueWatching, unwatched
    case mediaLibraries, chineseSeries, variety, chineseAnimation, asianSeries, westernSeries, documentaries
    static let homeCategories: [Self] = [.movies, .chineseSeries, .variety, .chineseAnimation, .asianSeries, .westernSeries, .documentaries]
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mediaLibraries: "我的媒体"
        case .chineseSeries: "国产剧"
        case .variety: "综艺"
        case .chineseAnimation: "国漫"
        case .asianSeries: "日韩剧"
        case .westernSeries: "欧美剧"
        case .documentaries: "纪录片"
        case .all: "全部影片"
        case .movies: "电影"
        case .series: "剧集"
        case .favorites: "收藏"
        case .other: "其他视频"
        case .recentMovies: "最近添加的电影"
        case .recentSeries: "最近添加的剧集"
        case .continueWatching: "继续观看"
        case .unwatched: "待观看"
        }
    }
    var icon: String {
        switch self {
        case .movies, .recentMovies: "film"
        case .series, .recentSeries: "tv"
        case .favorites: "heart"
        case .other: "play.rectangle.on.rectangle"
        case .continueWatching: "play.circle"
        case .unwatched: "bookmark"
        case .all, .mediaLibraries: "square.grid.2x2"
        case .chineseSeries, .asianSeries, .westernSeries: "tv"
        case .variety: "mic"
        case .chineseAnimation: "sparkles.tv"
        case .documentaries: "globe.asia.australia"
        }
    }
    func items(cards: [MediaItem], files: [MediaItem]) -> [MediaItem] {
        let groups = Dictionary(grouping: files, by: \.catalogGroupID)
        let dates = groups.mapValues { $0.map(\.addedAt).max() ?? .distantPast }
        let newest = cards.sorted { (dates[$0.catalogGroupID] ?? $0.addedAt) > (dates[$1.catalogGroupID] ?? $1.addedAt) }
        let favorites = Set(files.filter { $0.isFavorite || $0.seriesFavorite == true }.map(\.catalogGroupID))
        switch self {
        case .all, .mediaLibraries: return newest
        case .movies: return newest.filter { Self.category($0, members: groups[$0.catalogGroupID] ?? [$0]) == .movies }
        case .chineseSeries, .variety, .chineseAnimation, .asianSeries, .westernSeries, .documentaries:
            return newest.filter { Self.category($0, members: groups[$0.catalogGroupID] ?? [$0]) == self }
        case .recentMovies: return newest.filter { $0.identity?.seriesName == nil }
        case .series, .recentSeries: return newest.filter { $0.identity?.seriesName != nil }
        case .favorites: return newest.filter { favorites.contains($0.catalogGroupID) }
        case .other: return files.filter { $0.metadata == nil }.sorted { $0.addedAt > $1.addedAt }
        case .continueWatching: return cards.filter(\.isInProgress).sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .unwatched: return newest.filter { !Self.isWatched($0, members: groups[$0.catalogGroupID] ?? [$0]) }
        }
    }
    static func category(_ item: MediaItem, members: [MediaItem]) -> Self? {
        // Directory classification is explicit user organisation. Ignore the filename.
        let paths = members.map { $0.catalogRecognitionPath.components(separatedBy: "/").dropLast().map { $0.lowercased() } }
        let aliases: [(Self, Set<String>)] = [
            (.movies,["电影","movies","movie"]),(.chineseSeries,["国产剧","大陆剧","华语剧"]),
            (.variety,["综艺","综艺节目","variety"]),(.chineseAnimation,["国漫","国产动漫","国产动画"]),
            (.asianSeries,["日韩剧","日剧","韩剧"]),(.westernSeries,["欧美剧","美剧","英剧"]),
            (.documentaries,["纪录片","记录片","documentaries","documentary"])]
        for path in paths {
            for directory in path.reversed() {
                if let match = aliases.first(where: { $0.1.contains(directory) }) { return match.0 }
            }
        }
        let ids = Set(item.metadata?.genreIDs ?? [])
        let genres = Set((item.metadata?.genres ?? []).map { $0.lowercased() })
        if ids.contains(99) || !genres.isDisjoint(with:["纪录","纪录片","documentary"]) { return .documentaries }
        if item.identity?.seriesName == nil { return .movies }
        if !ids.isDisjoint(with:[10764,10767]) || !genres.isDisjoint(with:["真人秀","脱口秀","reality","talk","综艺"]) { return .variety }
        let countries = Set(item.metadata?.originCountries ?? [])
        let language = item.metadata?.originalLanguage?.lowercased() ?? ""
        let chinese = !countries.isDisjoint(with:["CN","HK","TW","MO"]) || (countries.isEmpty && ["zh","cn"].contains(language))
        let animation = ids.contains(16) || !genres.isDisjoint(with:["动画","animation","动漫"])
        if animation && chinese { return .chineseAnimation }
        if !countries.isDisjoint(with:["JP","KR"]) || (countries.isEmpty && ["ja","ko"].contains(language)) { return .asianSeries }
        if chinese { return .chineseSeries }
        if !countries.isDisjoint(with:["US","GB","CA","AU","NZ","FR","DE","IT","ES","SE","NO","DK","FI","NL","BE","IE","AT","CH","PL","RU"]) || (countries.isEmpty && ["en","fr","de","es","it","ru"].contains(language)) { return .westernSeries }
        return nil
    }

    static func isWatched(_ item: MediaItem, members: [MediaItem]) -> Bool {
        item.identity?.seriesName == nil ? members.contains(where: \.watched) : members.allSatisfy(\.watched)
    }

}

struct LocalCatalogArtwork: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    var landscape = false
    var backdropOnly = false
    private var url: URL? {
        let hasBackdrop = landscape && item.metadata?.backdropPath != nil
        let path = hasBackdrop || backdropOnly ? item.metadata?.backdropPath : item.metadata?.posterPath
        return path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(hasBackdrop ? "w780" : "w500")\($0)") }
    }
    var body: some View {
        let file = backdropOnly ? nil : library.posterURL(for: item)
        let target = file ?? url
        LucentRemoteArtwork(request: target.map { URLRequest(url: $0) },
            cacheKey: file.map { "local|\(item.id)|\($0.lastPathComponent)" } ?? "tmdb|\(url?.absoluteString ?? "")",
            maximumPixels: landscape ? 780 : 750,
            symbol: item.identity?.seriesName == nil ? "film" : "tv")
    }
}

struct LocalCatalogPosterCard: View {
    let item: MediaItem
    var showsPlaybackTime = false
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LocalCatalogArtwork(item: item)
                .overlay(alignment: showsPlaybackTime ? .topTrailing : .bottomTrailing) {
                    if let rating = item.metadata?.rating { LucentRatingBadge(rating: rating).padding(3) }
                }
                .aspectRatio(LucentUI.posterAspectRatio, contentMode: .fit)
                .overlay(alignment: .bottom) {
                    if showsPlaybackTime { LucentPlaybackProgressOverlay(position: item.position, duration: item.duration ?? item.technicalInfo?.duration, progress: item.progress) }
                }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
            LucentPosterCaption(title: item.catalogDisplayTitle, subtitle: item.catalogDisplayYearText ?? " ", lines: 1)
        }
        .contentShape(Rectangle())
    }
}

struct LocalCatalogCollectionView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    let collection: LocalCatalogCollection
    @Binding var detailPresented: Bool
    var onBack: (() -> Void)? = nil
    @State private var selectedCollection: LocalCatalogCollection?
    private enum Sort: String, CaseIterable, Identifiable {
        case title, newest, year, rating

        var id: Self { self }
        var title: String {
            switch self {
            case .title: "标题"
            case .newest: "添加日期"
            case .year: "年份"
            case .rating: "评分"
            }
        }
    }

    @State private var sort: Sort = .newest
    @State private var reversedSort = false
    @State private var genre = "全部题材"
    @State private var watched = "all"
    @State private var selectedItemID: UUID?
    @State private var matchingItem: MediaItem?
    @State private var transitionKey: String?
    @Namespace private var detailTransition
    private var all: [MediaItem] {
        collection.items(cards: library.localCatalogCards,
                         files: library.localLibraryItems.filter { $0.missingSince == nil })
    }
    private var genres: [String] { Array(Set(all.flatMap { $0.metadata?.genres ?? [] })).sorted() }
    private var displayed: [MediaItem] {
        let groups = Dictionary(grouping: library.localLibraryItems, by: \.catalogGroupID)
        let filtered = all.filter {
            let seen = LocalCatalogCollection.isWatched($0, members: groups[$0.catalogGroupID] ?? [$0])
            return (genre == "全部题材" || $0.metadata?.genres?.contains(genre) == true) &&
            (watched == "all" || (watched == "watched" ? seen : !seen))
        }
        let sorted: [MediaItem]
        switch sort {
        case .title:
            sorted = filtered.sorted { $0.catalogDisplayTitle.localizedStandardCompare($1.catalogDisplayTitle) == .orderedAscending }
        case .year:
            sorted = filtered.sorted { ($0.metadata?.year ?? 0) > ($1.metadata?.year ?? 0) }
        case .rating:
            sorted = filtered.sorted { ($0.metadata?.rating ?? 0) > ($1.metadata?.rating ?? 0) }
        case .newest:
            sorted = filtered
        }
        return reversedSort ? Array(sorted.reversed()) : sorted
    }
    private var filterMenu: some View {
        Menu {
            Section {
                ForEach(Sort.allCases) { option in
                    let selected = sort == option
                    let ascending = (option == .title) != reversedSort
                    let direction = selected ? (ascending ? " ↑" : " ↓") : ""
                    Toggle(isOn: Binding(
                        get: { sort == option },
                        set: { _ in
                            reversedSort = sort == option ? !reversedSort : false
                            sort = option
                        }
                    )) {
                        Text(option.title.lucentLocalized + direction)
                    }
                }
            } header: { Text("排序") }
            Picker("观看状态", selection: $watched) {
                Text("全部").tag("all"); Text("未观看").tag("unwatched"); Text("已观看").tag("watched")
            }
            if !genres.isEmpty {
                Picker("题材", selection: $genre) {
                    Text("全部题材").tag("全部题材")
                    ForEach(genres, id: \.self) { Text($0).tag($0) }
                }
            }
        } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 19, weight: .medium))
        }
        .buttonStyle(.automatic)
        .accessibilityLabel("排序与筛选")
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let columns = LucentUI.libraryColumnCount
                if collection == .mediaLibraries {
                    let files = library.localLibraryItems.filter { $0.missingSince == nil }
                    let cards = LocalCatalogIndex(files: files).cards
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: LucentUI.libraryOverviewColumnCount), spacing: 18) {
                        ForEach(LocalCatalogCollection.homeCategories.filter {
                            !$0.items(cards: cards, files: files).isEmpty
                        }) { category in
                            let values = category.items(cards: cards, files: files)
                            Button { withAnimation { selectedCollection = category } } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Group {
                                        if let first = values.first { LocalCatalogArtwork(item: first, landscape: true, backdropOnly: true) }
                                        else { LucentArtworkPlaceholder(symbol: category.icon) }
                                    }
                                    .aspectRatio(16.0 / 9.0, contentMode: .fit)
                                    .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
                                    LucentPosterCaption(title: category.title, subtitle: " ", lines: 1)
                                }
                            }.buttonStyle(.plain)
                        }
                    }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
                } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: columns),
                          alignment: .leading, spacing: 22) {
                    ForEach(displayed) { item in
                        Button {
                            transitionKey = collection == .continueWatching ? nil : "grid:\(item.id)"; selectedItemID = item.id
                        } label: {
                            LocalCatalogPosterCard(item: item, showsPlaybackTime: collection == .continueWatching)
                                .modifier(HomeMatchedSource(key: "grid:\(item.id)", namespace: detailTransition))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button(item.isFavorite ? "取消收藏" : "收藏", systemImage: "heart") { library.toggleFavorite(id: item.id) }
                            Button("匹配资料", systemImage: "text.magnifyingglass") { matchingItem = item }
                        }
                    }
                }.padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 32)
                if displayed.isEmpty {
                    LucentStateView(title: "暂无影片", symbol: collection.icon, message: "可以调整筛选条件，或在片源页面添加内容。")
                        .padding(.top, 80)
                }
                }
            }.background(LucentUI.page)
        }
        .lucentCollectionChrome(title: collection.title) { if selectedCollection == nil && selectedItemID == nil { filterMenu } }
        .navigationDestination(item: $selectedCollection) { destination in
            Group {
                LocalCatalogCollectionView(collection: destination, detailPresented: $detailPresented,
                                           onBack: { withAnimation { selectedCollection = nil } }).environmentObject(library)
            }.lucentSecondaryPage()
        }
        .navigationDestination(item: $selectedItemID) { id in
            Group {
                #if os(iOS)
                if #available(iOS 18, *), let transitionKey {
                    MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
                        .navigationTransition(.zoom(sourceID: transitionKey, in: detailTransition))
                } else { MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library) }
                #else
                MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
                #endif
            }.lucentSecondaryPage()
        }
        .onChange(of: selectedItemID) { _, value in detailPresented = value != nil }
        .sheet(item: $matchingItem) { item in MetadataMatchView(item: item).environmentObject(library) }
    }
}

/// Favorites belong to the Lucent user, independently of server user data.
struct LucentFavoritesView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var selectedItemID: UUID?
    @State private var selectedGroupID: String?
    private struct Group: Identifiable {
        let id: String
        let title: String
        var asset: String? = nil
        let items: [MediaItem]
    }
    private var groups: [Group] {
        let visible = Set(library.visibleItems.map(\.id))
        let local = LocalCatalogCollection.favorites.items(cards: library.localCatalogCards,
            files: library.localLibraryItems.filter { $0.missingSince == nil && visible.contains($0.id) })
        var result = [Group(id: "library", title: "聚合媒体库".lucentLocalized, items: local)]
        let favorites = library.visibleItems.filter(\.isFavorite)
        result += library.embySources.map { source in
            Group(id: "emby:\(source.id)", title: source.name, asset: source.kind.assetName, items: favorites.filter {
                if case .embyItem(let id, _) = $0.location { return id == source.id }; return false
            })
        }
        result += library.jellyfinSources.map { source in
            Group(id: "jellyfin:\(source.id)", title: source.name, asset: "JellyfinBrand", items: favorites.filter {
                if case .jellyfinItem(let id, _) = $0.location { return id == source.id }; return false
            })
        }
        result += library.plexSources.map { source in
            Group(id: "plex:\(source.id)", title: source.name, asset: "PlexBrand", items: favorites.filter {
                if case .plexItem(let id, _, _) = $0.location { return id == source.id }; return false
            })
        }
        return result.filter { !$0.items.isEmpty }
    }
    private func fillMissingMetadata(for group: Group) async {
        let ids = group.items.compactMap { item -> String? in
            let sourceID: UUID
            let itemID: String
            switch item.location {
            case .embyItem(let source, let id), .jellyfinItem(let source, let id):
                (sourceID, itemID) = (source, id)
            default: return nil
            }
            let metadata = library.cardMetadata[LibraryStore.cardKey(sourceID: sourceID, itemID: itemID)]
            let needsYear = metadata?.year == nil && item.catalogDisplayYearText == nil
            let needsRating = metadata?.rating == nil && item.metadata?.rating == nil
            return needsYear || needsRating ? itemID : nil
        }
        guard !ids.isEmpty else { return }
        let requestedAt = Date()
        if let source = library.embySources.first(where: { group.id == "emby:\($0.id)" }),
           let token = try? KeychainPasswordStore.embyToken(for: source.id),
           let items = try? await ServerCatalogSync.cachedItems(base: source.baseAddress, userID: source.userID,
               token: token, ids: ids, fields: "CommunityRating,ProductionYear"),
           !Task.isCancelled {
            library.mergeServerCards(items, sourceID: source.id, requestedAt: requestedAt)
        } else if let source = library.jellyfinSources.first(where: { group.id == "jellyfin:\($0.id)" }),
                  let token = try? KeychainPasswordStore.jellyfinToken(for: source.id),
                  let items = try? await ServerCatalogSync.cachedItems(base: source.baseAddress, userID: source.userID,
                      token: token, ids: ids, fields: "CommunityRating,ProductionYear"),
                  !Task.isCancelled {
            library.mergeServerCards(items, sourceID: source.id, requestedAt: requestedAt)
        }
    }
    private func removeFavorite(_ item: MediaItem) {
        if library.localLibraryItems.contains(where: { $0.id == item.id }) {
            library.setLocalSeriesFavorite(groupID: item.catalogGroupID, anchorID: item.id, favorite: false)
            let ids = library.localLibraryItems.filter { $0.catalogGroupID == item.catalogGroupID && $0.isFavorite }.map(\.id)
            for id in ids { library.toggleFavorite(id: id) }
        } else { library.toggleFavorite(id: item.id) }
    }
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if groups.isEmpty {
                    ContentUnavailableView("暂无收藏", systemImage: "heart",
                        description: Text("在内容详情页添加收藏后，会显示在这里。"))
                        .frame(maxWidth: .infinity).padding(.top, 64)
                }
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 12) {
                        Button {
                            selectedGroupID = group.id
                        } label: {
                            HStack {
                                LucentSourceLabel(title: group.title, asset: group.asset).font(.headline)
                                Spacer()
                                Text("\(group.items.count)").font(.subheadline)
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        ScrollView(.horizontal) {
                            LazyHStack(alignment: .top, spacing: 12) {
                                ForEach(group.items) { item in
                                    favoriteButton(item, in: group)
                                        .frame(width: 106)
                                }
                            }
                        }
                        .scrollIndicators(.hidden)
                        #if os(tvOS)
                        .focusSection()
                        #endif
                    }
                    .task(id: group.items.map(\.id)) { await fillMissingMetadata(for: group) }
                }
            }.padding(.horizontal, LucentUI.pageInset).padding(.top, 18).padding(.bottom, 32)
        }
        .background(LucentUI.page)
        .lucentCollectionChrome(title: "收藏") { EmptyView() }
        .navigationDestination(item: $selectedGroupID) { id in
            if let group = groups.first(where: { $0.id == id }) {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                             count: LucentUI.libraryColumnCount), spacing: 20) {
                        ForEach(group.items) { item in favoriteButton(item, in: group) }
                    }
                    .padding(LucentUI.pageInset)
                }
                .scrollIndicators(.hidden)
                .background(LucentUI.page)
                .lucentCollectionChrome(title: group.title) { EmptyView() }
                .lucentSecondaryPage()
            } else {
                ContentUnavailableView("暂无收藏", systemImage: "heart")
                    .lucentSecondaryPage()
            }
        }
        .navigationDestination(item: $selectedItemID) { id in
            MediaDetailView(itemID: id, onBack: { selectedItemID = nil })
                .environmentObject(library).lucentSecondaryPage()
        }
    }

    private func favoriteButton(_ item: MediaItem, in group: Group) -> some View {
        Button { selectedItemID = item.id } label: {
            if group.id == "library" {
                LocalCatalogPosterCard(item: item)
            } else {
                LucentFavoriteCard(item: item)
            }
        }
        .lucentContentButtonStyle()
        .contextMenu {
            Button("取消收藏", systemImage: "heart.slash") { removeFavorite(item) }
        }
    }
}

private struct LucentFavoriteCard: View {
    @EnvironmentObject private var library: LibraryStore
    let item: MediaItem
    private var metadataKey: String? {
        switch item.location {
        case .embyItem(let source, let id), .jellyfinItem(let source, let id), .plexItem(let source, let id, _):
            LibraryStore.cardKey(sourceID: source, itemID: id)
        default: nil
        }
    }

    private var metadata: LibraryStore.CardMetadata? { metadataKey.flatMap { library.cardMetadata[$0] } }

    private var request: URLRequest? {
        switch item.location {
        case .embyItem(let id, let remoteID):
            if let source = library.embySources.first(where: { $0.id == id }),
               let token = try? KeychainPasswordStore.embyToken(for: id) {
                return EmbyClient.posterRequest(source: source, token: token, itemID: remoteID)
            }
        case .jellyfinItem(let id, let remoteID):
            if let source = library.jellyfinSources.first(where: { $0.id == id }),
               let token = try? KeychainPasswordStore.jellyfinToken(for: id) {
                return JellyfinClient.posterRequest(source: source, token: token, itemID: remoteID)
            }
        case .plexItem(let id, _, _):
            if let source = library.plexSources.first(where: { $0.id == id }),
               let token = try? KeychainPasswordStore.plexToken(for: id), let thumb = item.serverPosterKey {
                return PlexClient.posterRequest(source: source, token: token, thumb: thumb)
            }
        default: break
        }
        if let url = library.posterURL(for: item) { return URLRequest(url: url) }
        return item.metadata?.posterURL.map { URLRequest(url: $0) }
    }
    private var fallbackArtwork: some View {
        let key: String
        switch item.location {
        case .jellyfinItem(let source, let id): key = "jellyfin|\(source)|\(id)"
        case .plexItem(let source, let id, _): key = "plex|\(source)|\(id)"
        default: key = "favorites|\(item.id)|\(item.metadata?.posterPath ?? "")"
        }
        return LucentRemoteArtwork(request: request, cacheKey: key)
    }

    @ViewBuilder private var artwork: some View {
        #if os(iOS)
        if case .embyItem(let id, let remoteID) = item.location,
           let source = library.embySources.first(where: { $0.id == id }) {
            EmbyArtwork(source: source, itemID: remoteID, backdrop: false, width: LucentUI.catalogPosterRequestWidth)
        } else {
            fallbackArtwork
        }
        #else
        fallbackArtwork
        #endif
    }

    var body: some View {
        LucentCatalogPosterLayout {
            artwork
                .aspectRatio(LucentUI.posterAspectRatio, contentMode: .fit)
                .overlay(alignment: .bottomTrailing) {
                    if let rating = metadata?.rating ?? item.metadata?.rating { LucentRatingBadge(rating: rating).padding(3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
        } caption: {
            LucentCatalogCaption(title: metadata?.title ?? item.catalogDisplayTitle, yearText: metadata?.year ?? item.catalogDisplayYearText)
        }

    }
}
