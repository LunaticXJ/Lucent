#if !os(iOS)
import SwiftUI

enum NativeServerKind: String, CaseIterable, Identifiable {
    case emby, jellyfin, plex, fnos, zspace, ugreen
    var id: String { rawValue }
    var embyKind: EmbyServerKind? { EmbyServerKind(rawValue: rawValue) }
    var title: String { embyKind?.title ?? (self == .plex ? "Plex" : "Jellyfin") }
    var asset: String { embyKind?.assetName ?? (self == .plex ? "PlexBrand" : "JellyfinBrand") }
    var port: String { switch self { case .emby, .jellyfin: "8096"; case .plex: "32400"; case .fnos: "8005"; case .zspace: "8021"; case .ugreen: "9443" } }
}

private struct NativeServerEdit: Identifiable {
    let id: UUID
    let kind: NativeServerKind
    var existing: UUID?
}

struct NativeSourcesView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("lucent.sources.selectedKind") private var kind = 1
    @State private var storageManager = false
    @State private var addingStorage = false
    @State private var editor: NativeServerEdit?
    @State private var selectedStorage: LibraryStorage?
    @State private var pendingStorage: LibraryStorage?
    @State private var pendingAdd = false
    @State private var removal: NativeCatalog?
    @State private var counts: [UUID: (movies: Int, series: Int)] = [:]
    @State private var countsRevision = UUID()
    let addCloud: () -> Void
    let addDLNA: () -> Void
    let addFolder: () -> Void
    let editCloud: (UUID) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if library.activeProfile?.isChild == true {
                LucentStateView(title: "当前资料不能管理片源", symbol: "lock", message: "请切换至成人资料。")
            } else {
            Picker("片源类型", selection: $kind) {
                Text("影视服务器").tag(1)
                Text("聚合媒体库").tag(0)
            }.pickerStyle(.segmented)
            if kind == 0 {
                AggregateLibraryOverview(manageStorage: { storageManager = true }, importSource: { storageManager = true })
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 480), spacing: 22)], spacing: 22) {
                    ForEach(NativeCatalog.all(in: library).filter { $0.id != "library" }) { server in
                        Button {
                            guard let id = server.sourceID else { return }
                            editor = .init(id: UUID(), kind: serverKind(server), existing: id)
                        } label: {
                            VStack(alignment: .leading, spacing: 16) {
                                HStack {
                                    Text(server.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
                                    Spacer()
                                    if let asset = server.asset { Image(asset).resizable().scaledToFit().frame(width: 44, height: 44) }
                                }
                                if let id = server.sourceID, let count = counts[id] {
                                    HStack(spacing: 18) {
                                        Label("\(count.movies)", systemImage: "film")
                                        Label("\(count.series)", systemImage: "tv")
                                    }.font(.subheadline).foregroundStyle(.secondary)
                                }
                                Text(address(server)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }.padding(22).frame(maxWidth: .infinity, minHeight: 130, alignment: .leading)
                        }.buttonStyle(.bordered)
                        .task(id: "\(server.id)|\(countsRevision)") { await loadCounts(server) }
                        .contextMenu {
                            Button("编辑", systemImage: "pencil") { if let id = server.sourceID { editor = .init(id: UUID(), kind: serverKind(server), existing: id) } }
                            Button("移除", systemImage: "trash", role: .destructive) { removal = server }
                        }
                    }
                }
                if NativeCatalog.all(in: library).count == 1 { LucentStateView(title: "尚未连接影视服务器", symbol: "server.rack") }
            }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    if kind == 1 {
                        Section("影视服务器") {
                            ForEach(NativeServerKind.allCases) { value in
                                Button { editor = .init(id: UUID(), kind: value) } label: { Label(value.title, image: value.asset) }
                            }
                        }
                    }
                    if kind == 0 && library.activeProfile?.isChild != true {
                        Section("聚合媒体库") {
                            Button("添加存储", systemImage: "externaldrive.badge.plus") { addingStorage = true }
                            Button("从存储导入目录", systemImage: "folder.badge.plus") { storageManager = true }
                        }
                    }
                } label: { Label("添加", systemImage: "plus") }
                .disabled(library.activeProfile?.isChild == true)
            }
        }
        .sheet(item: $editor, onDismiss: { countsRevision = UUID() }) { route in NativeServerEditor(kind: route.kind, existingID: route.existing).environmentObject(library) }
        .lucentHierarchicalPresentation(isPresented: $storageManager, onDismiss: {
            if let pendingStorage {
                self.pendingStorage = nil
                if pendingStorage.kind == .cloud { editCloud(pendingStorage.id) }
                else { selectedStorage = pendingStorage }
            }
            else if pendingAdd { pendingAdd = false; addingStorage = true }
        }) {
            Group {
                #if os(tvOS)
                storageManagerContent
                #else
                NavigationStack { storageManagerContent }
                #endif
            }.environmentObject(library).frame(idealWidth: 760, idealHeight: 650)
        }
        .sheet(isPresented: $addingStorage, onDismiss: {
            if let action = pendingAddStorageAction { pendingAddStorageAction = nil; dispatchStorage(action) }
        }) {
            NavigationStack {
                List {
                    #if os(macOS)
                    Button("本地文件夹", systemImage: "folder") { pendingAddStorageAction = .local; addingStorage = false }
                    #endif
                    Button("SMB", systemImage: "externaldrive") { pendingAddStorageAction = .smb; addingStorage = false }
                    Button("WebDAV", systemImage: "network") { pendingAddStorageAction = .webDAV; addingStorage = false }
                    Button("网盘", systemImage: "cloud") { pendingAddStorageAction = .cloud; addingStorage = false }
                    Button("DLNA", systemImage: "dot.radiowaves.left.and.right") { pendingAddStorageAction = .dlna; addingStorage = false }
                }.navigationTitle("添加存储").toolbar { Button("完成") { addingStorage = false } }
            }.frame(idealWidth: 600, idealHeight: 500)
        }
        .sheet(item: $selectedStorage) { storage in
            if storage.kind == .smb || storage.kind == .webDAV {
                StorageConnectionEditor(kind: storage.kind == .smb ? .smb : .webDAV,
                    existingID: library.libraryStorages.contains(where: { $0.id == storage.id }) ? storage.id : nil,
                    close: { selectedStorage = nil }).environmentObject(library).frame(idealWidth: 650, idealHeight: 760)
            }
        }
        .confirmationDialog("移除此服务器？", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("移除", role: .destructive) { if let value = removal { remove(value) }; removal = nil }
        }

    }
    private var storageManagerContent: some View {
        StorageManagementView(add: { pendingAdd = true; storageManager = false }, edit: { id in
            pendingStorage = library.libraryStorages.first { $0.id == id }; storageManager = false
        })
    }
    private enum StorageAction { case local, smb, webDAV, cloud, dlna }
    @State private var pendingAddStorageAction: StorageAction?
    private func dispatchStorage(_ action: StorageAction) {
        switch action {
        case .local: addFolder()
        case .cloud: addCloud()
        case .dlna: addDLNA()
        case .smb, .webDAV:
            // New storage uses a transient identity and the same editor as existing connections.
            selectedStorage = .init(id: UUID(), name: "", subtitle: "", kind: action == .smb ? .smb : .webDAV)
        }
    }
    private func loadCounts(_ value: NativeCatalog) async {
        guard let id = value.sourceID else { return }
        do {
            if let source = library.embySources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.embyToken(for: id) {
                counts[id] = try await EmbyClient.mediaCounts(source: source, token: token)
            } else if let source = library.jellyfinSources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.jellyfinToken(for: id) {
                counts[id] = try await JellyfinClient.mediaCounts(source: source, token: token)
            } else if let source = library.plexSources.first(where: { $0.id == id }), let token = try KeychainPasswordStore.plexToken(for: id) {
                counts[id] = try await PlexClient.mediaCounts(source: source, token: token)
            }
        } catch { counts[id] = nil }
    }
    private func serverKind(_ value: NativeCatalog) -> NativeServerKind {
        if value.id.hasPrefix("plex:") { return .plex }
        if value.id.hasPrefix("jellyfin:") { return .jellyfin }
        return library.embySources.first { $0.id == value.sourceID }.flatMap { NativeServerKind(rawValue: $0.kind.rawValue) } ?? .emby
    }
    private func address(_ value: NativeCatalog) -> String {
        if let source = library.embySources.first(where: { $0.id == value.sourceID }) { return source.baseAddress + (source.username.map { " · \($0)" } ?? "") }
        if let source = library.jellyfinSources.first(where: { $0.id == value.sourceID }) { return source.baseAddress + (source.username.map { " · \($0)" } ?? "") }
        if let source = library.plexSources.first(where: { $0.id == value.sourceID }) { return source.baseAddress + (source.username.map { " · \($0)" } ?? "") }
        return ""
    }
    private func remove(_ value: NativeCatalog) {
        guard let id = value.sourceID else { return }
        if value.id.hasPrefix("emby:") { library.removeEmby(id: id) }
        else if value.id.hasPrefix("jellyfin:") { library.removeJellyfin(id: id) }
        else { library.removePlex(id: id) }
    }
}

struct NativeServerEditor: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let kind: NativeServerKind
    var existingID: UUID?
    @State private var draft = ServerAddressDraft()
    @State private var username = ""
    @State private var password = ""
    @State private var token = ""
    @State private var userID = ""
    @State private var usesToken = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LucentFormField("名称") { TextField("选填（自动获取）", text: $draft.name) }
                    LucentFormField("协议") { Toggle("HTTPS", isOn: $draft.usesHTTPS) }
                    LucentFormField("服务器地址") { TextField("必填（127.0.0.1 / sample.com）", text: $draft.host) }
                    LucentFormField("端口号") { TextField(kind.port, text: $draft.port) }
                    LucentFormField("路径") { TextField("选填（/path）", text: $draft.path) }
                }
                Section("登录") {
                    if kind != .plex { Toggle("使用访问令牌", isOn: $usesToken) }
                    if usesToken || kind == .plex {
                        SecureField(existingID == nil ? "访问令牌" : "留空沿用原令牌", text: $token)
                        if kind.embyKind != nil && existingID == nil { TextField("用户 ID", text: $userID) }
                    } else {
                        TextField("用户名", text: $username)
                        LucentPasswordInput(text: $password, visible: $draft.showsPassword, placeholder: existingID == nil ? "选填" : "账户不变时可留空")
                    }
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                if busy { ProgressView("正在连接") }
            }.modifier(LucentSettingsPageStyle()).lucentTextInput().autocorrectionDisabled()
                .navigationTitle("\(existingID == nil ? "添加" : "编辑") \(kind.title)")
                .toolbar { LucentEditorToolbar(actionTitle: existingID == nil ? "添加" : "保存", busy: busy, canSave: draft.address != nil, close: { dismiss() }, save: save) }
                .onChange(of: draft.host) { _, _ in draft.absorbPastedAddress() }
                .task { load() }
        }.frame(idealWidth: 680, idealHeight: 760)
    }
    private func load() {
        if let source = library.embySources.first(where: { $0.id == existingID }) {
            draft = .init(address: source.baseAddress, name: source.name); username = source.username ?? ""
        } else if let source = library.jellyfinSources.first(where: { $0.id == existingID }) {
            draft = .init(address: source.baseAddress, name: source.name); username = source.username ?? ""
        } else if let source = library.plexSources.first(where: { $0.id == existingID }) {
            draft = .init(address: source.baseAddress, name: source.name); usesToken = true
        } else { draft.port = kind.port; draft.usesHTTPS = kind == .ugreen }
    }
    private func save() {
        guard let address = draft.address else { return }
        busy = true; error = nil
        Task {
            defer { busy = false }
            var savedID: UUID?
            if let existingID {
                savedID = await library.updateServerAddress(id: existingID, address: address, replacementToken: (usesToken || kind == .plex) ? token : nil,
                    username: usesToken ? nil : username, password: password)
            } else if let embyKind = kind.embyKind {
                let saved = usesToken ? await library.addEmby(address: address, token: token, userID: userID, kind: embyKind) : await library.addEmby(address: address, username: username, password: password, kind: embyKind)
                if saved { savedID = library.embySources.last?.id }
            } else if kind == .jellyfin {
                let saved = usesToken ? await library.addJellyfin(address: address, token: token) : await library.addJellyfin(address: address, username: username, password: password)
                if saved { savedID = library.jellyfinSources.last?.id }
            } else if await library.addPlex(address: address, token: token) { savedID = library.plexSources.last?.id }
            if let savedID { library.renameServer(id: savedID, name: draft.name); dismiss() }
            else { error = library.errorMessage ?? "连接失败"; library.errorMessage = nil }
        }
    }
}
#endif
