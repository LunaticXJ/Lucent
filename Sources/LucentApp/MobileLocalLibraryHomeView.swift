#if os(iOS)
import SwiftUI

/// A content home: favorites and horizontal shelves lead to complete library grids.
/// Indexing, probing and matching belong to Sources/Settings, never this surface.
struct MobileLocalLibraryHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var detailPresented: Bool
    @Binding var collectionPresented: Bool
    let manageSources: () -> Void
    @AppStorage("lucent.library.home.continue") private var showContinue = true
    @AppStorage("lucent.library.home.movies") private var showMovies = true
    @AppStorage("lucent.library.home.series") private var showSeries = true
    @AppStorage("lucent.library.home.favorites") private var showFavorites = true
    @AppStorage("lucent.library.home.unwatched") private var showUnwatched = false
    @State private var selectedItemID: UUID?
    @State private var selectedCollection: LocalCatalogCollection?
    @State private var transitionKey: String?
    @Namespace private var detailTransition

    var body: some View {
        let files = library.localLibraryItems.filter { $0.missingSince == nil }
        let cards = library.localCatalogCards
        GeometryReader { geometry in
            let posterWidth = min(154.0, max(112.0, (geometry.size.width - 60) / 2.8))
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    header
                    if files.isEmpty {
                        HomeLibraryEmptyState(action: manageSources, aggregateLibrary: true)
                            .padding(.top, 24)
                    } else {
                        if showContinue {
                            continueWatching(LocalCatalogCollection.continueWatching.items(cards: cards, files: files),
                                             width: min(300, geometry.size.width * 0.68))
                        }
                        categories(cards: cards, files: files)
                        if showMovies {
                            shelf(.recentMovies, items: LocalCatalogCollection.movies.items(cards: cards, files: files), width: posterWidth)
                        }
                        if showSeries {
                            shelf(.recentSeries, items: LocalCatalogCollection.series.items(cards: cards, files: files), width: posterWidth)
                        }
                        if showFavorites {
                            shelf(.favorites, items: LocalCatalogCollection.favorites.items(cards: cards, files: files), width: posterWidth)
                        }
                        if showUnwatched {
                            shelf(.unwatched, items: LocalCatalogCollection.unwatched.items(cards: cards, files: files), width: posterWidth)
                        }
                        if cards.isEmpty {
                            shelf(.other, items: LocalCatalogCollection.other.items(cards: cards, files: files), width: posterWidth)
                        }
                    }
                }
                .padding(.top, 66)
                .padding(.bottom, 44)
            }
            .background(Color(uiColor: .systemBackground))
        }
        .navigationDestination(item: $selectedItemID) { id in
            Group {
                if #available(iOS 18, *), let transitionKey {
                    MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
                        .navigationTransition(.zoom(sourceID: transitionKey, in: detailTransition))
                } else { MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library) }
            }.lucentSecondaryPage()
        }
        .navigationDestination(item: $selectedCollection) { collection in
            Group {
                LocalCatalogCollectionView(collection: collection, detailPresented: $detailPresented,
                                           onBack: { withAnimation { selectedCollection = nil } }).environmentObject(library)
            }.lucentSecondaryPage()
        }
        .onChange(of: selectedItemID) { _, _ in updateNavigationState() }
        .onChange(of: selectedCollection) { _, value in
            collectionPresented = value != nil
            if value == nil { updateNavigationState() }
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            Text("聚合媒体库").font(.system(size: 32, weight: .bold))
            Spacer()
            Menu {
                Menu("首页栏目", systemImage: "rectangle.3.group") {
                    Toggle("继续观看", isOn: $showContinue)
                    Toggle("最近添加的电影", isOn: $showMovies)
                    Toggle("最近添加的剧集", isOn: $showSeries)
                    Toggle("收藏", isOn: $showFavorites)
                    Toggle("待观看", isOn: $showUnwatched)
                }
                Button("全部影片", systemImage: "square.grid.2x2") { selectedCollection = .all }
                Button("管理片源", systemImage: "externaldrive") { manageSources() }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 20, weight: .semibold))
                    .frame(width: 44, height: 44).contentShape(Circle())
            }
            .foregroundStyle(.primary).accessibilityLabel("媒体库选项")
        }.padding(.horizontal, 22)
    }

    private func categories(cards: [MediaItem], files: [MediaItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("媒体库").font(.title3.bold()).padding(.horizontal, 22)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach([LocalCatalogCollection.movies, .series, .favorites, .other]) { collection in
                        let count = collection.items(cards: cards, files: files).count
                        Button { selectedCollection = collection } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Image(systemName: collection.icon).font(.system(size: 27, weight: .light))
                                    .foregroundStyle(.primary.opacity(0.85))
                                HStack {
                                    Text(LocalizedStringKey(collection.title)).font(.system(size: 15, weight: .semibold))
                                    Spacer(minLength: 5)
                                    Text(count.formatted(.number.locale(LocalizationPreferences.current.displayLocale))).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .padding(15).frame(width: 146, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 17))
                        }.buttonStyle(.plain)
                    }
                }.padding(.horizontal, 22)
            }
        }
    }

    private func shelf(_ collection: LocalCatalogCollection, items: [MediaItem], width: CGFloat) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    shelfHeader(collection)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 13) {
                            ForEach(items.prefix(20)) { item in
                                let key = "shelf:\(collection.id):\(item.id)"
                                Button { open(item, key: key) } label: {
                                    LocalCatalogPosterCard(item: item).frame(width: width)
                                        .modifier(HomeMatchedSource(key: key, namespace: detailTransition))
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 22)
                    }
                }
            }
        }
    }

    private func continueWatching(_ items: [MediaItem], width: CGFloat) -> some View {
        Group {
            if !items.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    shelfHeader(.continueWatching)
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(alignment: .top, spacing: 14) {
                            ForEach(items.prefix(12)) { item in
                                let key = "continue:\(item.id)"
                                Button { open(item, key: key) } label: {
                                    VStack(alignment: .leading, spacing: 8) {
                                        LocalCatalogArtwork(item: item, landscape: true)
                                            .frame(width: width, height: width * 9 / 16)
                                            .overlay(alignment: .bottom) {
                                                GeometryReader { proxy in
                                                    ZStack(alignment: .leading) {
                                                        Color.white.opacity(0.22)
                                                        Color.white.frame(width: proxy.size.width * item.progress)
                                                    }
                                                }.frame(height: 3)
                                            }
                                            .overlay(alignment: .bottomTrailing) {
                                                Image(systemName: "play.fill").font(.system(size: 13))
                                                    .foregroundStyle(.white).frame(width: 30, height: 30)
                                                    .background(.black.opacity(0.5), in: Circle()).padding(9)
                                            }
                                            .clipShape(RoundedRectangle(cornerRadius: 13))
                                            .modifier(HomeMatchedSource(key: key, namespace: detailTransition))
                                        Text(item.catalogDisplayTitle).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                        Text(resumeLabel(item)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    }.frame(width: width, alignment: .leading)
                                }.buttonStyle(.plain)
                            }
                        }.padding(.horizontal, 22)
                    }
                }
            }
        }
    }

    private func shelfHeader(_ collection: LocalCatalogCollection) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(collection.title)).font(.title3.bold())
            Spacer()
            Button { selectedCollection = collection } label: {
                HStack(spacing: 4) {
                    Text("查看全部").font(.subheadline)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                }.foregroundStyle(.secondary).padding(.vertical, 8)
            }.buttonStyle(.plain)
        }.padding(.horizontal, 22)
    }
    private func resumeLabel(_ item: MediaItem) -> String {
        let position = "已播放 \(Int(item.position / 60)) 分钟"
        return [item.identity?.episodeLabel, position].compactMap { $0 }.joined(separator: " · ")
    }
    private func open(_ item: MediaItem, key: String) { transitionKey = key; selectedItemID = item.id }
    private func updateNavigationState() { detailPresented = selectedItemID != nil }
}
#endif
