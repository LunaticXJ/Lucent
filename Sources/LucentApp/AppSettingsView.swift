import SwiftUI
#if os(iOS)
import UIKit
#endif

enum AppSettingsAction {
    case profiles, trakt, enrichMetadata, purgeMissing
}



struct AppSettingsView: View {
    @EnvironmentObject private var library: LibraryStore
    @Binding var sortSelection: String
    @Binding var filterSelection: String
    let onAction: (AppSettingsAction) -> Void
    let onSelectProfile: (UUID) -> Void
    @AppStorage("lucent.library.autoScanInterval") private var autoScanInterval = 86_400.0
    @AppStorage("lucent.appearance.theme") private var appearance = "system"
    @AppStorage("lucent.home.collapseDock") private var collapseDock = true
    @AppStorage("lucent.playback.atmosLayout") private var atmosLayout = "5.1.2"
    @AppStorage("lucent.autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("lucent.subtitleFontScale") private var subtitleFontScale = 1.0
    @AppStorage("lucent.subtitleBackgroundOpacity") private var subtitleBackgroundOpacity = 0.6
    @AppStorage("lucent.player.controlsAutoHideDelay") private var controlsAutoHideDelay = 3.0
    @AppStorage("lucent.player.seekPreview") private var seekPreviewEnabled = true
    @AppStorage("lucent.player.seekInterval") private var seekInterval = 10.0
    @AppStorage("lucent.player.showRemainingTime") private var showRemainingTime = false
    @AppStorage("lucent.player.videoScaleMode") private var videoScaleMode = VideoScaleMode.fit.rawValue
    @State private var metadataTokenInput = ""
    @State private var metadataTokenConfigured = false
    @State private var metadataTokenStatus: String?
    @State private var matchingItem: MediaItem?
    @AppStorage(NetworkUsagePolicy.playbackKey) private var cellularPlayback = true
    @AppStorage(NetworkUsagePolicy.syncKey) private var cellularSync = false
    @AppStorage(NetworkUsagePolicy.downloadKey) private var cellularDownloads = false

    private var unmatchedItems: [MediaItem] {
        library.localLibraryItems.filter { $0.metadata == nil && $0.missingSince == nil }
    }

    private var scanningSources: Bool {
        library.fileSourceIDs.contains(where: library.isScanningFileSource) || !library.scanningFolders.isEmpty || !library.scanningSMBSources.isEmpty ||
        !library.scanningWebDAVSources.isEmpty || !library.scanningCloudSources.isEmpty
    }

    var body: some View {
        Form {
            Section("通用") {
                NavigationLink { LocalizationSettingsView().lucentSecondaryPage() } label: {
                    settingsRow("语言与地区", icon: "globe")
                }
                NavigationLink { appearancePage.lucentSecondaryPage() } label: {
                    settingsRow("外观与首页", icon: "circle.lefthalf.filled")
                }
            }
            Section("观看体验") {
                NavigationLink { playbackPage.lucentSecondaryPage() } label: {
                    settingsRow("播放", icon: "play.rectangle")
                }
                NavigationLink { subtitlePage.lucentSecondaryPage() } label: {
                    settingsRow("字幕", icon: "captions.bubble")
                }
                NavigationLink { PlaybackServicesView(scope: .danmaku).lucentSecondaryPage() } label: {
                    settingsRow("弹幕", icon: "bubble.left.and.bubble.right")
                }
            }
            Section("内容与存储") {
                #if os(iOS)
                NavigationLink { cellularNetworkPage.lucentSecondaryPage() } label: {
                    settingsRow("移动网络", icon: "antenna.radiowaves.left.and.right")
                }
                #endif
                NavigationLink { libraryPage.lucentSecondaryPage() } label: {
                    settingsRow("聚合媒体库", icon: "rectangle.stack")
                }
                NavigationLink { CacheSettingsView(embedded: true).lucentSecondaryPage() } label: {
                    settingsRow("缓存与存储", icon: "internaldrive")
                }
                NavigationLink { metadataPage.lucentSecondaryPage() } label: {
                    settingsRow("在线元数据", icon: "photo.on.rectangle.angled")
                }
            }
            Section("账户与同步") {
                NavigationLink { profilesPage.lucentSecondaryPage() } label: {
                    settingsRow("观看资料", icon: "person.crop.circle")
                }
                if library.activeProfile?.isChild != true {
                    NavigationLink { syncPage.lucentSecondaryPage() } label: {
                        settingsRow("同步与服务", icon: "arrow.triangle.2.circlepath")
                    }
                }
            }
        }
        .modifier(LucentSettingsPageStyle())
        .lucentPageTitle("设置")
        .lucentTabRoot()
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .onAppear {
            metadataTokenConfigured = !((try? KeychainPasswordStore.metadataToken()) ?? "").isEmpty
        }
        .sheet(item: $matchingItem) { item in
            MetadataMatchView(item: item).environmentObject(library)
        }
    }

    private func settingsRow(_ title: String, icon: String) -> some View {
        LucentSettingsRow(title: title, icon: icon)
    }

    private func settingsPage<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        Form(content: content)
            .modifier(LucentSettingsPageStyle())
            .lucentPageTitle(title).lucentNavigationTitleStyle()
    }

    private var appearancePage: some View {
        settingsPage("外观与首页") {
            Section {
                LucentSettingsPicker("主题", selection: $appearance) {
                    Text("跟随系统").tag("system")
                    Text("深色").tag("dark")
                    Text("浅色").tag("light")
                }
                .pickerStyle(.menu)
            } header: { Text("外观") }
            #if os(iOS)
            AppIconSettingsSection()
            Section("首页") {
                Toggle("滚动时收起底栏", isOn: $collapseDock)
            }
            #endif
        }
    }

    private var playbackPage: some View {
        settingsPage("播放") {
            Section {
                Toggle("播放光盘转场", isOn: Binding(
                    get: { UserDefaults.standard.object(forKey: "lucent.playback.discTransition") as? Bool ?? true },
                    set: { UserDefaults.standard.set($0, forKey: "lucent.playback.discTransition") }))
            }
            Section("播放控制") {
                #if os(iOS)
                NavigationLink("播放手势") { PlaybackGestureSettings().lucentSecondaryPage() }
                #else
                NavigationLink("播放控制") { NativePlaybackInputSettings().lucentSecondaryPage() }
                #endif
                NavigationLink("进度记忆") { PlaybackProgressSettings().lucentSecondaryPage() }
                Toggle("拖动进度预览", isOn: $seekPreviewEnabled)
                LucentSettingsPicker("自动隐藏控制栏", selection: $controlsAutoHideDelay) {
                    Text("3 秒").tag(3.0)
                    Text("5 秒").tag(5.0)
                    Text("8 秒").tag(8.0)
                    Text("不自动隐藏").tag(0.0)
                }
                .pickerStyle(.menu)
                LucentSettingsPicker("快进 / 快退间隔", selection: $seekInterval) {
                    ForEach([5.0, 10.0, 15.0, 30.0], id: \.self) { seconds in
                        Text("\(Int(seconds)) 秒").tag(seconds)
                    }
                }
                .pickerStyle(.menu)
                Toggle("显示剩余时长", isOn: $showRemainingTime)
            }
            Section {
                LucentSettingsPicker("画面缩放", selection: $videoScaleMode) {
                    ForEach(VideoScaleMode.allCases, id: \.rawValue) { mode in
                        Text(LocalizedStringKey(mode.title)).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.menu)
            } header: { Text("画面") }
            Section {
                Toggle("自动跳过片头片尾", isOn: $autoSkipSegments)
            }
            Section {
                LucentSettingsPicker("扬声器布局", selection: $atmosLayout) {
                    ForEach(["5.1.2", "5.1.4", "7.1.2", "7.1.4", "9.1.6"], id: \.self) { layout in
                        Text(layout).tag(layout)
                    }
                }
                .pickerStyle(.menu)
            } header: { Text("音频输出") } footer: {
                Text("需片源与音频设备支持。")
            }
        }
    }

    private var subtitlePage: some View {
        settingsPage("字幕") {
            Section {
                ZStack {
                    LinearGradient(colors: [Color(white: 0.2), Color(white: 0.09)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text("让每一句对白，清晰可见。")
                        .font(.system(size: 18 * subtitleFontScale, weight: .semibold))
                        .foregroundStyle(.white).multilineTextAlignment(.center)
                        .padding(10)
                        .background(.black.opacity(subtitleBackgroundOpacity), in: RoundedRectangle(cornerRadius: 7))
                        .padding(16)
                }
                .frame(height: 118).clipShape(RoundedRectangle(cornerRadius: 15))
                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
            }
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("字幕字号")
                        Spacer()
                        Text("\(Int((subtitleFontScale * 100).rounded()))%").foregroundStyle(.secondary).monospacedDigit()
                    }
                    LucentValueSlider(value: $subtitleFontScale, range: 0.75...1.5, step: 0.05)
                        .accessibilityLabel("字幕字号")
                }
                .padding(.vertical, 6)
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("背景不透明度")
                        Spacer()
                        Text("\(Int((subtitleBackgroundOpacity * 100).rounded()))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    LucentValueSlider(value: $subtitleBackgroundOpacity, range: 0...0.85, step: 0.05)
                        .accessibilityLabel("字幕背景不透明度")
                }
                .padding(.vertical, 6)
                Button("恢复默认外观") { subtitleFontScale = 1; subtitleBackgroundOpacity = 0.6 }
                    .foregroundStyle(.primary)
            } header: { Text("文本字幕") } footer: {
                Text("特效字幕保留片源样式。")
            }
            Section("在线字幕") {
                NavigationLink("字幕服务配置") { PlaybackServicesView(scope: .subtitles).lucentSecondaryPage() }
            }
        }
    }

    private var metadataPage: some View {
        settingsPage("在线元数据") {
            Section {
                LabeledContent("TMDB", value: metadataTokenConfigured ? "令牌已配置" : "尚未配置")
                SecureField("API 密钥或读取令牌", text: $metadataTokenInput)
                    .textContentType(.password).privacySensitive()
                    .autocorrectionDisabled().lucentTextInput()
                Button("保存令牌") { saveMetadataToken() }
                    .foregroundStyle(.primary)
                    .disabled(metadataTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: { Text("The Movie Database") }
            if let metadataTokenStatus {
                Section { Text(metadataTokenStatus).font(.subheadline).foregroundStyle(.secondary) }
            }
        }
    }

    private func saveMetadataToken() {
        let value = metadataTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        do {
            try KeychainPasswordStore.setMetadataToken(value)
            metadataTokenInput = ""
            metadataTokenConfigured = true
            metadataTokenStatus = "已保存，正在处理媒体库资料与图片。"
            library.retryLocalLibraryProcessing()
        } catch {
            metadataTokenStatus = "保存失败：请检查系统钥匙串权限。"
        }
    }

    private var libraryPage: some View {
        settingsPage("聚合媒体库") {
            Section("浏览") {
                LucentSettingsPicker("默认排序", selection: $sortSelection) {
                    Text("最近添加").tag("newest")
                    Text("标题").tag("title")
                }
                .pickerStyle(.menu)
                LucentSettingsPicker("默认筛选", selection: $filterSelection) {
                    Text("全部").tag("all")
                    Text("未看完").tag("unwatched")
                    Text("收藏").tag("favorites")
                }
                .pickerStyle(.menu)
            }
            if library.activeProfile?.isChild != true {
                Section {
                    LabeledContent("存储连接", value: "\(library.libraryStorages.count)")
                    LabeledContent("已启用文件源", value: "\(library.fileSources.filter { $0.enabled && !$0.needsConfirmation }.count)")
                } header: { Text("文件源") } footer: {
                    Text("在片源中连接存储并导入目录。停用不删除记录。")
                }
                Section("扫描与影片资料") {
                    LucentSettingsPicker("自动扫描", selection: $autoScanInterval) {
                        Text("仅手动").tag(0.0)
                        Text("每天").tag(86_400.0)
                        Text("每周").tag(604_800.0)
                    }
                    Toggle("媒体信息探测", isOn: Binding(
                        get: { library.mediaProbeEnabled },
                        set: { library.setMediaProbeEnabled($0) }))
                    Text("扫描时探测编码与音轨，默认关闭。")
                        .font(.caption).foregroundStyle(.secondary)
                    LabeledContent("待匹配文件", value: "\(unmatchedItems.count)")
                    LabeledContent("已探测媒体", value: "\(library.localLibraryItems.filter { $0.technicalInfo != nil }.count)")
                    if let title = library.processingItemTitle { ProgressView("探测：\(title)").font(.caption) }
                    if let status = library.catalogProcessingStatus { Text(LocalizedStringKey(status)).font(.caption).foregroundStyle(.secondary) }
                    Button("重试获取未完成的资料", systemImage: "arrow.triangle.2.circlepath") { library.retryLocalLibraryProcessing() }
                        .foregroundStyle(.primary)
                    if scanningSources { ProgressView("正在扫描文件源") }
                    Button("刷新聚合媒体库", systemImage: "arrow.clockwise") { refreshLibrary() }
                        .foregroundStyle(.primary).disabled(scanningSources)
                    Button { onAction(.enrichMetadata) } label: {
                        Label("补全影片资料", systemImage: "sparkles")
                    }
                    .foregroundStyle(.primary).disabled(library.enrichingMetadata)
                    if !unmatchedItems.isEmpty {
                        Menu("手动匹配影片资料", systemImage: "text.magnifyingglass") {
                            ForEach(unmatchedItems.prefix(30)) { item in
                                Button(item.title) { matchingItem = item }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    Button(role: .destructive) { onAction(.purgeMissing) } label: {
                        Label("清理失效影片", systemImage: "trash")
                    }
                    .disabled(!library.items.contains { $0.missingSince != nil })
                }
            }
        }
    }

    private func refreshLibrary() {
        for scope in library.fileSources where scope.enabled && !scope.needsConfirmation { library.scanFileScope(scope.id) }
    }

    private var profilesPage: some View {
        settingsPage("观看资料") {
            Section {
                ForEach(library.viewerProfiles) { profile in
                    Button { onSelectProfile(profile.id) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle").font(.title3).foregroundStyle(.secondary)
                            Text(profile.name).foregroundStyle(.primary)
                            Spacer()
                            if library.activeProfile?.id == profile.id {
                                Image(systemName: "checkmark").foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 5)
                    }
                    .accessibilityAddTraits(library.activeProfile?.id == profile.id ? .isSelected : [])
                }
            }
            if library.activeProfile?.isChild == false {
                Section { Button("管理观看资料") { onAction(.profiles) }.foregroundStyle(.primary) }
            }
        }
    }

    private var cellularNetworkPage: some View {
        settingsPage("移动网络") {
            Section {
                Toggle("允许移动网络同步", isOn: $cellularSync)
                Toggle("允许移动网络下载", isOn: $cellularDownloads)
            } footer: {
                Text("关闭后，观看记录和收藏仅在 Wi-Fi 同步，影片下载仅使用 Wi-Fi。")
            }
            Section {
                Toggle("允许移动网络播放", isOn: $cellularPlayback)
            } footer: {
                Text("开启后，移动网络播放不再询问；关闭后播放前会询问。本地文件和已下载影片不受影响。")
            }
        }
        .onChange(of: cellularPlayback) { _, _ in NetworkUsagePolicy.notifySettingsChanged() }
        .onChange(of: cellularSync) { _, _ in NetworkUsagePolicy.notifySettingsChanged() }
        .onChange(of: cellularDownloads) { _, _ in NetworkUsagePolicy.notifySettingsChanged() }
    }

    private var syncPage: some View {
        settingsPage("同步与服务") {
            Section("iCloud") {
                Toggle("iCloud 数据同步", isOn: $library.iCloudSyncEnabled)
                Button("立即同步") { Task { await library.syncNow() } }
                    .foregroundStyle(.primary)
                    .disabled(!library.iCloudSyncEnabled || library.syncing)
                if let status = library.syncStatus {
                    Text(LocalizedStringKey(status)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("开启后同步收藏、聚合媒体库观看记录、片源与用户配置。影音服务器观看进度仍与服务器同步。")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Trakt") {
                Button("Trakt 设置") { onAction(.trakt) }.foregroundStyle(.primary)
            }
        }
    }
}

#if os(iOS)
enum AppIconChoice: String, CaseIterable, Identifiable {
    case primary = "AppIcon"
    case graphiteIce = "AppIconGraphiteIce"
    case graphiteRose = "AppIconGraphiteRose"

    var id: Self { self }
    var systemName: String? { self == .primary ? nil : rawValue }
    var previewName: String { rawValue + "Preview" }

    @MainActor static var current: Self {
        UIApplication.shared.alternateIconName.flatMap(Self.init(rawValue:)) ?? .primary
    }

    var title: LocalizedStringKey {
        switch self {
        case .primary: "默认图标"
        case .graphiteIce: "冰蓝石墨"
        case .graphiteRose: "淡粉石墨"
        }
    }
}

private struct AppIconSettingsSection: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedName: String?
    @State private var isChanging = false
    @State private var showFailure = false

    var body: some View {
        Section("更换图标") {
            HStack(spacing: 12) {
                ForEach(AppIconChoice.allCases) { icon in
                    let selected = selectedName == icon.systemName
                    Button {
                        changeIcon(to: icon)
                    } label: {
                        Image(icon.previewName)
                            .resizable()
                            .frame(width: 58, height: 58)
                            .clipShape(RoundedRectangle(cornerRadius: 13))
                            .padding(4)
                            .overlay {
                                if selected {
                                    RoundedRectangle(cornerRadius: 17)
                                        .strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(icon.title))
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
        .disabled(isChanging || !UIApplication.shared.supportsAlternateIcons)
        .onAppear { selectedName = UIApplication.shared.alternateIconName }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { selectedName = UIApplication.shared.alternateIconName }
        }
        .alert("无法更换图标", isPresented: $showFailure) {
            Button("好", role: .cancel) {}
        }
    }

    private func changeIcon(to icon: AppIconChoice) {
        guard !isChanging, selectedName != icon.systemName else { return }
        isChanging = true
        Task { @MainActor in
            defer {
                selectedName = UIApplication.shared.alternateIconName
                isChanging = false
            }
            do {
                try await UIApplication.shared.setAlternateIconName(icon.systemName)
            } catch {
                showFailure = true
            }
        }
    }
}
#endif
