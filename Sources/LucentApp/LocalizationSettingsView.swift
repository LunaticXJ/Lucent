import SwiftUI

private struct ContentLocalizationKey: EnvironmentKey { static let defaultValue = LocalizationPreferences.current.contentID }
extension EnvironmentValues {
    var contentLocalizationID: String {
        get { self[ContentLocalizationKey.self] }
        set { self[ContentLocalizationKey.self] = newValue }
    }
}

struct LocalizationEnvironment: ViewModifier {
    @AppStorage("lucent.locale.interface") private var interface = "system"
    @AppStorage("lucent.locale.content") private var content = "auto"
    @AppStorage("lucent.locale.region") private var region = "system"
    @AppStorage("lucent.locale.dateOrder") private var dateOrder = "system"
    @AppStorage("lucent.locale.clock") private var clock = "system"
    @AppStorage("lucent.locale.zone") private var zone = "system"
    @State private var systemRevision = 0
    func body(content view: Content) -> some View {
        let _ = [interface, content, region, dateOrder, clock, zone, String(systemRevision)]
        let preferences = LocalizationPreferences.current
        var calendar = preferences.displayLocale.calendar
        calendar.timeZone = preferences.timeZone
        return view.environment(\.locale, preferences.displayLocale)
            .environment(\.calendar, calendar)
            .environment(\.timeZone, preferences.timeZone)
            .environment(\.contentLocalizationID, preferences.contentID)
            .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in systemRevision += 1 }
            .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in systemRevision += 1 }
    }
}

struct LocalizationSettingsView: View {
    @AppStorage("lucent.locale.interface") private var interface = "system"
    @AppStorage("lucent.locale.content") private var content = "auto"
    @AppStorage("lucent.locale.subtitles") private var subtitles = "auto"
    @AppStorage("lucent.locale.audio") private var audio = "original"
    @AppStorage("lucent.locale.region") private var region = "system"
    @AppStorage("lucent.locale.dateOrder") private var dateOrder = "system"
    @AppStorage("lucent.locale.clock") private var clock = "system"
    @AppStorage("lucent.locale.zone") private var zone = "system"
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.locale) private var locale
    private let languages: [(String, String)] = [("zh-CN", "简体中文"), ("zh-TW", "繁体中文"), ("en-US", "English (US)"), ("en-GB", "English (UK)"), ("ja-JP", "日本語"), ("ko-KR", "한국어"), ("fr-FR", "Français"), ("de-DE", "Deutsch"), ("es-ES", "Español"), ("pt-BR", "Português (Brasil)"), ("it-IT", "Italiano"), ("ru-RU", "Русский"), ("ar-SA", "العربية"), ("hi-IN", "हिन्दी"), ("th-TH", "ไทย")]
    var body: some View {
        Form {
            Section {
                LucentSettingsPicker("界面语言", selection: $interface) {
                    Text("跟随系统").tag("system")
                    Text("简体中文").tag("zh-Hans")
                    Text("繁体中文").tag("zh-Hant")
                    Text("English").tag("en")
                }
                LucentSettingsPicker("海报与元数据", selection: $content) {
                    Text("自动").tag("auto")
                    languageOptions
                }
                LucentSettingsPicker("字幕首选语言", selection: $subtitles) {
                    Text("自动").tag("auto")
                    languageOptions
                }
                LucentSettingsPicker("音轨首选语言", selection: $audio) {
                    Text("保留片源默认").tag("original")
                    Text("自动").tag("auto")
                    languageOptions
                }
            } header: { Text("语言") } footer: { Text("自动使用界面或系统首选语言。字幕和音轨偏好在下次起播时使用；播放中手动选择优先。") }
            Section("地区与日期") {
                NavigationLink {
                    Group {
                        LocaleChoiceList(title: "地区", selection: $region, automatic: "system", options: Locale.Region.isoRegions.map { ($0.identifier, locale.localizedString(forRegionCode: $0.identifier) ?? $0.identifier) })
                    }.lucentSecondaryPage()
                } label: { LabeledContent("地区", value: region == "system" ? "跟随系统".lucentLocalized : locale.localizedString(forRegionCode: region) ?? region) }
                LucentSettingsPicker("日期格式", selection: $dateOrder) {
                    Text("跟随地区").tag("system")
                    Text("年 / 月 / 日").tag("ymd")
                    Text("日 / 月 / 年").tag("dmy")
                    Text("月 / 日 / 年").tag("mdy")
                }
                LucentSettingsPicker("时间格式", selection: $clock) {
                    Text("跟随地区").tag("system")
                    Text("12 小时制").tag("12")
                    Text("24 小时制").tag("24")
                }
                NavigationLink {
                    Group {
                        LocaleChoiceList(title: "时区", selection: $zone, automatic: "system", options: TimeZone.knownTimeZoneIdentifiers.map { ($0, (TimeZone(identifier: $0)?.localizedName(for: .standard, locale: locale) ?? $0) + " · " + $0) })
                    }.lucentSecondaryPage()
                } label: { LabeledContent("时区", value: zone == "system" ? "跟随系统".lucentLocalized : zone) }
                LabeledContent("日期预览", value: LocalizationPreferences.current.formatted(Date()))
            }
            Section {
                Button("更新已有影片的本地化资料") { Task { await library.refreshLocalizedMetadata() } }
                    .disabled(library.enrichingMetadata)
            } footer: { Text("按已匹配的 TMDB 编号更新聚合媒体库，不重新识别文件。影视服务器资料由服务器提供。") }
        }
            .modifier(LucentSettingsPageStyle())
        .lucentPageTitle("语言与地区").lucentNavigationTitleStyle()
        .tint(.gray)
    }
    private var languageOptions: some View {
        ForEach(languages, id: \.0) { Text(LocalizedStringKey($0.1)).tag($0.0) }
    }
}

private struct LocaleChoiceList: View {
    let title: String
    @Binding var selection: String
    let automatic: String
    let options: [(String, String)]
    @State private var query = ""
    var body: some View {
        List {
            choice(automatic, title: "跟随系统".lucentLocalized)
            ForEach(options.filter { query.isEmpty || $0.1.localizedStandardContains(query) || $0.0.localizedStandardContains(query) }.sorted { $0.1.localizedStandardCompare($1.1) == .orderedAscending }, id: \.0) { id, title in
                choice(id, title: title)
            }
        }.lucentPageTitle(title).lucentNavigationTitleStyle().searchable(text: $query)
    }
    private func choice(_ id: String, title: String) -> some View {
        Button { selection = id } label: {
            HStack { Text(title).foregroundStyle(.primary); Spacer(); if selection == id { Image(systemName: "checkmark").foregroundStyle(.gray) } }
        }
    }
}
