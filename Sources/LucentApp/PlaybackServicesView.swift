import SwiftUI
import UniformTypeIdentifiers

/// Credentials are local to this device. No provider's keys are embedded or copied from other apps.
enum PlaybackServiceConfiguration {
    struct SubtitleSession: Codable {
        let login: OpenSubtitlesClient.Login
        let expires: Date
    }
    static func subtitleSession() -> OpenSubtitlesClient.Login? {
        guard let raw = try? KeychainPasswordStore.playbackServiceSecret("opensubtitles-session"),
              let data = raw.data(using: .utf8),
              let value = try? JSONDecoder().decode(SubtitleSession.self, from: data), value.expires > Date() else { return nil }
        return value.login
    }
    static func saveSession(_ login: OpenSubtitlesClient.Login) throws {
        let value = SubtitleSession(login: login, expires: Date().addingTimeInterval(23 * 3600))
        let data = try JSONEncoder().encode(value)
        try KeychainPasswordStore.setPlaybackServiceSecret(String(decoding: data, as: UTF8.self), key: "opensubtitles-session")
    }
}

enum PlaybackServiceScope { case subtitles, danmaku }

struct PlaybackServicesView: View {
    let scope: PlaybackServiceScope
    @AppStorage("lucent.danmaku.blocked") private var blockedDanmakuWords = ""
    @State private var key = ""
    @State private var username = ""
    @State private var password = ""
    @State private var appID = ""
    @State private var secret = ""
    @State private var status: String?
    @State private var busy = false
    @State private var loggedIn = false

    var body: some View {
        Form {
            if scope == .subtitles {
                Section {
                    SecureField("API Key", text: $key)
                    TextField("OpenSubtitles 用户名（可选）", text: $username)
                    SecureField("密码", text: $password)
                    Button(loggedIn ? "重新登录" : "登录账户") { login() }
                        .disabled(key.isEmpty || username.isEmpty || password.isEmpty || busy)
                    if loggedIn {
                        Button("退出账户", role: .destructive) {
                            do { try KeychainPasswordStore.setPlaybackServiceSecret("", key: "opensubtitles-session"); loggedIn = false }
                            catch { status = error.localizedDescription }
                        }
                    }
                    Link("申请 OpenSubtitles API Key", destination: URL(string: "https://www.opensubtitles.com/consumers")!)
                } header: { Text("OpenSubtitles") } footer: {
                    Text("搜索需 API Key；登录可使用账户下载额度。登录状态约 24 小时后需更新。")
                }
            }
            if scope == .danmaku {
                Section {
                    NavigationLink("自定义弹幕 API") {
                        CustomDanmakuServersView().lucentSecondaryPage()
                    }
                }
                Section {
                    #if os(tvOS)
                    TextField("屏蔽词", text: $blockedDanmakuWords)
                    #else
                    TextField("屏蔽词", text: $blockedDanmakuWords, axis: .vertical)
                        .lineLimit(3...8)
                    #endif
                } header: {
                    Text("弹幕屏蔽词")
                } footer: {
                    Text("每行输入一个屏蔽词，适用于所有影片。")
                }
                Section {
                    TextField("App ID", text: $appID)
                    SecureField("App Secret", text: $secret)
                    Link("弹弹play 开发者中心", destination: URL(string: "https://dev.dandanplay.com/")!)
                } header: { Text("弹弹play") } footer: {
                    Text("使用自行申请的应用凭据。在线搜索会发送影片名称，选择后下载对应集的弹幕。")
                }
            }
            Section {
                Button("保存配置") {
                    do {
                        if scope == .subtitles {
                            if key != (try KeychainPasswordStore.openSubtitlesAPIKey() ?? "") {
                                try KeychainPasswordStore.setPlaybackServiceSecret("", key: "opensubtitles-session"); loggedIn = false
                            }
                            try KeychainPasswordStore.setOpenSubtitlesAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        } else {
                            try KeychainPasswordStore.setPlaybackServiceSecret(appID.trimmingCharacters(in: .whitespacesAndNewlines), key: "dandan-app-id")
                            try KeychainPasswordStore.setPlaybackServiceSecret(secret.trimmingCharacters(in: .whitespacesAndNewlines), key: "dandan-secret")
                        }
                        status = "已保存"
                    } catch { status = error.localizedDescription }
                }.disabled(busy)
                if busy { ProgressView() }
                if let status { Text(LocalizedStringKey(status)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .lucentPageTitle(scope == .subtitles ? "字幕服务配置" : "弹幕服务").lucentNavigationTitleStyle()
        .lucentTextInput().autocorrectionDisabled()
        .modifier(LucentSettingsPageStyle())
        .task {
            if scope == .subtitles {
                key = (try? KeychainPasswordStore.openSubtitlesAPIKey()) ?? ""
                loggedIn = PlaybackServiceConfiguration.subtitleSession() != nil
            } else {
                appID = (try? KeychainPasswordStore.playbackServiceSecret("dandan-app-id")) ?? ""
                secret = (try? KeychainPasswordStore.playbackServiceSecret("dandan-secret")) ?? ""
            }
        }
    }
    private func login() {
        busy = true; status = nil
        Task {
            defer { busy = false }
            do {
                let value = try await OpenSubtitlesClient.login(username: username, password: password, apiKey: key)
                try KeychainPasswordStore.setOpenSubtitlesAPIKey(key)
                try PlaybackServiceConfiguration.saveSession(value)
                loggedIn = true; password = ""; status = "账户已登录"
            } catch { status = error.localizedDescription }
        }
    }
}

struct CustomDanmakuServersView: View {
    @AppStorage(CustomDanmakuServers.key) private var data = Data()
    @State private var editing: CustomDanmakuServer?
    private var servers: [CustomDanmakuServer] { CustomDanmakuServers.decode(data) }
    var body: some View {
        Form {
            Section {
                ForEach(servers) { server in
                    HStack(spacing: 12) {
                        Button { editing = server } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(server.displayName).foregroundStyle(.primary)
                                Text(URLComponents(string: server.address)?.host ?? "")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        #if os(tvOS)
                        .buttonStyle(.automatic)
                        #else
                        .buttonStyle(.plain)
                        #endif
                        Toggle("启用", isOn: Binding(get: { server.enabled }, set: { enabled in
                            var value = server; value.enabled = enabled; store(value)
                        })).labelsHidden().accessibilityLabel("启用：\(server.displayName)")
                    }
                }.onDelete { indices in
                    var values = servers; values.remove(atOffsets: indices); persist(values)
                }
                if servers.isEmpty {
                    Text("尚未添加弹幕服务器").foregroundStyle(.secondary)
                }
                Button("添加服务器", systemImage: "plus") { editing = CustomDanmakuServer() }
            } footer: {
                Text("支持兼容弹弹play协议的 API。可填写服务器根地址或以 /api/v2 结尾的地址，并保留服务提供的鉴权路径。")
            }
        }
        .lucentPageTitle("自定义弹幕 API").lucentNavigationTitleStyle()
        .modifier(LucentSettingsPageStyle())
        .navigationDestination(item: $editing) { server in
            CustomDanmakuServerEditor(server: server,
                existing: servers.contains(where: { $0.id == server.id }), save: {
                    store($0)
                    UserDefaults.standard.set("custom:" + $0.id.uuidString, forKey: "lucent.danmaku.selectedServer")
                }, remove: { persist(servers.filter { $0.id != server.id }) }).lucentSecondaryPage()
        }
    }
    private func store(_ server: CustomDanmakuServer) {
        var values = servers
        if let index = values.firstIndex(where: { $0.id == server.id }) { values[index] = server }
        else { values.append(server) }
        persist(values)
    }
    private func persist(_ values: [CustomDanmakuServer]) {
        if let encoded = try? JSONEncoder().encode(values) { data = encoded }
    }
}

private struct CustomDanmakuServerEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var server: CustomDanmakuServer
    let existing: Bool
    let save: (CustomDanmakuServer) -> Void
    let remove: () -> Void
    @State private var busy = false
    @State private var status: String?
    @State private var testTask: Task<Void, Never>?
    private var valid: Bool { (try? server.endpoint()) != nil }
    var body: some View {
        Form {
            Section {
                LabeledContent("名称") { TextField("服务器名称", text: $server.name).multilineTextAlignment(.trailing) }
                LabeledContent("地址") {
                    TextField("https://example.com", text: $server.address).multilineTextAlignment(.trailing)
                        #if os(iOS)
                        .keyboardType(.URL).textInputAutocapitalization(.never)
                        #endif
                }
                Toggle("启用", isOn: $server.enabled)
            } footer: { Text("仅填写 API 基础地址，不需要填写搜索或弹幕接口路径。") }
            .disabled(busy)
            Section {
                Button("检测连接") { test() }.disabled(!valid || busy)
                if busy { ProgressView() }
                if let status { Text(LocalizedStringKey(status)).font(.footnote).foregroundStyle(.secondary) }
            } footer: { Text("检测会验证搜索接口是否兼容；实际弹幕以播放时的匹配和下载结果为准。") }
            Section {
                Button("保存配置") {
                    guard valid else { return }
                    server.name = server.displayName
                    server.address = server.address.trimmingCharacters(in: .whitespacesAndNewlines)
                    save(server); dismiss()
                }.disabled(!valid || busy)
                if existing {
                    Button("删除服务器", role: .destructive) { remove(); dismiss() }.disabled(busy)
                }
            }
        }
        .lucentPageTitle("弹幕服务器").lucentNavigationTitleStyle()
        .modifier(LucentSettingsPageStyle())
        .autocorrectionDisabled()
        .onChange(of: server) { _, _ in status = nil }
        .onDisappear { testTask?.cancel() }
    }
    private func test() {
        guard let endpoint = try? server.endpoint() else { return }
        busy = true; status = nil
        testTask?.cancel()
        testTask = Task {
            defer { busy = false }
            do {
                _ = try await DandanplayClient.search("Lucent", server: endpoint)
                try Task.checkCancellation()
                status = "连接成功，搜索接口兼容。"
            } catch {
                guard !Task.isCancelled else { return }
                // Do not echo a credential-bearing API URL from an underlying URL error.
                status = DanmakuError.message(for: error)
            }
        }
    }
}

struct SubtitleSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    var onInstalled: (Data, String) -> Void = { _, _ in }
    @State private var query = ""
    @State private var results: [OpenSubtitlesClient.Result] = []
    @State private var busy = false
    @State private var status: String?
    @State private var page = 1
    @State private var hasMore = false
    @State private var importer = false
    @State private var hasSearched = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("影片或剧集名称", text: $query).submitLabel(.search).onSubmit { search() }.disabled(busy)
                    Button("搜索 OpenSubtitles", systemImage: "magnifyingglass") { search() }
                        .disabled(busy || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    #if !os(tvOS)
                    Button("从文件添加字幕", systemImage: "folder.badge.plus") { importer = true }.disabled(busy)
                    #endif
                }
                if let status { Section { Text(LocalizedStringKey(status)).font(.footnote).foregroundStyle(.secondary) } }
                if busy { ProgressView("正在处理…") }
                Section {
                    ForEach(results) { result in
                        Button { download(result) } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "captions.bubble").font(.title2).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.displayRelease).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                    Text("\(result.language.uppercased()) · \(result.downloads) 次下载" + (result.hearingImpaired ? " · 听障字幕" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(result.displayFilename).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.disabled(busy)
                    }
                    if hasSearched && !busy && results.isEmpty { Text("未找到字幕，试试原文片名。").foregroundStyle(.secondary) }
                    if hasMore && !busy { Button("加载更多") { search(more: true) } }
                } header: { if !results.isEmpty { Text("搜索结果") } }
            }
            .lucentPageTitle("添加字幕").lucentNavigationTitleStyle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { query = item.identity?.seriesName ?? item.metadata?.localizedTitle ?? item.title }
            .onChange(of: query) { _, _ in resetResults() }
            #if !os(tvOS)
            .fileImporter(isPresented: $importer, allowedContentTypes: SubtitleParser.supportedExtensions.compactMap { UTType(filenameExtension: $0) }) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size > 0, size <= 5_000_000 else { throw CocoaError(.fileReadTooLarge) }
                    let data = try Data(contentsOf: url)
                    install(data, filename: url.lastPathComponent)
                } catch { status = error.localizedDescription }
            }
            #endif
        }
    }
    private func resetResults() {
        guard !busy else { return }
        results = []; page = 1; hasMore = false; hasSearched = false; status = nil
    }
    private func search(more: Bool = false) {
        busy = true; status = nil
        if !more { results = []; page = 1; hasMore = false }
        let next = more ? page + 1 : 1
        Task {
            defer { busy = false }
            do {
                guard let key = try KeychainPasswordStore.openSubtitlesAPIKey(), !key.isEmpty else {
                    status = "请先在字幕服务配置中填写 OpenSubtitles API Key。"; return
                }
                let language = LocalizationPreferences.current.subtitleSearchLanguage
                let response = try await OpenSubtitlesClient.search(item: item, language: language, apiKey: key,
                    query: query, page: next, session: PlaybackServiceConfiguration.subtitleSession())
                let ids = Set(results.map(\.id))
                let additions = response.filter { !ids.contains($0.id) }
                results += additions; page = next; hasMore = !additions.isEmpty; hasSearched = true
            } catch { status = error.localizedDescription }
        }
    }
    private func download(_ result: OpenSubtitlesClient.Result) {
        busy = true; status = nil
        Task {
            defer { busy = false }
            do {
                guard let key = try KeychainPasswordStore.openSubtitlesAPIKey(), !key.isEmpty else { return }
                let (data, filename) = try await OpenSubtitlesClient.download(fileID: result.id, apiKey: key,
                    session: PlaybackServiceConfiguration.subtitleSession())
                install(data, filename: filename)
            } catch { status = error.localizedDescription }
        }
    }
    private func install(_ data: Data, filename: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        if ["srt", "vtt", "ass", "ssa"].contains(ext), SubtitleParser.parse(data, fileExtension: ext).isEmpty {
            status = "字幕中没有可读取的时间轴，请选择其他文件。"; return
        }
        if library.installSubtitle(id: item.id, data: data, filename: filename) {
            onInstalled(data, filename); dismiss()
        } else { status = library.errorMessage; library.errorMessage = nil }
    }
}
