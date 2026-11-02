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
        let favorites = Set(files.filter(\.isFavorite).map(\.catalogGroupID))
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
    private var url: URL? {
        let hasBackdrop = landscape && item.metadata?.backdropPath != nil
        let path = hasBackdrop ? item.metadata?.backdropPath : item.metadata?.posterPath
        return path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(hasBackdrop ? "w780" : "w500")\($0)") }
    }
    var body: some View {
        let file = library.posterURL(for: item)
        let target = file ?? url
        LucentRemoteArtwork(request: target.map { URLRequest(url: $0) },
            cacheKey: file.map { "local|\(item.id)|\($0.lastPathComponent)" } ?? "tmdb|\(url?.absoluteString ?? "")",
            maximumPixels: landscape ? 780 : 750,
            symbol: item.identity?.seriesName == nil ? "film" : "tv")
    }
}

struct LocalCatalogPosterCard: View {
    let item: MediaItem
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            LocalCatalogArtwork(item: item)
                .overlay(alignment: .bottomTrailing) {
                    if let rating = item.metadata?.rating { LucentRatingBadge(rating: rating).padding(5) }
                }
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
            LucentPosterCaption(title: item.catalogDisplayTitle, subtitle: item.metadata?.year.map(String.init) ?? " ")
        }
        .contentShape(Rectangle())
    }
}

struct LocalCatalogCollectionView: View {
    @EnvironmentObject private var library: LibraryStore
    let collection: LocalCatalogCollection
    @Binding var detailPresented: Bool
    @State private var sort = "newest"
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
        switch sort {
        case "title": return filtered.sorted { $0.catalogDisplayTitle.localizedStandardCompare($1.catalogDisplayTitle) == .orderedAscending }
        case "year": return filtered.sorted { ($0.metadata?.year ?? 0) > ($1.metadata?.year ?? 0) }
        case "rating": return filtered.sorted { ($0.metadata?.rating ?? 0) > ($1.metadata?.rating ?? 0) }
        default: return filtered
        }
    }
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                let columns = max(3, Int((geometry.size.width - 28) / 150))
                if collection == .mediaLibraries {
                    LazyVGrid(columns: [GridItem(.flexible()),GridItem(.flexible())], spacing:16) {
                        ForEach(LocalCatalogCollection.homeCategories.filter { !$0.items(cards: library.localCatalogCards, files: library.localLibraryItems.filter { $0.missingSince == nil }).isEmpty }) { category in
                            let values = category.items(cards:library.localCatalogCards, files:library.localLibraryItems)
                            NavigationLink(value:category) {
                                ZStack(alignment:.bottomLeading) {
                                    if let first = values.first { LocalCatalogArtwork(item:first,landscape:true) }
                                    else { LucentUI.panel }
                                    LinearGradient(colors:[.clear,.black.opacity(0.8)],startPoint:.top,endPoint:.bottom)
                                    HStack { Text(LocalizedStringKey(category.title)).bold(); Spacer(); Text(values.count.formatted(.number.locale(LocalizationPreferences.current.displayLocale))) }
                                        .font(.subheadline).foregroundStyle(.white).padding(14)
                                }.frame(height:112).clipShape(RoundedRectangle(cornerRadius:16))
                            }.buttonStyle(.plain)
                        }
                    }.padding(20)
                    NavigationLink("全部影片",value:LocalCatalogCollection.all).padding(.bottom,24)
                } else {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: columns),
                          alignment: .leading, spacing: 22) {
                    ForEach(displayed) { item in
                        Button {
                            transitionKey = "grid:\(item.id)"; selectedItemID = item.id
                        } label: {
                            LocalCatalogPosterCard(item: item)
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
        .navigationTitle(collection.title).lucentNavigationTitleStyle()
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("排序", selection: $sort) {
                        Text("最近添加").tag("newest"); Text("名称").tag("title")
                        Text("年份").tag("year"); Text("评分").tag("rating")
                    }
                    Picker("观看状态", selection: $watched) {
                        Text("全部").tag("all"); Text("未观看").tag("unwatched"); Text("已观看").tag("watched")
                    }
                    if !genres.isEmpty {
                        Picker("题材", selection: $genre) {
                            Text("全部题材").tag("全部题材")
                            ForEach(genres, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } label: { Image(systemName: "line.3.horizontal.decrease") }
                .accessibilityLabel("排序与筛选")
            }
        }
        .navigationDestination(for: LocalCatalogCollection.self) { destination in
            LocalCatalogCollectionView(collection:destination,detailPresented:$detailPresented).environmentObject(library)
        }
        .navigationDestination(item: $selectedItemID) { id in
            #if os(iOS)
            if #available(iOS 18, *), let transitionKey {
                MediaDetailView(itemID: id).environmentObject(library)
                    .navigationTransition(.zoom(sourceID: transitionKey, in: detailTransition))
            } else { MediaDetailView(itemID: id).environmentObject(library) }
            #else
            MediaDetailView(itemID: id).environmentObject(library)
            #endif
        }
        .onChange(of: selectedItemID) { _, value in detailPresented = value != nil }
        .sheet(item: $matchingItem) { item in MetadataMatchView(item: item).environmentObject(library) }
    }
}
