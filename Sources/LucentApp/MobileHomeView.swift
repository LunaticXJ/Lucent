#if os(iOS)
import SwiftUI
import UIKit

@MainActor
private enum HomePalette {
    static let background = Color(red: 0.981, green: 0.950, blue: 0.939)
    static let ink = Color(red: 0.115, green: 0.137, blue: 0.170)
    static let muted = Color(red: 0.44, green: 0.45, blue: 0.48)
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let inset: CGFloat = isPad ? 42 : 20
    static let heroHeight: CGFloat = isPad ? 510 : 390
    static let continueWidth: CGFloat = isPad ? 285 : 185
    static let categoryWidth: CGFloat = isPad ? 250 : 165
    static let posterWidth: CGFloat = isPad ? 160 : 105
    static let sectionSpacing: CGFloat = isPad ? 38 : 30
}

@MainActor
private enum ArtworkCache {
    static var images: [String: UIImage] = [:]
}

private struct EmbyArtwork: View {
    let source: EmbySource
    let itemID: String
    let backdrop: Bool
    let width: Int
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.init(red: 0.13, green: 0.23, blue: 0.39),
                                    .init(red: 0.48, green: 0.35, blue: 0.43)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: backdrop ? "film.stack" : "film")
                    .font(.system(size: backdrop ? 48 : 30, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.45))
            }
        }
        .clipped()
        .task(id: "\(source.id)|\(itemID)|\(backdrop)") {
            let key = "\(source.id)|\(itemID)|\(backdrop)|\(width)"
            if let cached = ArtworkCache.images[key] { image = cached; return }
            guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                  !token.isEmpty else { return }
            for useBackdrop in backdrop ? [true, false] : [false] {
                guard let data = try? await EmbyClient.artwork(source: source, token: token,
                                                               itemID: itemID, backdrop: useBackdrop,
                                                               maxWidth: width),
                      let loaded = UIImage(data: data) else { continue }
                ArtworkCache.images[key] = loaded
                image = loaded
                break
            }
        }
    }
}

private struct HomeShelf: Identifiable {
    let view: JellyfinItem
    let items: [JellyfinItem]
    var id: String { view.id }
}

private struct HomeBrowserRoute: Identifiable {
    let source: EmbySource
    let parentID: String?
    let title: String?
    var id: String { "\(source.id)|\(parentID ?? "root")" }
}

struct MobileHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    let showSources: () -> Void

    @State private var selectedSourceID: UUID?
    @State private var views: [JellyfinItem] = []
    @State private var latest: [JellyfinItem] = []
    @State private var continuing: [JellyfinItem] = []
    @State private var continuingTotal = 0
    @State private var shelves: [HomeShelf] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var browserRoute: HomeBrowserRoute?

    private var source: EmbySource? {
        library.embySources.first { $0.id == selectedSourceID } ?? library.embySources.first
    }

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero.frame(width: viewport.size.width)
                VStack(alignment: .leading, spacing: HomePalette.sectionSpacing) {
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(HomePalette.muted)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 18))
                    }
                    if !continuing.isEmpty { continueSection }
                    if !views.isEmpty { mediaSection }
                    ForEach(shelves) { shelf in posterSection(shelf) }
                    if latest.isEmpty && !isLoading && source != nil && errorMessage == nil {
                        Text("暂无推荐影片，进入片源浏览全部内容。")
                            .foregroundStyle(HomePalette.muted)
                    }
                }
                .padding(.top, HomePalette.isPad ? 30 : 20)
                .padding(.bottom, 56)
            }
            .frame(width: viewport.size.width, alignment: .leading)
        }
        }
        .background(HomePalette.background)
        .ignoresSafeArea(edges: .top)
        .preferredColorScheme(.light)
        .task(id: source?.id) { await loadHome() }
        .refreshable { await loadHome() }
        .sheet(item: $selectedItem) { item in
            MediaDetailView(itemID: item.id).environmentObject(library)
        }
        .sheet(item: $browserRoute) { route in
            EmbyBrowserView(source: route.source, parentID: route.parentID, title: route.title)
                .environmentObject(library)
        }
    }

    private var hero: some View {
        GeometryReader { geometry in
        ZStack(alignment: .bottomLeading) {
            if let source, let item = latest.first {
                EmbyArtwork(source: source, itemID: item.id, backdrop: true, width: 1200)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            } else {
                LinearGradient(colors: [.init(red: 0.10, green: 0.22, blue: 0.40),
                                        .init(red: 0.56, green: 0.49, blue: 0.53)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(width: geometry.size.width, height: geometry.size.height)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.38), location: 0),
                .init(color: .clear, location: 0.30),
                .init(color: .black.opacity(0.52), location: 0.50),
                .init(color: HomePalette.background.opacity(0.88), location: 0.73),
                .init(color: HomePalette.background, location: 0.95)
            ], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    if let source {
                        Menu {
                            ForEach(library.embySources) { option in
                                Button(option.name) { selectedSourceID = option.id }
                            }
                            Divider()
                            Button("管理片源", systemImage: "externaldrive") { showSources() }
                        } label: {
                            Label(source.name, systemImage: "play.square.stack.fill")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .padding(.horizontal, 14).padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule())
                        }
                    } else {
                        Text("LUCENT")
                            .font(.caption.bold()).tracking(2)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule())
                    }
                    Spacer()
                }
                .foregroundStyle(HomePalette.ink)
                .padding(.top, HomePalette.isPad ? 72 : 60)
                Spacer(minLength: 0)
                if let item = latest.first {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("新近入库").font(.caption.weight(.semibold)).tracking(2)
                            .foregroundStyle(.white.opacity(0.9))
                        Text(item.name)
                            .font(.system(size: HomePalette.isPad ? 48 : 34,
                                          weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                            .padding(.top, 8)
                        HStack(spacing: 8) {
                            if let rating = item.communityRating {
                                Label(rating.formatted(.number.precision(.fractionLength(1))),
                                      systemImage: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                            if let year = item.productionYear { Text(String(year)) }
                            Text("电影")
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.top, 8)
                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview)
                                .font(HomePalette.isPad ? .body : .subheadline)
                                .foregroundStyle(HomePalette.ink.opacity(0.84))
                                .lineLimit(2)
                                .padding(.top, 14)
                        }
                        Button {
                            open(item)
                        } label: {
                            Label("查看影片", systemImage: "play.fill")
                                .font(.subheadline.bold())
                                .padding(.horizontal, 18).padding(.vertical, 12)
                                .background(HomePalette.ink, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        .padding(.top, 18)
                    }
                    .frame(maxWidth: HomePalette.isPad ? 640 : .infinity,
                           alignment: .leading)
                } else {
                    Text("让好故事，触手可及")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                    Text(source == nil ? "添加片源，开始探索你的影片。" : "正在读取服务器推荐…")
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.top, 8)
                    Button("浏览片源") { showSources() }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 18)
                }
            }
            .frame(width: geometry.size.width - HomePalette.inset * 2,
                   alignment: .leading)
            .padding(.horizontal, HomePalette.inset)
            .padding(.bottom, 24)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .clipped()
        }
        .frame(height: HomePalette.heroHeight)
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("继续观看", count: continuingTotal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let source {
                        ForEach(continuing, id: \.id) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottom) {
                                        EmbyArtwork(source: source, itemID: item.id,
                                                    backdrop: true, width: 500)
                                        LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                       startPoint: .center, endPoint: .bottom)
                                        ProgressView(value: progress(item))
                                            .tint(.white)
                                            .padding(10)
                                    }
                                    .frame(width: HomePalette.continueWidth,
                                           height: HomePalette.isPad ? 160 : 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(item.name).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(HomePalette.ink).lineLimit(1)
                                    if let label = item.identity.episodeLabel {
                                        Text(label).font(.caption).foregroundStyle(HomePalette.muted)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: HomePalette.continueWidth, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HomePalette.inset)
            }
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("我的媒体", count: views.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    if let source {
                        ForEach(views, id: \.id) { view in
                            Button {
                                browserRoute = HomeBrowserRoute(source: source, parentID: view.id,
                                                               title: view.name)
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    if let first = shelves.first(where: { $0.id == view.id })?.items.first {
                                        EmbyArtwork(source: source, itemID: first.id,
                                                    backdrop: true, width: 500)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.isPad ? 145 : 120)
                                            .clipped()
                                    } else {
                                        LinearGradient(colors: [.init(red: 0.34, green: 0.51, blue: 0.52),
                                                                .init(red: 0.18, green: 0.27, blue: 0.36)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.isPad ? 145 : 120)
                                    }
                                    LinearGradient(colors: [.clear, .black.opacity(0.82)],
                                                   startPoint: .center, endPoint: .bottom)
                                        .frame(width: HomePalette.categoryWidth,
                                               height: HomePalette.isPad ? 145 : 120)
                                    Text(view.name)
                                        .font(.system(size: HomePalette.isPad ? 16 : 13,
                                                      weight: .semibold))
                                        .foregroundStyle(.white)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                        .frame(width: HomePalette.categoryWidth - 24,
                                               alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(12)
                                }
                                .frame(width: HomePalette.categoryWidth,
                                       height: HomePalette.isPad ? 145 : 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HomePalette.inset)
            }
        }
    }

    private func posterSection(_ shelf: HomeShelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                if let source {
                    browserRoute = HomeBrowserRoute(source: source, parentID: shelf.view.id,
                                                   title: shelf.view.name)
                }
            } label: {
                heading(shelf.view.name, count: nil)
            }
            .buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let source {
                        ForEach(shelf.items, id: \.id) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottomTrailing) {
                                        EmbyArtwork(source: source, itemID: item.id,
                                                    backdrop: false, width: 350)
                                        if let rating = item.communityRating {
                                            Text(rating.formatted(.number.precision(.fractionLength(1))))
                                                .font(.caption.bold()).foregroundStyle(.white)
                                                .padding(5)
                                                .background(.black.opacity(0.65), in: Capsule())
                                                .padding(8)
                                        }
                                    }
                                    .frame(width: HomePalette.posterWidth,
                                           height: HomePalette.isPad ? 240 : 158)
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                    Text(item.name).font(.subheadline.weight(.medium))
                                        .foregroundStyle(HomePalette.ink).lineLimit(1)
                                    if let year = item.productionYear {
                                        Text(String(year)).font(.caption).foregroundStyle(HomePalette.muted)
                                    }
                                }
                                .frame(width: HomePalette.posterWidth, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HomePalette.inset)
            }
        }
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(HomePalette.isPad ? .title2.bold() : .title3.bold())
                .foregroundStyle(HomePalette.ink)
            Spacer()
            if let count { Text(String(count)).font(.subheadline).foregroundStyle(HomePalette.muted) }
            Image(systemName: "chevron.right").font(.caption.bold())
                .foregroundStyle(HomePalette.muted)
        }
        .padding(.horizontal, HomePalette.inset)
    }

    private func progress(_ item: JellyfinItem) -> Double {
        guard let total = item.runTimeTicks, total > 0 else { return 0 }
        return min(1, max(0, Double(item.userData?.playbackPositionTicks ?? 0) / Double(total)))
    }

    private func open(_ item: JellyfinItem) {
        guard let source else { return }
        if item.isFolder == true || item.type == "Series" {
            browserRoute = HomeBrowserRoute(source: source, parentID: item.id, title: item.name)
            return
        }
        selectedItem = library.openEmbyItem(sourceID: source.id, remote: item)
    }

    private func loadHome() async {
        guard let source else {
            views = []; latest = []; continuing = []; continuingTotal = 0; shelves = []
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                errorMessage = "Emby 登录已失效，请在片源页面更新令牌。"
                return
            }
            async let viewsRequest = EmbyClient.browse(source: source, token: token, parentID: nil)
            async let latestRequest = EmbyClient.latest(source: source, token: token)
            async let resumeRequest = EmbyClient.resume(source: source, token: token)
            let viewPage = try? await viewsRequest
            let recentMovies = try? await latestRequest
            let resumePage = try? await resumeRequest
            views = viewPage?.items ?? []
            latest = recentMovies ?? []
            continuing = resumePage?.items ?? []
            continuingTotal = resumePage?.totalCount ?? continuing.count
            if views.isEmpty && latest.isEmpty && continuing.isEmpty {
                errorMessage = "服务器暂时无法提供首页内容，请在片源中浏览目录。"
            }
            var loadedShelves: [HomeShelf] = []
            for view in views.prefix(3) {
                let types = view.name.contains("电影") ? "Movie" : "Series"
                if let page = try? await EmbyClient.featured(source: source, token: token,
                                                             parentID: view.id, itemTypes: types),
                   !page.items.isEmpty {
                    loadedShelves.append(HomeShelf(view: view, items: page.items))
                }
            }
            shelves = loadedShelves
        } catch {
            errorMessage = "无法读取推荐内容：\(error.localizedDescription)"
        }
    }
}

struct MobileSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var results: [JellyfinItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var browserRoute: HomeBrowserRoute?

    private var source: EmbySource? { library.embySources.first }

    var body: some View {
        NavigationStack {
            List {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.secondary)
                }
                if loading { ProgressView("正在搜索…") }
                if let source {
                    ForEach(results, id: \.id) { item in
                        Button {
                            if item.isFolder == true || item.type == "Series" {
                                browserRoute = HomeBrowserRoute(source: source, parentID: item.id,
                                                               title: item.name)
                            } else {
                                selectedItem = library.openEmbyItem(sourceID: source.id, remote: item)
                            }
                        } label: {
                            HStack(spacing: 12) {
                                EmbyArtwork(source: source, itemID: item.id,
                                            backdrop: false, width: 160)
                                    .frame(width: 54, height: 76)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.name).font(.body.weight(.semibold))
                                        .foregroundStyle(HomePalette.ink)
                                    if let year = item.productionYear {
                                        Text(String(year)).font(.caption)
                                            .foregroundStyle(HomePalette.muted)
                                    }
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption)
                                    .foregroundStyle(HomePalette.muted)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("请先连接 Emby", systemImage: "server.rack")
                }
                if !query.isEmpty && !loading && results.isEmpty && errorMessage == nil {
                    ContentUnavailableView.search(text: query)
                }
            }
            .navigationTitle("搜索")
            .searchable(text: $query, prompt: "搜索 Emby 影片和剧集")
            .task(id: query) { await search() }
            .sheet(item: $selectedItem) { item in
                MediaDetailView(itemID: item.id).environmentObject(library)
            }
            .sheet(item: $browserRoute) { route in
                EmbyBrowserView(source: route.source, parentID: route.parentID, title: route.title)
                    .environmentObject(library)
            }
        }
        .preferredColorScheme(.light)
    }

    private func search() async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, let source else { results = []; errorMessage = nil; return }
        do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
        guard !Task.isCancelled else { return }
        loading = true
        defer { loading = false }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                errorMessage = "Emby 登录已失效。"
                return
            }
            let page = try await EmbyClient.search(source: source, token: token, term: term)
            guard !Task.isCancelled else { return }
            results = page.items
            errorMessage = nil
        } catch {
            if !Task.isCancelled { errorMessage = "搜索失败：\(error.localizedDescription)" }
        }
    }
}
#endif
