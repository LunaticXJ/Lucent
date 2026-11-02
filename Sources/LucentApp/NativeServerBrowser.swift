#if !os(iOS)
import SwiftUI

enum NativeEntryRoute: Hashable {
    case detail(UUID)
    case container(NativeCatalog, String, String)
}
extension NativeMediaEntry {
    @MainActor func destination(in library: LibraryStore) -> NativeEntryRoute? {
        if let plex, plex.type == "show" || plex.type == "season" {
            return .container(catalog, plex.ratingKey, plex.title)
        }
        if let remote, remote.isFolder == true, remote.type != "Series", remote.type != "Episode" {
            return .container(catalog, remote.id, remote.name)
        }
        return open(in: library).map { .detail($0.id) }
    }
}
struct NativeEntryPage: View {
    let route: NativeEntryRoute
    var body: some View {
        switch route {
        case .detail(let id): MediaDetailView(itemID: id)
        case .container(let catalog, let parent, let title): NativeServerBrowser(catalog: catalog, parentID: parent, title: title)
        }
    }
}

struct NativeServerBrowser: View {
    @EnvironmentObject private var library: LibraryStore
    let catalog: NativeCatalog
    var parentID: String?
    let title: String
    @State private var entries: [NativeMediaEntry] = []
    @State private var next = 0
    @State private var more = true
    @State private var busy = false
    @State private var error: String?
    @State private var selected: NativeEntryRoute?
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 180, maximum: 280), spacing: 24)], alignment: .leading, spacing: 28) {
                ForEach(entries) { entry in
                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry) }
                        .lucentContentButtonStyle()
                }
            }.padding(32)
            if busy { LucentLoadingView(title: "正在读取内容").padding(30) }
            if let error { LucentStateView(title: "读取失败", message: error, actionTitle: "重试") { Task { await load() } } }
            if !busy && error == nil && entries.isEmpty { LucentStateView(title: "暂无影片", symbol: "film") }
            if more && !busy && error == nil { Button("加载更多") { Task { await load() } }.buttonStyle(.bordered).padding(24) }
        }.background(LucentUI.page).navigationTitle(title)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button("刷新", systemImage: "arrow.clockwise") { Task { await load(reset: true) } }.disabled(busy) } }
            .task { await load(reset: true) }
            .navigationDestination(item: $selected) { NativeEntryPage(route: $0).environmentObject(library) }
    }
    private func load(reset: Bool = false) async {
        guard !busy, let id = catalog.sourceID else { return }
        if reset { next = 0; entries = []; more = true }
        guard more else { return }
        busy = true; error = nil
        defer { busy = false }
        do {
            let page: [NativeMediaEntry]
            if let source = library.embySources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.embyToken(for: id) {
                let response = try await EmbyClient.browse(source: source, token: token, parentID: parentID, startIndex: next, limit: 60)
                page = response.items.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }
                more = next + response.items.count < response.totalCount
            } else if let source = library.jellyfinSources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.jellyfinToken(for: id) {
                let response = try await JellyfinClient.browsePage(source: source, token: token, start: next)
                page = response.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }
                more = response.count == 60
            } else if let source = library.plexSources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.plexToken(for: id) {
                let response = try await PlexClient.catalogPage(source: source, token: token, parentKey: parentID, start: next)
                page = response.map { .init(catalog: catalog, remote: nil, plex: $0, local: nil) }
                more = response.count >= 60
            } else { throw URLError(.userAuthenticationRequired) }
            try Task.checkCancellation()
            let known = Set(entries.map(\.id))
            let additions = page.filter { !known.contains($0.id) }
            entries += additions; next += 60
            if additions.isEmpty { more = false }
        } catch is CancellationError { return }
        catch { self.error = error.localizedDescription }
    }
}
#endif
