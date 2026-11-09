#if os(iOS)
import SwiftUI

private struct ServerPoster: View {
    let request: URLRequest?
    let cacheKey: String
    var body: some View {
        LucentRemoteArtwork(request: request, cacheKey: cacheKey)
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
    }
}

struct MobileServerCatalogView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.colorScheme) private var colorScheme
    let catalog: String
    let refreshID: UUID
    @Binding var detailPresented: Bool
    @State private var jellyfinItems: [JellyfinItem] = []
    @State private var plexItems: [PlexItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItemID: UUID?
    @Namespace private var detailTransition
    @State private var selectedTransitionKey: String?
    @State private var nextStart = 0
    @State private var hasMore = true

    private var sourceID: UUID? {
        catalog.split(separator: ":", maxSplits: 1).last.flatMap { UUID(uuidString: String($0)) }
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(catalog.hasPrefix("plex:") ? "Plex" : "Jellyfin")
                    .font(.largeTitle.bold())
                    .padding(.top, 68)
                if loading { LucentLoadingView(title: "正在读取服务器内容…") }
                if let errorMessage {
                    LucentStateView(title: "无法读取服务器内容", symbol: "wifi.exclamationmark", message: errorMessage, actionTitle: "重试") { Task { await load() } }
                }
                if !loading && errorMessage == nil && jellyfinItems.isEmpty && plexItems.isEmpty {
                    Text("服务器暂时没有可展示的影片。")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                    if let sourceID, let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                       let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID) {
                        ForEach(jellyfinItems, id: \.id) { item in
                            Button {
                                selectedTransitionKey = "jellyfin:\(item.id)"
                                selectedItemID = library.openJellyfinItem(sourceID: sourceID, remote: item).id
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ServerPoster(request: JellyfinClient.posterRequest(
                                        source: source, token: token, itemID: item.id), cacheKey: "jellyfin|\(sourceID)|\(item.id)")
                                        .modifier(HomeMatchedSource(key: "jellyfin:\(item.id)",
                                                                    namespace: detailTransition))
                                    LucentPosterCaption(title: item.name, subtitle: item.displayYearText)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let sourceID, let source = library.plexSources.first(where: { $0.id == sourceID }),
                       let token = try? KeychainPasswordStore.plexToken(for: sourceID) {
                        ForEach(plexItems, id: \.ratingKey) { item in
                            Button {
                                selectedTransitionKey = "plex:\(item.ratingKey)"
                                selectedItemID = library.openPlexItem(sourceID: sourceID, remote: item)?.id
                            } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ServerPoster(request: item.thumb.flatMap {
                                        PlexClient.posterRequest(source: source, token: token, thumb: $0)
                                    }, cacheKey: "plex|\(sourceID)|\(item.ratingKey)")
                                    .modifier(HomeMatchedSource(key: "plex:\(item.ratingKey)",
                                                                namespace: detailTransition))
                                    LucentPosterCaption(title: item.title, subtitle: item.year.map(String.init))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if hasMore && !loading && errorMessage == nil {
                    Button("加载更多影片") { Task { await load(reset: false) } }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 50)
        }
        .background(colorScheme == .dark
                    ? Color(red: 0.055, green: 0.071, blue: 0.094)
                    : Color(uiColor: .systemGroupedBackground))
        .task(id: "\(catalog)|\(refreshID.uuidString)") { await load() }
        .refreshable { await load() }
        .navigationDestination(item: $selectedItemID) { id in
            Group {
                detailDestination(id)
            }.lucentSecondaryPage()
        }
        .onChange(of: selectedItemID) { _, value in detailPresented = value != nil }
    }

    @ViewBuilder private func detailDestination(_ id: UUID) -> some View {
        if #available(iOS 18.0, *), let selectedTransitionKey {
            MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
                .navigationTransition(.zoom(sourceID: selectedTransitionKey, in: detailTransition))
        } else {
            MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
        }
    }

    private func load(reset: Bool = true) async {
        guard let sourceID else { return }
        if reset {
            nextStart = 0
            hasMore = true
            jellyfinItems = []
            plexItems = []
        }
        guard hasMore, !loading else { return }
        loading = true
        errorMessage = nil
        defer { loading = false }
        do {
            if catalog.hasPrefix("jellyfin:"),
               let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
               let token = try KeychainPasswordStore.jellyfinToken(for: sourceID) {
                let page = try await JellyfinClient.browsePage(source: source, token: token,
                                                                start: nextStart)
                let known = Set(jellyfinItems.map(\.id))
                jellyfinItems += page.filter { !known.contains($0.id) }
                nextStart += 60
                hasMore = page.count == 60
                if reset { try await library.synchronizeServerHome(sourceID: sourceID, emby: false, displayedItems: jellyfinItems) }
            } else if let source = library.plexSources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.plexToken(for: sourceID) {
                let requestedAt = Date()
                let page = try await PlexClient.browsePage(source: source, token: token,
                                                           start: nextStart)
                let known = Set(plexItems.map(\.ratingKey))
                plexItems += page.filter { !known.contains($0.ratingKey) }
                nextStart += 40
                hasMore = !page.isEmpty
                library.synchronizePlexHome(sourceID: sourceID, displayedItems: page, requestedAt: requestedAt)
            } else {
                errorMessage = "无法读取服务器授权，请在片源页面更新登录凭据。"
            }
        } catch {
            errorMessage = "无法读取服务器内容：\(error.localizedDescription)"
        }
    }
}
#endif
