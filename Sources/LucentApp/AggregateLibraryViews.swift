#if os(iOS)
import SwiftUI

private struct LibraryGlass: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26, *) { content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 22)) }
        else { content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)) }
    }
}

struct AggregateLibraryOverview: View {
    @EnvironmentObject private var library: LibraryStore
    let manageStorage: () -> Void
    let importSource: () -> Void
    @State private var browsing: LibraryFileSource?
    @State private var renaming: LibraryFileSource?
    @State private var name = ""
    @State private var removing: LibraryFileSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            dashboard
            Button(action: manageStorage) {
                HStack(spacing: 14) {
                    Image(systemName: "externaldrive.connected.to.line.below").font(.title2)
                    Text("存储").font(.headline)
                    Spacer()
                    Text(library.libraryStorages.count.formatted())
                        .font(.subheadline).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                }.padding(18).contentShape(Rectangle())
            }.buttonStyle(.plain).modifier(LibraryGlass())
            HStack {
                Text("文件源").font(.title3.bold())
                Spacer()
                Button(action: importSource) { Label("导入目录", systemImage: "folder.badge.plus").font(.subheadline) }
            }
            if library.fileSources.isEmpty {
                ContentUnavailableView {
                    Label("从目录建立媒体库", systemImage: "folder.badge.plus")
                } description: {
                    Text(library.libraryStorages.isEmpty ? "先连接存储，再选择要加入的目录。" : "从存储中选择目录，扫描后即可在首页浏览。")
                } actions: {
                    Button(library.libraryStorages.isEmpty ? "添加存储" : "选择目录", action: manageStorage).buttonStyle(.bordered)
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(library.fileSources) { source in
                        sourceRow(source)
                        if source.id != library.fileSources.last?.id {
                            Divider().padding(.leading, 68)
                        }
                    }
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 22))
                .clipShape(RoundedRectangle(cornerRadius: 22))
            }
        }
        .sheet(item: $browsing) { source in
            NavigationStack {
                StorageDirectoryBrowser(storageID: source.storageID,
                    root: .init(identifier: source.directoryID, name: source.name, path: source.path, isDirectory: true))
            }.environmentObject(library)
        }
        .alert("重命名文件源", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $name)
            Button("保存") { if let source = renaming { library.renameFileSource(id: source.id, name: name) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("移除文件源？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("从聚合媒体库移除", role: .destructive) { if let source = removing { library.removeFileScope(source.id) }; removing = nil }
        } message: { Text("保留存储连接、原始文件、观看记录和已下载内容。") }
    }

    private var dashboard: some View {
        let items = library.localLibraryItems.filter { $0.missingSince == nil }
        let matched = library.localCatalogCards
        let series = matched.filter { $0.identity?.seriesName != nil }.count
        let movies = matched.filter { $0.identity?.seriesName == nil }.count
        let scanning = library.fileSources.filter { library.isScanningFileSource($0.id) }.count
        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                metric("电影", movies); metric("剧集", series); metric("视频文件", items.count)
            }
            Divider()
            HStack(spacing: 7) {
                Spacer(minLength: 0)
                if scanning > 0 { ProgressView().controlSize(.mini) }
                Text(scanning > 0 ? "\(scanning) 个文件源扫描中" :
                    (library.fileSources.compactMap(\.lastScannedAt).max().map { "更新于 " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "等待导入并扫描目录"))

            }.font(.caption2).foregroundStyle(.secondary)
        }.padding(18).modifier(LibraryGlass())
    }
    private func metric(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .center, spacing: 5) {
            Text(value.formatted()).font(.title2.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity, alignment: .center)
    }
    private func sourceRow(_ source: LibraryFileSource) -> some View {
        let storage = library.libraryStorages.first { $0.id == source.storageID }
        return HStack(spacing: 12) {
            Button { browsing = source } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.title2).frame(width: 40)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(source.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                        Text("\(storage?.name ?? "存储已移除") / \(source.path.isEmpty ? "根目录" : source.path)")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Text(status(source)).font(.caption2).foregroundStyle(source.needsConfirmation ? Color.orange : Color.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Toggle("启用\(source.name)", isOn: Binding(get: { library.isFileSourceIncluded(source.id) },
                set: { library.setFileSourceIncluded($0, id: source.id) })).labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 16)
        .contentShape(Rectangle())
        .contextMenu {
            Button("浏览目录", systemImage: "folder") { browsing = source }
            Button("重新扫描", systemImage: "arrow.clockwise") { library.scanFileScope(source.id) }.disabled(!source.enabled || source.needsConfirmation)
            if library.isScanningFileSource(source.id) { Button("停止扫描", systemImage: "stop") { library.stopFileScopeScan(source.id) } }
            Button("重命名", systemImage: "pencil") { name = source.name; renaming = source }
            Button("移除文件源", systemImage: "trash", role: .destructive) { removing = source }
        }
    }
    private func status(_ source: LibraryFileSource) -> String {
        if source.needsConfirmation { return "旧配置待确认" }
        if !source.enabled { return "已停用" }
        if library.isScanningFileSource(source.id), let state = library.scopeScanStates[source.id] { return state }
        if let state = library.scopeScanStates[source.id], state.hasPrefix("失败") || state == "已停止" { return state }
        let contents = library.localLibraryItems.filter { source.itemIDs.contains($0.id) && $0.missingSince == nil }
        if source.lastScannedAt != nil {
            return "\(contents.count) 个视频 · 已匹配 \(contents.filter { $0.metadata != nil }.count)"
        }
        if let state = library.scopeScanStates[source.id] { return state }
        return "\(library.fileSourceItemCount(source.id)) 个视频 · " + (source.lastScannedAt == nil ? "尚未扫描" : "已入库")
    }
}

struct StorageManagementView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let add: () -> Void
    let edit: (UUID) -> Void
    @State private var browsing: LibraryStorage?
    @State private var renaming: LibraryStorage?
    @State private var removing: LibraryStorage?
    @State private var name = ""
    var body: some View {
        List {
            group("本地", kinds: [.local])
            group("网络共享", kinds: [.smb, .webDAV])
            group("网盘", kinds: [.cloud])
            group("局域网媒体", kinds: [.dlna])
            if library.libraryStorages.isEmpty {
                ContentUnavailableView("尚未添加存储", systemImage: "externaldrive.badge.plus", description: Text("添加本地文件夹、网络共享或网盘后选择目录。"))
            }
        }
        .navigationTitle("存储").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button(action: add) { Image(systemName: "plus") }.accessibilityLabel("添加存储") }
        }
        .sheet(item: $browsing) { storage in
            NavigationStack { StorageDirectoryBrowser(storageID: storage.id, root: .root) }.environmentObject(library)
        }
        .alert("重命名存储", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("名称", text: $name)
            Button("保存") { if let storage = renaming { library.renameLibraryStorage(storage.id, name: name) }; renaming = nil }
            Button("取消", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("移除存储？", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("移除连接及其文件源", role: .destructive) { if let storage = removing { library.removeLibraryStorage(storage.id) }; removing = nil }
        } message: {
            Text("同时移除 \(library.fileSources.filter { $0.storageID == removing?.id }.count) 个文件源。原始文件、观看记录与下载保留。")
        }
    }
    @ViewBuilder private func group(_ title: String, kinds: Set<LibraryStorage.Kind>) -> some View {
        let storages = library.libraryStorages.filter { kinds.contains($0.kind) }
        if !storages.isEmpty {
            Section(title) {
                ForEach(storages) { storage in
                    Button { browsing = storage } label: {
                        HStack(spacing: 14) {
                            Image(systemName: storage.icon).font(.title2).frame(width: 34)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(storage.name).font(.headline).foregroundStyle(.primary)
                                Text(storage.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text("\(library.fileSources.filter { $0.storageID == storage.id }.count) 个文件源 · \(library.storageConnectionStates[storage.id] ?? "未检查")").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                        }.padding(.vertical, 7).contentShape(Rectangle())
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("浏览与导入", systemImage: "folder") { browsing = storage }
                        Button("重命名", systemImage: "pencil") { renaming = storage; name = storage.name }
                        if storage.kind != .dlna { Button("编辑连接", systemImage: "slider.horizontal.3") { edit(storage.id) } }
                        Button("移除存储", systemImage: "trash", role: .destructive) { removing = storage }
                    }
                }
            }
        }
    }
}

struct StorageDirectoryBrowser: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let storageID: UUID
    let root: StorageDirectory
    @State private var trail: [StorageDirectory] = []
    @State private var entries: [StorageDirectory] = []
    @State private var selected: [StorageDirectory] = []
    @State private var selectionMode = false
    @State private var loading = false
    @State private var message: String?
    @State private var showingReview = false
    @State private var playing: MediaItem?
    private var current: StorageDirectory { trail.last ?? root }
    var body: some View {
        VStack(spacing: 0) {
            breadcrumbs
            if loading { ProgressView("正在读取目录").frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if let message {
                ContentUnavailableView {
                    Label("无法读取目录", systemImage: "wifi.exclamationmark")
                } description: { Text(message) } actions: { Button("重试") { Task { await load() } } }
            } else {
                List {
                    if selectionMode {
                        Section { directoryRow(current, currentRow: true) }
                    }
                    if entries.isEmpty { Text("此目录为空，或没有可播放的视频").foregroundStyle(.secondary) }
                    ForEach(entries) { entry in
                        if entry.isDirectory { directoryRow(entry) }
                        else {
                            Button { play(entry) } label: {
                                Label(entry.name, systemImage: "play.rectangle").foregroundStyle(.primary).lineLimit(2)
                            }.disabled(selectionMode)
                        }
                    }
                }.listStyle(.insetGrouped)
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle(trail.isEmpty ? (root.path.isEmpty ? (library.libraryStorages.first { $0.id == storageID }?.name ?? "存储") : root.name) : current.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            ToolbarItem(placement: .primaryAction) { Button(selectionMode ? "取消选择" : "选择目录") { selectionMode.toggle(); if !selectionMode { selected = [] } } }
        }
        .safeAreaInset(edge: .bottom) {
            if selectionMode {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("已选 \(selected.count) 个目录").font(.subheadline.bold())
                        Text("每个目录将建立一个文件源").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("下一步") { showingReview = true }.buttonStyle(.borderedProminent).tint(.gray).disabled(selected.isEmpty)
                }.padding(16).modifier(LibraryGlass()).padding(12)
            }
        }
        .task(id: current.identifier) { await load() }
        .sheet(isPresented: $showingReview) {
            NavigationStack {
                DirectoryImportReview(storageID: storageID, directories: selected) {
                    showingReview = false; selected = []; selectionMode = false
                }
            }.environmentObject(library)
        }
        .fullScreenCover(item: $playing, onDismiss: { LucentOrientationDelegate.setPlaybackPresented(false) }) { item in
            PlaybackView(item: item).environmentObject(library)
        }
    }
    private var breadcrumbs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button(root.path.isEmpty ? "根目录" : root.name) { trail = [] }
                ForEach(Array(trail.enumerated()), id: \.element.id) { index, directory in
                    Image(systemName: "chevron.right").font(.caption2)
                    Button(directory.name) { trail = Array(trail.prefix(index + 1)) }
                }
            }.font(.subheadline).foregroundStyle(.secondary).padding(16)
        }
    }
    private func directoryRow(_ entry: StorageDirectory, currentRow: Bool = false) -> some View {
        let existing = library.scopeOverlap(storageID: storageID, directory: entry)
        let covered = selected.contains { LibraryScopePath.contains($0.path, entry.path) }
        return HStack(spacing: 12) {
            if selectionMode {
                Button { toggle(entry) } label: {
                    Image(systemName: covered ? "checkmark.circle.fill" : "circle").font(.title3)
                        .foregroundStyle(existing == nil ? Color.primary : Color.secondary)
                        .frame(width: 30, height: 40)
                }.buttonStyle(.plain).disabled(existing != nil)
                    .accessibilityLabel("选择\(entry.name)")
            }
            Button {
                if currentRow { if selectionMode { toggle(entry) } }
                else { trail.append(entry) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "folder").font(.title3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(currentRow ? "选择当前目录" : entry.name).foregroundStyle(.primary)
                        if let existing { Text("已导入：\(existing.name)").font(.caption).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if !currentRow { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary) }
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
        }
    }
    private func toggle(_ entry: StorageDirectory) {
        guard library.scopeOverlap(storageID: storageID, directory: entry) == nil else { return }
        if selected.contains(where: { $0.identifier == entry.identifier }) { selected.removeAll { $0.identifier == entry.identifier }; return }
        if selected.contains(where: { LibraryScopePath.contains($0.path, entry.path) }) { return }
        selected.removeAll { LibraryScopePath.contains(entry.path, $0.path) }
        selected.append(entry)
    }
    @MainActor private func load() async {
        let requested = current
        loading = true; message = nil; entries = []
        do {
            let values = try await library.storageContents(storageID, directory: requested)
            guard !Task.isCancelled, current.identifier == requested.identifier else { return }
            entries = values
        } catch is CancellationError { return }
        catch {
            guard !Task.isCancelled, current.identifier == requested.identifier else { return }
            message = error.localizedDescription
        }
        loading = false
    }
    private func play(_ entry: StorageDirectory) {
        guard let item = library.scannedStorageItem(storageID: storageID, entry: entry) else { return }
        LucentOrientationDelegate.setPlaybackPresented(true); playing = item
    }
}

private struct DirectoryImportReview: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let storageID: UUID
    let directories: [StorageDirectory]
    let finished: () -> Void
    @State private var names: [String: String] = [:]
    @State private var scanImmediately = true
    @State private var message: String?
    var body: some View {
        Form {
            Section {
                Text("每个目录独立命名、扫描和管理。").foregroundStyle(.secondary)
            }
            ForEach(directories) { directory in
                Section(directory.path.isEmpty ? "根目录" : directory.path) {
                    TextField("文件源名称", text: Binding(get: { names[directory.identifier] ?? defaultName(directory) }, set: { names[directory.identifier] = $0 }))
                }
            }
            Section { Toggle("导入后立即扫描", isOn: $scanImmediately) } footer: { Text("扫描在后台任务中进行，你可以继续浏览。仅扫描选中的目录及其子目录。") }
            if let message { Section { Text(message).foregroundStyle(.red) } }
        }
        .navigationTitle("导入文件源").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("返回") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("导入 \(directories.count) 个") {
                    do {
                        try library.importDirectories(storageID: storageID, directories: directories.map { ($0, names[$0.identifier] ?? defaultName($0)) }, scanImmediately: scanImmediately)
                        finished()
                    } catch { message = error.localizedDescription }
                }.disabled(directories.contains { (names[$0.identifier] ?? defaultName($0)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            }
        }
    }
    private func defaultName(_ directory: StorageDirectory) -> String {
        directory.path.isEmpty ? (library.libraryStorages.first { $0.id == storageID }?.name ?? "全部目录") : directory.name
    }
}
#endif
