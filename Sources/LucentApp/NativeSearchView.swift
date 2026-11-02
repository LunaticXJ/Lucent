#if !os(iOS)
import SwiftUI

struct NativeSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @State private var query = ""
    @State private var submitted = ""
    @State private var scope = 0
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
                    TextField("搜索电影或剧集", text: $query).onSubmit(search)
                    Button("搜索", systemImage: "magnifyingglass", action: search).disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }.padding(18).background(LucentUI.panel, in: RoundedRectangle(cornerRadius: 18))
                if busy { LucentLoadingView(title: "正在搜索") }
                if !results.isEmpty {
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
            }.padding(32)
        }.background(LucentUI.page).navigationTitle(submitted.isEmpty ? "搜索" : "搜索：\(submitted)")
            .task {
                guard library.localCatalogCards.isEmpty,
                      let server = NativeCatalog.all(in: library).first(where: { $0.id != "library" }) else { return }
                await recommendationModel.load(catalog: server, library: library)
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
            var groups: [NativeShelf] = []
            for catalog in NativeCatalog.all(in: library) {
                guard generation == request, !Task.isCancelled else { return }
                do {
                    var entries: [NativeMediaEntry] = []
                    if catalog.id == "library" {
                        let visible = Set(library.visibleItems.map(\.id))
                        entries = library.localCatalogCards.filter { visible.contains($0.id) && $0.catalogDisplayTitle.localizedStandardContains(term) }.map { .init(catalog: catalog, remote: nil, plex: nil, local: $0) }
                    } else if let id = catalog.sourceID, let source = library.embySources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.embyToken(for: id) {
                        entries = try await EmbyClient.search(source: source, token: token, term: term).items.filter { $0.type == "Movie" || $0.type == "Series" }.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }
                    } else if let id = catalog.sourceID, let source = library.jellyfinSources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.jellyfinToken(for: id) {
                        entries = try await JellyfinClient.search(source: source, token: token, term: term).filter { $0.type == "Movie" || $0.type == "Series" }.map { .init(catalog: catalog, remote: $0, plex: nil, local: nil) }
                    } else if let id = catalog.sourceID, let source = library.plexSources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.plexToken(for: id) {
                        entries = try await PlexClient.search(source: source, token: token, term: term).map { .init(catalog: catalog, remote: nil, plex: $0, local: nil) }
                    }
                    if !entries.isEmpty { groups.append(.init(id: catalog.id, title: catalog.name, entries: entries)) }
                } catch {
                    guard generation == request else { return }
                    errors.append("\(catalog.name)：\(error.localizedDescription)")
                }
                guard generation == request, !Task.isCancelled else { return }
                results = groups
            }
            busy = false
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
                    Button { selected = entry.destination(in: library) } label: { NativeMediaCard(entry: entry).frame(width: 190) }.buttonStyle(.bordered)
                }
            }.padding(12)
        }.navigationDestination(item: $selected) { NativeEntryPage(route: $0).environmentObject(library) }
    }
}
#endif
