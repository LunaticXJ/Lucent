#if os(tvOS)
import SwiftUI
import UIKit

private enum TVPalette {
    static let background = Color(red: 0.045, green: 0.055, blue: 0.078)
    static let secondary = Color(red: 0.73, green: 0.76, blue: 0.81)
    static let accent = Color(red: 0.87, green: 0.93, blue: 1.0)
    static let horizontalInset: CGFloat = 88
}

@MainActor
private enum TVArtworkCache {
    static var images: [String: UIImage] = [:]
}

private struct TVArtwork: View {
    let source: EmbySource
    let itemID: String
    let backdrop: Bool
    let width: Int
    var topAligned = false
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.init(red: 0.13, green: 0.22, blue: 0.35),
                                    .init(red: 0.32, green: 0.30, blue: 0.36)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                GeometryReader { geometry in
                    Image(uiImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height,
                               alignment: topAligned ? .top : .center)
                        .clipped()
                }
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 60, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .clipped()
        .task(id: "\(source.id)|\(itemID)|\(backdrop)|\(width)") {
            let key = "\(source.id)|\(itemID)|\(backdrop)|\(width)"
            if let cached = TVArtworkCache.images[key] { image = cached; return }
            guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                  !token.isEmpty else { return }
            for useBackdrop in backdrop ? [true, false] : [false] {
                guard let data = try? await EmbyClient.artwork(source: source, token: token,
                                                               itemID: itemID, backdrop: useBackdrop,
                                                               maxWidth: width),
                      let loaded = UIImage(data: data) else { continue }
                TVArtworkCache.images[key] = loaded
                image = loaded
                break
            }
        }
    }
}

private struct TVHomeShelf: Identifiable {
    let view: JellyfinItem
    let items: [JellyfinItem]
    var id: String { view.id }
}

private struct TVBrowserRoute: Identifiable {
    let source: EmbySource
    let parentID: String?
    let title: String?
    var id: String { "\(source.id)|\(parentID ?? "root")" }
}

struct TVHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    let showLibrary: () -> Void

    @State private var latest: [JellyfinItem] = []
    @State private var continuing: [JellyfinItem] = []
    @State private var continuingTotal = 0
    @State private var views: [JellyfinItem] = []
    @State private var shelves: [TVHomeShelf] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var browserRoute: TVBrowserRoute?

    private var source: EmbySource? { library.embySources.first }

    var body: some View {
        Group {
            if source == nil {
                emptyState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 48) {
                        hero
                        if let errorMessage {
                            Text(errorMessage).font(.system(size: 22))
                                .foregroundStyle(TVPalette.secondary)
                                .padding(.horizontal, TVPalette.horizontalInset)
                        }
                        if !continuing.isEmpty { continueSection }
                        if !views.isEmpty { sourceSection }
                        ForEach(shelves) { shelf in posterSection(shelf) }
                    }
                    .padding(.bottom, 90)
                }
            }
        }
        .background(TVPalette.background)
        .ignoresSafeArea(edges: .top)
        .task(id: source?.id) { await loadHome() }
        .sheet(item: $selectedItem) { item in
            MediaDetailView(itemID: item.id).environmentObject(library)
        }
        .sheet(item: $browserRoute) { route in
            EmbyBrowserView(source: route.source, parentID: route.parentID, title: route.title)
                .environmentObject(library)
        }
    }

    private var emptyState: some View {
        ZStack {
            RadialGradient(colors: [.init(red: 0.19, green: 0.29, blue: 0.42),
                                    TVPalette.background],
                           center: .init(x: 0.76, y: 0.44), startRadius: 80, endRadius: 900)
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 450, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.055))
                .offset(x: 470, y: 60)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("LUCENT")
                        .font(.system(size: 25, weight: .bold, design: .rounded))
                        .tracking(4)
                    Spacer()
                    Button("媒体库", systemImage: "square.stack.3d.up") { showLibrary() }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Text("你的大屏幕，从这里开始")
                    .font(.system(size: 68, weight: .bold))
                Text("连接媒体服务器或网络片源，电影和剧集即刻呈现。")
                    .font(.system(size: 27))
                    .foregroundStyle(TVPalette.secondary)
                    .padding(.top, 18)
                Button("添加片源", systemImage: "plus") { showLibrary() }
                    .buttonStyle(.borderedProminent)
                    .tint(TVPalette.accent)
                    .foregroundStyle(TVPalette.background)
                    .padding(.top, 36)
                Text("Emby  ·  Jellyfin  ·  Plex  ·  网络共享  ·  网盘")
                    .font(.system(size: 19))
                    .foregroundStyle(TVPalette.secondary.opacity(0.72))
                    .padding(.top, 30)
                Spacer()
            }
            .padding(.horizontal, TVPalette.horizontalInset)
            .padding(.top, 62)
            .padding(.bottom, 72)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if let source, let item = latest.first {
                TVArtwork(source: source, itemID: item.id, backdrop: true, width: 1920,
                          topAligned: true)
                    .frame(height: 620)
            } else {
                LinearGradient(colors: [.init(red: 0.13, green: 0.24, blue: 0.38),
                                        .init(red: 0.25, green: 0.24, blue: 0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 620)
            }
            LinearGradient(stops: [
                .init(color: TVPalette.background.opacity(0.92), location: 0),
                .init(color: TVPalette.background.opacity(0.74), location: 0.29),
                .init(color: TVPalette.background.opacity(0.20), location: 0.67),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.24), location: 0),
                .init(color: .clear, location: 0.35),
                .init(color: TVPalette.background.opacity(0.24), location: 0.62),
                .init(color: TVPalette.background, location: 1)
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 28) {
                    Text("LUCENT").font(.system(size: 25, weight: .bold, design: .rounded))
                        .tracking(4)
                    if let source {
                        Text(source.name).font(.system(size: 20, weight: .medium))
                            .foregroundStyle(TVPalette.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("媒体库", systemImage: "square.stack.3d.up") { showLibrary() }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                if let item = latest.first {
                    Text("新近入库").font(.system(size: 19, weight: .semibold))
                        .tracking(3).foregroundStyle(TVPalette.accent)
                    Text(item.name).font(.system(size: 68, weight: .bold))
                        .lineLimit(1).padding(.top, 10)
                    HStack(spacing: 16) {
                        if let rating = item.communityRating {
                            Label(rating.formatted(.number.precision(.fractionLength(1))),
                                  systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        if let year = item.productionYear { Text(String(year)) }
                        Text("电影")
                    }
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(TVPalette.secondary)
                    .padding(.top, 10)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).font(.system(size: 24))
                            .foregroundStyle(TVPalette.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: 760, alignment: .leading)
                            .padding(.top, 18)
                    }
                    Button("查看影片", systemImage: "play.fill") { open(item) }
                        .buttonStyle(.borderedProminent)
                        .tint(TVPalette.accent)
                        .foregroundStyle(TVPalette.background)
                        .padding(.top, 26)
                } else {
                    Text("让好故事，触手可及")
                        .font(.system(size: 58, weight: .bold))
                    Text(source == nil ? "连接 Emby，开始浏览你的影片。" :
                         loading ? "正在读取服务器推荐…" : "暂无推荐影片，可在媒体库中浏览。")
                        .font(.system(size: 25)).foregroundStyle(TVPalette.secondary)
                        .padding(.top, 12)
                    if loading { ProgressView().padding(.top, 22) }
                    Button("打开媒体库", systemImage: "square.stack.3d.up") { showLibrary() }
                        .buttonStyle(.borderedProminent).padding(.top, 24)
                }
            }
            .padding(.horizontal, TVPalette.horizontalInset)
            .padding(.top, 62)
            .padding(.bottom, 56)
        }
        .frame(height: 620)
        .clipped()
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("继续观看", count: continuingTotal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 26) {
                    if let source {
                        ForEach(continuing, id: \.id) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    ZStack(alignment: .bottom) {
                                        TVArtwork(source: source, itemID: item.id,
                                                  backdrop: true, width: 640)
                                        ProgressView(value: progress(item)).tint(.white)
                                            .padding(14)
                                    }
                                    .frame(width: 350, height: 196)
                                    .clipShape(RoundedRectangle(cornerRadius: 14))
                                    Text(item.name).font(.system(size: 27, weight: .semibold))
                                        .lineLimit(1)
                                    if let episode = item.identity.episodeLabel {
                                        Text(episode).font(.system(size: 20))
                                            .foregroundStyle(TVPalette.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 350, alignment: .leading)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, TVPalette.horizontalInset)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 22) {
            heading("我的媒体", count: views.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 26) {
                    if let source {
                        ForEach(views, id: \.id) { view in
                            Button {
                                browserRoute = TVBrowserRoute(source: source, parentID: view.id,
                                                             title: view.name)
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    if let first = shelves.first(where: { $0.id == view.id })?.items.first {
                                        TVArtwork(source: source, itemID: first.id,
                                                  backdrop: true, width: 640)
                                    } else {
                                        Color(red: 0.18, green: 0.28, blue: 0.36)
                                    }
                                    LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                                   startPoint: .center, endPoint: .bottom)
                                    Text(view.name).font(.system(size: 28, weight: .bold))
                                        .padding(20)
                                }
                                .frame(width: 350, height: 196)
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, TVPalette.horizontalInset)
            }
        }
    }

    private func posterSection(_ shelf: TVHomeShelf) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            heading(shelf.view.name, count: nil)
            if shelf.items.isEmpty, let source {
                Button("打开媒体库查看全部") {
                    browserRoute = TVBrowserRoute(source: source, parentID: shelf.view.id,
                                                 title: shelf.view.name)
                }
                .padding(.horizontal, TVPalette.horizontalInset)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 26) {
                    if let source {
                        ForEach(shelf.items, id: \.id) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 10) {
                                    TVArtwork(source: source, itemID: item.id,
                                              backdrop: false, width: 420)
                                        .frame(width: 202, height: 303)
                                        .clipShape(RoundedRectangle(cornerRadius: 14))
                                    Text(item.name).font(.system(size: 22, weight: .semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: 202, alignment: .leading)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, TVPalette.horizontalInset)
            }
        }
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title).font(.system(size: 36, weight: .bold))
            if let count {
                Text(String(count)).font(.system(size: 22))
                    .foregroundStyle(TVPalette.secondary)
            }
        }
        .padding(.horizontal, TVPalette.horizontalInset)
    }

    private func progress(_ item: JellyfinItem) -> Double {
        guard let total = item.runTimeTicks, total > 0 else { return 0 }
        return min(1, max(0, Double(item.userData?.playbackPositionTicks ?? 0) / Double(total)))
    }

    private func open(_ item: JellyfinItem) {
        guard let source else { return }
        if item.isFolder == true || item.type == "Series" {
            browserRoute = TVBrowserRoute(source: source, parentID: item.id, title: item.name)
        } else {
            selectedItem = library.openEmbyItem(sourceID: source.id, remote: item)
        }
    }

    private func loadHome() async {
        guard let source else {
            latest = []; continuing = []; continuingTotal = 0; views = []; shelves = []
            return
        }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id),
                  !token.isEmpty else {
                errorMessage = "Emby 登录已失效，请在媒体库更新令牌。"
                return
            }
            async let latestRequest = EmbyClient.latest(source: source, token: token)
            async let resumeRequest = EmbyClient.resume(source: source, token: token)
            async let viewsRequest = EmbyClient.browse(source: source, token: token, parentID: nil)
            latest = (try? await latestRequest) ?? []
            let resumePage = try? await resumeRequest
            continuing = resumePage?.items ?? []
            continuingTotal = resumePage?.totalCount ?? continuing.count
            views = (try? await viewsRequest.items) ?? []
            let fetched = await withTaskGroup(of: (String, [JellyfinItem]).self) { group in
                for view in views {
                    group.addTask {
                        let page = try? await EmbyClient.featured(
                            source: source, token: token, parentID: view.id,
                            itemTypes: EmbyClient.featuredItemTypes(for: view))
                        return (view.id, page?.items ?? [])
                    }
                }
                var results: [String: [JellyfinItem]] = [:]
                for await (id, items) in group { results[id] = items }
                return results
            }
            shelves = views.map { TVHomeShelf(view: $0, items: fetched[$0.id] ?? []) }
        } catch {
            errorMessage = "读取 Emby 首页失败：\(error.localizedDescription)"
        }
    }
}
#endif
