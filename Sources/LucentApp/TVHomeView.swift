#if os(tvOS)
import SwiftUI
import UIKit

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
    @State private var views: [JellyfinItem] = []
    @State private var shelves: [TVHomeShelf] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?
    @State private var browserRoute: TVBrowserRoute?

    private var source: EmbySource? { library.embySources.first }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 42) {
                hero
                if let errorMessage {
                    Text(errorMessage).font(.title3).foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 72)
                }
                if !continuing.isEmpty { continueSection }
                if !views.isEmpty { sourceSection }
                ForEach(shelves) { shelf in posterSection(shelf) }
            }
            .padding(.bottom, 90)
        }
        .background(Color(red: 0.055, green: 0.073, blue: 0.10))
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

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            if let source, let item = latest.first {
                TVArtwork(source: source, itemID: item.id, backdrop: true, width: 1920,
                          topAligned: true)
                    .frame(height: 630)
            } else {
                LinearGradient(colors: [.init(red: 0.13, green: 0.24, blue: 0.38),
                                        .init(red: 0.25, green: 0.24, blue: 0.28)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                    .frame(height: 630)
            }
            LinearGradient(stops: [
                .init(color: .black.opacity(0.65), location: 0),
                .init(color: .clear, location: 0.28),
                .init(color: .black.opacity(0.18), location: 0.48),
                .init(color: Color(red: 0.055, green: 0.073, blue: 0.10), location: 1)
            ], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 26) {
                    Text("LUCENT").font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(5)
                    if let source {
                        Text(source.name).font(.title3.weight(.medium))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    Spacer()
                    Button("媒体库", systemImage: "square.stack.3d.up") { showLibrary() }
                        .buttonStyle(.bordered)
                }
                Spacer(minLength: 0)
                if let item = latest.first {
                    Text("为你推荐").font(.title3.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.8))
                    Text(item.name).font(.system(size: 64, weight: .bold))
                        .lineLimit(1).padding(.top, 12)
                    HStack(spacing: 18) {
                        if let rating = item.communityRating {
                            Label(rating.formatted(.number.precision(.fractionLength(1))),
                                  systemImage: "star.fill")
                                .foregroundStyle(.yellow)
                        }
                        if let year = item.productionYear { Text(String(year)) }
                        Text("电影")
                    }
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.top, 12)
                    if let overview = item.overview, !overview.isEmpty {
                        Text(overview).font(.title3)
                            .foregroundStyle(.white.opacity(0.75))
                            .lineLimit(2)
                            .frame(maxWidth: 900, alignment: .leading)
                            .padding(.top, 16)
                    }
                    Button("查看影片", systemImage: "play.fill") { open(item) }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 24)
                } else {
                    Text("让好故事，触手可及")
                        .font(.system(size: 58, weight: .bold))
                    Text(source == nil ? "连接 Emby，开始浏览你的影片。" : "正在读取服务器推荐…")
                        .font(.title2).foregroundStyle(.white.opacity(0.75))
                        .padding(.top, 12)
                    Button("打开媒体库", systemImage: "square.stack.3d.up") { showLibrary() }
                        .buttonStyle(.borderedProminent).padding(.top, 24)
                }
            }
            .padding(.horizontal, 72)
            .padding(.top, 58)
            .padding(.bottom, 48)
        }
        .frame(height: 630)
        .clipped()
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("继续观看", count: continuing.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    if let source {
                        ForEach(continuing, id: \.id) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    ZStack(alignment: .bottom) {
                                        TVArtwork(source: source, itemID: item.id,
                                                  backdrop: true, width: 640)
                                        ProgressView(value: progress(item)).tint(.white)
                                            .padding(14)
                                    }
                                    .frame(width: 320, height: 180)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(item.name).font(.title3.weight(.semibold))
                                        .lineLimit(1)
                                    if let episode = item.identity.episodeLabel {
                                        Text(episode).font(.body)
                                            .foregroundStyle(.white.opacity(0.58))
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: 320, alignment: .leading)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, 72)
            }
        }
    }

    private var sourceSection: some View {
        VStack(alignment: .leading, spacing: 20) {
            heading("我的媒体", count: views.count)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 28) {
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
                                    Text(view.name).font(.title2.bold()).padding(20)
                                }
                                .frame(width: 320, height: 180)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, 72)
            }
        }
    }

    private func posterSection(_ shelf: TVHomeShelf) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            heading(shelf.view.name, count: nil)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 28) {
                    if let source {
                        ForEach(shelf.items, id: \.id) { item in
                            Button { open(item) } label: {
                                VStack(alignment: .leading, spacing: 12) {
                                    TVArtwork(source: source, itemID: item.id,
                                              backdrop: false, width: 420)
                                        .frame(width: 210, height: 315)
                                        .clipShape(RoundedRectangle(cornerRadius: 16))
                                    Text(item.name).font(.title3.weight(.semibold))
                                        .lineLimit(1)
                                }
                                .frame(width: 210, alignment: .leading)
                            }
                            .buttonStyle(.card)
                        }
                    }
                }
                .padding(.horizontal, 72)
            }
        }
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(spacing: 14) {
            Text(title).font(.title.bold())
            if let count {
                Text(String(count)).font(.title3).foregroundStyle(.white.opacity(0.55))
            }
        }
        .padding(.horizontal, 72)
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
        guard let source else { return }
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
            continuing = (try? await resumeRequest.items) ?? []
            views = (try? await viewsRequest.items) ?? []
            var loaded: [TVHomeShelf] = []
            for view in views.prefix(3) {
                let types = view.name.contains("电影") ? "Movie" : "Series"
                if let page = try? await EmbyClient.featured(source: source, token: token,
                                                             parentID: view.id, itemTypes: types),
                   !page.items.isEmpty {
                    loaded.append(TVHomeShelf(view: view, items: page.items))
                }
            }
            shelves = loaded
        } catch {
            errorMessage = "读取 Emby 首页失败：\(error.localizedDescription)"
        }
    }
}
#endif
