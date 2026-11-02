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

struct PlaybackServicesView: View {
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
            Section {
                TextField("App ID", text: $appID)
                SecureField("App Secret", text: $secret)
                Link("弹弹play 开发者中心", destination: URL(string: "https://dev.dandanplay.com/")!)
            } header: { Text("弹弹play") } footer: {
                Text("使用自行申请的应用凭据。在线搜索会发送影片名称，选择后下载对应集的弹幕。")
            }
            Section {
                Button("保存配置") {
                    do {
                        if key != (try KeychainPasswordStore.openSubtitlesAPIKey() ?? "") {
                            try KeychainPasswordStore.setPlaybackServiceSecret("", key: "opensubtitles-session"); loggedIn = false
                        }
                        try KeychainPasswordStore.setOpenSubtitlesAPIKey(key.trimmingCharacters(in: .whitespacesAndNewlines))
                        try KeychainPasswordStore.setPlaybackServiceSecret(appID.trimmingCharacters(in: .whitespacesAndNewlines), key: "dandan-app-id")
                        try KeychainPasswordStore.setPlaybackServiceSecret(secret.trimmingCharacters(in: .whitespacesAndNewlines), key: "dandan-secret")
                        status = "已保存"
                    } catch { status = error.localizedDescription }
                }.disabled(busy)
                if busy { ProgressView() }
                if let status { Text(LocalizedStringKey(status)).font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("字幕与弹幕服务").lucentNavigationTitleStyle()
        .lucentTextInput().autocorrectionDisabled()
        .lucentScrollBackgroundHidden().background(LucentUI.page)
        .task {
            key = (try? KeychainPasswordStore.openSubtitlesAPIKey()) ?? ""
            appID = (try? KeychainPasswordStore.playbackServiceSecret("dandan-app-id")) ?? ""
            secret = (try? KeychainPasswordStore.playbackServiceSecret("dandan-secret")) ?? ""
            loggedIn = PlaybackServiceConfiguration.subtitleSession() != nil
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

struct SubtitleSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    var onInstalled: (Data, String) -> Void = { _, _ in }
    @State private var query = ""
    @State private var language = LocalizationPreferences.current.subtitleSearchLanguage
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
                    Picker("字幕语言", selection: $language) {
                        Text("简体与繁体中文").tag("zh-cn,zh-tw")
                        Text("简体中文").tag("zh-cn")
                        Text("繁体中文").tag("zh-tw")
                        Text("英语").tag("en")
                        Text("日语").tag("ja")
                        ForEach(["ko", "fr", "de", "es", "pt", "ru", "it", "ar", "hi", "th"], id: \.self) { code in
                            Text(LocalizationPreferences.current.displayLocale.localizedString(forLanguageCode: code) ?? code).tag(code)
                        }
                    }.disabled(busy)
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
                                    Text(result.release).font(.subheadline).foregroundStyle(.primary).lineLimit(2)
                                    Text("\(result.language.uppercased()) · \(result.downloads) 次下载" + (result.hearingImpaired ? " · 听障字幕" : ""))
                                        .font(.caption).foregroundStyle(.secondary)
                                    Text(result.filename).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                            }.padding(.vertical, 4)
                        }.disabled(busy)
                    }
                    if hasSearched && !busy && results.isEmpty { Text("未找到字幕，试试原文片名或其他语言。 ").foregroundStyle(.secondary) }
                    if hasMore && !busy { Button("加载更多") { search(more: true) } }
                } header: { if !results.isEmpty { Text("搜索结果") } }
                Section {
                    NavigationLink("字幕服务配置") { PlaybackServicesView() }
                }
            }
            .navigationTitle("添加字幕").lucentNavigationTitleStyle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { query = item.identity?.seriesName ?? item.metadata?.localizedTitle ?? item.title }
            .onChange(of: query) { _, _ in resetResults() }
            .onChange(of: language) { _, _ in resetResults() }
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
