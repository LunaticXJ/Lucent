import SwiftUI

#if os(iOS)
struct MobileFolderBrowserView: View {
    @EnvironmentObject private var library: LibraryStore
    let sourceID: UUID
    var relativePath = ""
    @State private var entries: [FolderScanner.Entry] = []
    @State private var loading = false
    @State private var message: String?
    @State private var playingItem: MediaItem?
    @State private var search = ""
    @State private var ascending = true
    @Environment(\.dismiss) private var dismiss

    private var visibleEntries: [FolderScanner.Entry] {
        entries.filter { search.isEmpty || $0.name.localizedStandardContains(search) }.sorted {
            if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
            return $0.name.localizedStandardCompare($1.name) == (ascending ? .orderedAscending : .orderedDescending)
        }
    }

    private var source: FolderSource? { library.folders.first { $0.id == sourceID } }

    var body: some View {
        List {
            if loading { ProgressView("正在读取文件夹…") }
            if let message { ContentUnavailableView("无法打开文件夹", systemImage: "folder.badge.questionmark", description: Text(message)) }
            if !loading && message == nil && entries.isEmpty {
                ContentUnavailableView("没有可播放的文件", systemImage: "folder")
            }
            ForEach(visibleEntries) { entry in
                if entry.isDirectory {
                    NavigationLink {
                        MobileFolderBrowserView(sourceID: sourceID, relativePath: entry.relativePath)
                            .environmentObject(library)
                    } label: {
                        Label(entry.name, systemImage: "folder.fill")
                    }
                } else {
                    Button {
                        guard let item = library.browsedFileItem(sourceID: sourceID, path: entry.relativePath) else { return }
                        playingItem = item
                        LucentOrientationDelegate.setPlaybackPresented(true)
                    } label: {
                        Label(entry.name, systemImage: "play.rectangle")
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(relativePath.isEmpty ? (source?.name ?? "文件夹") : (relativePath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "搜索当前目录")
        .tint(.gray)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Menu {
                    Button("刷新目录", systemImage: "arrow.clockwise") { Task { await loadDirectory() } }
                        .disabled(loading)
                    Toggle("名称升序", isOn: $ascending)
                } label: { Image(systemName: "ellipsis") }
                .accessibilityLabel("目录选项")
            }
            if relativePath.isEmpty {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
            }
        }
        .task(id: relativePath) { await loadDirectory() }
        .refreshable { await loadDirectory() }
        .fullScreenCover(item: $playingItem, onDismiss: {
            LucentOrientationDelegate.setPlaybackPresented(false)
        }) { item in
            PlaybackView(item: item).environmentObject(library)
        }
    }
    @MainActor private func loadDirectory() async {
        guard !loading else { return }
        guard let bookmark = source?.bookmark else { message = "文件夹已移除。"; return }
        loading = true; message = nil
        defer { loading = false }
        let path = relativePath
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.contents(bookmark: bookmark, relativePath: path)
            }.value
            try Task.checkCancellation()
            entries = result
        } catch {
            if !Task.isCancelled { message = error.localizedDescription }
        }
    }

}
#endif
