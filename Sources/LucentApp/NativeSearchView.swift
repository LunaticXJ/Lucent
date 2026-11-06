#if !os(iOS)
import SwiftUI

struct NativeSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var submitted = ""
    @State private var scope = 1
    @State private var results: [NativeShelf] = []
    @State private var busy = false
    @State private var errors: [String] = []
    @State private var searchTask: Task<Void, Never>?
    @State private var generation = UUID()
    @AppStorage("lucent.search.history") private var historyData = Data()
    @State private var recommendationBatch = 0
    @StateObject private var recommendationModel = NativeHomeModel()
    private var history: [String] { (try? JSONDecoder().decode([String].self, from: historyData)) ?? [] }
    private var visible: [NativeShelf] { results.filter { scope == 0 ? $0.id == "library" : $0.id != "library" } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack {
                    TextField("搜索电影或剧集", text: $query).submitLabel(.search).onSubmit(search)
                    Button("搜索", systemImage: "magnifyingglass", action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(18).background(LucentUI.panel, in: RoundedRectangle(cornerRadius: 18))
                if busy { LucentLoadingView(title: "正在搜索") }
                if !submitted.isEmpty {
                    Picker("搜索范围", selection: $scope) { Text("聚合媒体库").tag(0); Text("影视服务器").tag(1) }.pickerStyle(.segmented)
                    ForEach(visible) { shelf in
                        NavigationLink { NativeShelfGrid(shelf: shelf) } label: {
                            HStack { Text(shelf.title).font(.title2.bold()); Spacer(); Text("\(shelf.entries.count)"); Image(systemName: "chevron.right") }
                        }
                        NativeSearchShelf(entries: shelf.entries)
                    }
                }
                ForEach(errors, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                if !busy && visible.isEmpty {
                    if !submitted.isEmpty { Text("未找到匹配的电影或剧集").foregroundStyle(.secondary) }
                    if !history.isEmpty {
                        HStack { Text("历史搜索").font(.title2.bold()); Spacer(); Button("清空") { historyData = Data() } }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))]) {
                            ForEach(history, id: \.self) { value in Button(value) { query = value; search() }.buttonStyle(.bordered) }
                        }
                    }
                    HStack { Text("推荐观看").font(.title2.bold()); Spacer(); Button("换一批") { recommendationBatch += 1 } }
                    NativeSearchShelf(entries: recommendations)
                }
            }.padding(NativeLayout.pageInset)
        }.background(LucentUI.page).navigationTitle(submitted.isEmpty ? "搜索" : "搜索：\(submitted)")
            .task {
                if submitted.isEmpty {
                    scope = NativeCatalog.all(in: library).contains(where: { $0.id != "library" }) ? 1 : 0
                }
                guard recommendationModel.shelves.isEmpty, library.localCatalogCards.isEmpty,
                      let server = NativeCatalog.all(in: library).first(where: { $0.id != "library" }) else { return }
                await recommendationModel.load(catalog: server, library: library, rootOnly: true)
            }
            .onDisappear { searchTask?.cancel(); generation = UUID(); busy = false }
    }
    private var recommendations: [NativeMediaEntry] {
        let visible = Set(library.visibleItems.map(\.id))
        let values = library.localCatalogCards.filter { visible.contains($0.id) }.sorted { $0.addedAt > $1.addedAt }
        guard !values.isEmpty else {
            let remote = recommendationModel.shelves.filter { !$0.landscape }.flatMap(\.entries)
            guard !remote.isEmpty else { return [] }
            let start = (recommendationBatch * 10) % remote.count
            return (0..<min(10, remote.count)).map { remote[(start + $0) % remote.count] }
        }
        let catalog = NativeCatalog(id: "library", name: "聚合媒体库", asset: nil)
        let start = (recommendationBatch * 10) % values.count
        return (0..<min(10, values.count)).map { .init(catalog: catalog, remote: nil, plex: nil, local: values[(start + $0) % values.count]) }
    }
    private func search() {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        searchTask?.cancel(); let request = UUID(); generation = request
        submitted = term; busy = true; results = []; errors = []
        var terms = history.filter { $0 != term }; terms.insert(term, at: 0)
        historyData = (try? JSONEncoder().encode(Array(terms.prefix(20)))) ?? Data()
        searchTask = Task { @MainActor in
            defer { if generation == request { busy = false } }
            let catalogs = NativeCatalog.all(in: library)
            var groups: [NativeShelf] = []
            var jobs: [NativeSearchRequest] = []
            for catalog in catalogs {
                guard generation == request, !Task.isCancelled else { return }
                do {
                    if catalog.id == "library" {
                        let visible = Set(library.visibleItems.map(\.id))
                        let entries: [NativeMediaEntry] = library.localCatalogCards.filter {
                            visible.contains($0.id) && $0.catalogDisplayTitle.localizedStandardContains(term)
                        }.map { .init(catalog: catalog, remote: nil, plex: nil, local: $0) }
                        if !entries.isEmpty { groups.append(.init(id: catalog.id, title: catalog.name, entries: entries)) }
                    } else if let id = catalog.sourceID {
                        if let source = library.embySources.first(where: { $0.id == id }),
                           let token = try KeychainPasswordStore.embyToken(for: id) { jobs.append(.emby(catalog, source, token)) }
                        else if let source = library.jellyfinSources.first(where: { $0.id == id }),
                                let token = try KeychainPasswordStore.jellyfinToken(for: id) { jobs.append(.jellyfin(catalog, source, token)) }
                        else if let source = library.plexSources.first(where: { $0.id == id }),
                                let token = try KeychainPasswordStore.plexToken(for: id) { jobs.append(.plex(catalog, source, token)) }
                        else { throw URLError(.userAuthenticationRequired) }
                    }
                } catch { errors.append("\(catalog.name)：\(error.localizedDescription)") }
            }
            results = groups
            let order = Dictionary(uniqueKeysWithValues: catalogs.enumerated().map { ($0.element.id, $0.offset) })
            await withTaskGroup(of: NativeSearchRequest.Outcome.self) { group in
                for job in jobs { group.addTask { await job.run(term) } }
                for await outcome in group {
                    guard generation == request, !Task.isCancelled else { group.cancelAll(); return }
                    if let message = outcome.error { errors.append(message) }
                    if let shelf = outcome.shelf { groups.append(shelf) }
                    results = groups.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
                }
            }
        }
    }
}

private enum NativeSearchRequest: Sendable {
    case emby(NativeCatalog, EmbySource, String)
    case jellyfin(NativeCatalog, JellyfinSource, String)
    case plex(NativeCatalog, PlexSource, String)
    struct Outcome: Sendable { let shelf: NativeShelf?; let error: String? }
    var catalog: NativeCatalog {
        switch self { case .emby(let value, _, _), .jellyfin(let value, _, _), .plex(let value, _, _): value }
    }
    func run(_ term: String) async -> Outcome {
        let gate = ArtworkWorkGate.shelves
        do { try await gate.acquire() } catch { return .init(shelf: nil, error: nil) }
        do {
            try Task.checkCancellation()
            let entries: [NativeMediaEntry]
            switch self {
            case .emby(let catalog, let source, let token):
                entries = try await EmbyClient.search(source: source, token: token, term: term).items
                    .filter { $0.type == "Movie" || $0.type == "Series" }
                    .map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }
            case .jellyfin(let catalog, let source, let token):
                entries = try await JellyfinClient.search(source: source, token: token, term: term)
                    .filter { $0.type == "Movie" || $0.type == "Series" }
                    .map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }
            case .plex(let catalog, let source, let token):
                entries = try await PlexClient.search(source: source, token: token, term: term)
                    .map { .init(catalog: catalog, remote: nil, plex: $0, local: nil) }
            }
            await gate.release()
            guard !Task.isCancelled else { return .init(shelf: nil, error: nil) }
            return .init(shelf: entries.isEmpty ? nil : .init(id: catalog.id, title: catalog.name, entries: entries), error: nil)
        } catch {
            await gate.release()
            return .init(shelf: nil, error: Task.isCancelled ? nil : "\(catalog.name)：\(error.localizedDescription)")
        }
    }
}

private struct NativeSearchShelf: View {
    @EnvironmentObject private var library: LibraryStore
    let entries: [NativeMediaEntry]
    @State private var selected: NativeEntryRoute?
    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: 22) {
                ForEach(entries) { entry in
                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry).frame(width: NativeLayout.posterWidth) }.lucentContentButtonStyle()
                }
            }.padding(20)
        }.focusSection().navigationDestination(item: $selected) { NativeEntryPage(route: $0).environmentObject(library) }
    }
}
#endif
