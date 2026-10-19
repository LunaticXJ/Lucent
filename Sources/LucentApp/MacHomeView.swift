#if os(macOS)
import SwiftUI
import AppKit

private enum MacPalette {
    static let background = Color(red: 0.055, green: 0.067, blue: 0.09)
    static let surface = Color(red: 0.105, green: 0.12, blue: 0.15)
    static let muted = Color(red: 0.70, green: 0.73, blue: 0.78)
    static let accent = Color(red: 0.86, green: 0.93, blue: 1.0)
}

@MainActor
private enum MacArtworkCache {
    static var images: [String: NSImage] = [:]
}

private struct MacArtwork: View {
    let source: EmbySource
    let itemID: String
    let backdrop: Bool
    let width: Int
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [.init(red: 0.17, green: 0.25, blue: 0.35),
                                    .init(red: 0.28, green: 0.28, blue: 0.34)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: backdrop ? "film.stack" : "film")
                    .font(.system(size: backdrop ? 44 : 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .clipped()
        .task(id: "\(source.id)|\(itemID)|\(backdrop)|\(width)") {
            let key = "\(source.id)|\(itemID)|\(backdrop)|\(width)"
            if let cached = MacArtworkCache.images[key] { image = cached; return }
            guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                  !token.isEmpty else { return }
            for useBackdrop in backdrop ? [true, false] : [false] {
                guard let data = try? await EmbyClient.artwork(source: source, token: token,
                                                               itemID: itemID, backdrop: useBackdrop,
                                                               maxWidth: width),
                      let loaded = NSImage(data: data) else { continue }
                MacArtworkCache.images[key] = loaded
                image = loaded
                break
            }
        }
    }
}

private struct MacShelf: Identifiable {
    let view: JellyfinItem
    let items: [JellyfinItem]
    var id: String { view.id }
}

private struct MacBrowserRoute: Identifiable {
    let source: EmbySource
    let parentID: String?
    let title: String?
    var id: String { "\(source.id)|\(parentID ?? "root")" }
}

private struct MacCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15)
                .stroke(.white.opacity(configuration.isPressed ? 0.38 : 0.08), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

struct MacHomeView: View {
    @EnvironmentObject private var library: LibraryStore
    let showLibrary: () -> Void

    @State private var latest: [JellyfinItem] = []
    @State private var continuing: [JellyfinItem] = []
    @State private var continuingTotal = 0
    @State private var views: [JellyfinItem] = []
    @State private var shelves: [MacShelf] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var browserRoute: MacBrowserRoute?

    private var source: EmbySource? { library.embySources.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 30) {
                header
                if let source {
                    hero(source: source)
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(MacPalette.muted)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(MacPalette.surface, in: RoundedRectangle(cornerRadius: 14))
                    }
                    if !continuing.isEmpty { continueSection(source: source) }
                    if !views.isEmpty { mediaSection(source: source) }
                    ForEach(shelves) { shelf in posterSection(shelf, source: source) }
                } else {
                    emptyState
                }
            }
            .frame(maxWidth: 1320, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 30)
            .padding(.bottom, 64)
            .frame(maxWidth: .infinity)
        }
        .background(MacPalette.background)
        .preferredColorScheme(.dark)
        .task(id: source?.id) { await loadHome() }
        .sheet(item: $selectedItem) { item in
            MediaDetailView(itemID: item.id).environmentObject(library)
        }
        .sheet(item: $browserRoute) { route in
            EmbyBrowserView(source: route.source, parentID: route.parentID, title: route.title)
                .environmentObject(library)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("发现").font(.system(size: 32, weight: .bold))
                Text(source?.name ?? "你的电影与剧集")
                    .font(.system(size: 14)).foregroundStyle(MacPalette.muted)
            }
            Spacer()
            Button("管理片源", systemImage: "externaldrive") { showLibrary() }
                .buttonStyle(.bordered)
        }
    }

    private func hero(source: EmbySource) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .bottomLeading) {
                if let item = latest.first {
                    MacArtwork(source: source, itemID: item.id, backdrop: true, width: 1400)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    LinearGradient(colors: [.init(red: 0.16, green: 0.26, blue: 0.39),
                                            MacPalette.background],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
                LinearGradient(stops: [
                    .init(color: MacPalette.background.opacity(0.96), location: 0),
                    .init(color: MacPalette.background.opacity(0.72), location: 0.34),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, MacPalette.background.opacity(0.78)],
                               startPoint: .center, endPoint: .bottom)
                VStack(alignment: .leading, spacing: 0) {
                    Spacer()
                    if let item = latest.first {
                        Text("新近入库").font(.system(size: 12, weight: .semibold))
                            .tracking(2).foregroundStyle(MacPalette.accent)
                        Text(item.name).font(.system(size: 40, weight: .bold))
                            .lineLimit(1).padding(.top, 9)
                        HStack(spacing: 12) {
                            if let rating = item.communityRating {
                                Label(rating.formatted(.number.precision(.fractionLength(1))),
                                      systemImage: "star.fill").foregroundStyle(.yellow)
                            }
                            if let year = item.productionYear { Text(String(year)) }
                            Text("电影")
                        }
                        .font(.system(size: 14)).foregroundStyle(MacPalette.muted)
                        .padding(.top, 8)
                        if let overview = item.overview, !overview.isEmpty {
                            Text(overview).font(.system(size: 15))
                                .foregroundStyle(MacPalette.muted)
                                .lineLimit(2).padding(.top, 13)
                        }
                        Button("查看影片", systemImage: "play.fill") { open(item) }
                            .buttonStyle(.borderedProminent)
                            .tint(MacPalette.accent)
                            .foregroundStyle(MacPalette.background)
                            .padding(.top, 20)
                    } else {
                        Text(loading ? "正在读取推荐…" : "暂无推荐影片")
                            .font(.system(size: 32, weight: .bold))
                        Button("浏览片源") { showLibrary() }
                            .buttonStyle(.borderedProminent).padding(.top, 20)
                    }
                }
                .frame(maxWidth: 480, alignment: .leading)
                .padding(32)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipShape(RoundedRectangle(cornerRadius: 22))
        }
        .frame(height: 360)
    }

    private var emptyState: some View {
        HStack(spacing: 36) {
            VStack(alignment: .leading, spacing: 16) {
                Text("你的媒体，随时开场")
                    .font(.system(size: 36, weight: .bold))
                Text("连接服务器、网络共享或本地文件，开始整理和播放。")
                    .font(.system(size: 16)).foregroundStyle(MacPalette.muted)
                Button("添加片源", systemImage: "plus") { showLibrary() }
                    .buttonStyle(.borderedProminent).padding(.top, 8)
            }
            Spacer(minLength: 0)
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 150, weight: .ultraLight))
                .foregroundStyle(MacPalette.accent.opacity(0.22))
        }
        .padding(48)
        .frame(maxWidth: .infinity, minHeight: 350, alignment: .leading)
        .background(LinearGradient(colors: [.init(red: 0.12, green: 0.20, blue: 0.29),
                                            MacPalette.surface],
                                   startPoint: .topLeading, endPoint: .bottomTrailing),
                    in: RoundedRectangle(cornerRadius: 22))
    }

    private func continueSection(source: EmbySource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("继续观看", count: continuingTotal)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(continuing, id: \.id) { item in
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                ZStack(alignment: .bottom) {
                                    MacArtwork(source: source, itemID: item.id,
                                               backdrop: true, width: 500)
                                    ProgressView(value: progress(item)).tint(.white)
                                        .padding(10)
                                }
                                .frame(width: 250, height: 140)
                                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 15,
                                                                  topTrailingRadius: 15))
                                Text(item.name).font(.system(size: 15, weight: .semibold))
                                    .lineLimit(1).padding(.horizontal, 12)
                                if let episode = item.identity.episodeLabel {
                                    Text(episode).font(.system(size: 12))
                                        .foregroundStyle(MacPalette.muted)
                                        .lineLimit(1).padding(.horizontal, 12)
                                }
                            }
                            .frame(width: 250, alignment: .leading)
                            .padding(.bottom, 12)
                        }
                        .buttonStyle(MacCardStyle())
                    }
                }
                .padding(2)
            }
        }
    }

    private func mediaSection(source: EmbySource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("我的媒体", count: views.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
                    ForEach(views, id: \.id) { view in
                        Button {
                            browserRoute = MacBrowserRoute(source: source, parentID: view.id,
                                                           title: view.name)
                        } label: {
                            ZStack(alignment: .bottomLeading) {
                                if let first = shelves.first(where: { $0.id == view.id })?.items.first {
                                    MacArtwork(source: source, itemID: first.id,
                                               backdrop: true, width: 500)
                                } else {
                                    MacPalette.surface
                                }
                                LinearGradient(colors: [.clear, .black.opacity(0.75)],
                                               startPoint: .center, endPoint: .bottom)
                                Text(view.name).font(.system(size: 20, weight: .bold))
                                    .padding(16)
                            }
                            .frame(width: 220, height: 130)
                            .clipShape(RoundedRectangle(cornerRadius: 15))
                        }
                        .buttonStyle(MacCardStyle())
                    }
                }
                .padding(2)
            }
        }
    }

    private func posterSection(_ shelf: MacShelf, source: EmbySource) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                browserRoute = MacBrowserRoute(source: source, parentID: shelf.view.id,
                                               title: shelf.view.name)
            } label: { heading(shelf.view.name, count: nil) }
                .buttonStyle(.plain)
            if shelf.items.isEmpty {
                Text("打开媒体库查看全部")
                    .font(.subheadline)
                    .foregroundStyle(MacPalette.muted)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.items, id: \.id) { item in
                        Button { open(item) } label: {
                            VStack(alignment: .leading, spacing: 8) {
                                MacArtwork(source: source, itemID: item.id,
                                           backdrop: false, width: 350)
                                    .frame(width: 145, height: 216)
                                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 15,
                                                                      topTrailingRadius: 15))
                                Text(item.name).font(.system(size: 13, weight: .medium))
                                    .lineLimit(1).padding(.horizontal, 10)
                            }
                            .frame(width: 145, alignment: .leading)
                            .padding(.bottom, 12)
                        }
                        .buttonStyle(MacCardStyle())
                    }
                }
                .padding(2)
            }
        }
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.system(size: 23, weight: .bold))
            if let count {
                Text(String(count)).font(.system(size: 13))
                    .foregroundStyle(MacPalette.muted)
            }
        }
    }

    private func progress(_ item: JellyfinItem) -> Double {
        guard let total = item.runTimeTicks, total > 0 else { return 0 }
        return min(1, max(0, Double(item.userData?.playbackPositionTicks ?? 0) / Double(total)))
    }

    private func open(_ item: JellyfinItem) {
        guard let source else { return }
        if item.isFolder == true || item.type == "Series" {
            browserRoute = MacBrowserRoute(source: source, parentID: item.id, title: item.name)
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
                errorMessage = "Emby 登录已失效，请在片源中更新令牌。"
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
            shelves = views.map { MacShelf(view: $0, items: fetched[$0.id] ?? []) }
        } catch {
            errorMessage = "读取首页失败：\(error.localizedDescription)"
        }
    }
}
#endif
