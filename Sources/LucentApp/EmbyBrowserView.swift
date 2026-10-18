import SwiftUI

struct EmbyBrowserView: View {
    @Environment(\.dismiss) private var dismiss
    let source: EmbySource
    var parentID: String? = nil
    var title: String? = nil

    var body: some View {
        NavigationStack {
            EmbyBrowserPageView(source: source, parentID: parentID, title: title ?? source.name)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("完成") { dismiss() }
                    }
                }
        }
    }
}

private struct EmbyBrowserPageView: View {
    @EnvironmentObject private var library: LibraryStore
    let source: EmbySource
    let parentID: String?
    let title: String

    @State private var entries: [JellyfinItem] = []
    @State private var totalCount = 0
    @State private var loaded = false
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItem: MediaItem?

    var body: some View {
        List {
            ForEach(entries, id: \.id) { entry in
                if entry.type == "Series" {
                    Button {
                        selectedItem = library.openEmbyItem(sourceID: source.id, remote: entry)
                    } label: {
                        Label(entry.name, systemImage: "tv")
                    }
                } else if entry.isFolder == true {
                    NavigationLink {
                        EmbyBrowserPageView(source: source, parentID: entry.id, title: entry.name)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                } else if entry.mediaType == "Video" ||
                            ["Movie", "Episode", "Video", "MusicVideo"].contains(entry.type) {
                    Button {
                        selectedItem = library.openEmbyItem(sourceID: source.id, remote: entry)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "play.rectangle")
                            VStack(alignment: .leading, spacing: 3) {
                                Text(entry.name).foregroundStyle(.primary)
                                if let overview = entry.overview, !overview.isEmpty {
                                    Text(overview).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                            }
                        }
                    }
                } else {
                    NavigationLink {
                        EmbyBrowserPageView(source: source, parentID: entry.id, title: entry.name)
                    } label: {
                        Label(entry.name, systemImage: "folder")
                    }
                }
            }
            if parentID != nil && loaded && entries.count < totalCount {
                Button("加载更多") { Task { await loadNextPage() } }
                    .disabled(loading)
            }
            if loading { ProgressView("正在读取目录…") }
            if let errorMessage {
                VStack(alignment: .leading, spacing: 8) {
                    Text(errorMessage).foregroundStyle(.secondary)
                    Button("重试") { Task { await reload() } }
                }
            }
            if loaded && entries.isEmpty && errorMessage == nil {
                ContentUnavailableView("目录为空", systemImage: "folder")
            }
        }
        .navigationTitle(title)
        .refreshable { await reload() }
        .task { await reload() }
        .sheet(item: $selectedItem) { item in
            MediaDetailView(itemID: item.id).environmentObject(library)
        }
    }

    private func reload() async {
        guard !loading else { return }
        entries = []
        totalCount = 0
        loaded = false
        errorMessage = nil
        await loadNextPage()
    }

    private func loadNextPage() async {
        guard !loading, !loaded || entries.count < totalCount else { return }
        loading = true
        defer { loading = false }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                errorMessage = "Emby 令牌已丢失，请重新连接服务器。"
                return
            }
            let page = try await EmbyClient.browse(source: source, token: token,
                                                   parentID: parentID, startIndex: entries.count)
            entries.append(contentsOf: page.items)
            totalCount = page.totalCount
            loaded = true
            errorMessage = nil
        } catch {
            errorMessage = "无法读取 Emby 目录：\(error.localizedDescription)"
        }
    }
}
