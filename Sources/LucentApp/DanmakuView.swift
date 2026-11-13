import SwiftUI

@MainActor final class DanmakuModel: ObservableObject {
    @Published private(set) var comments: [DanmakuComment] = []
    @Published private(set) var source = "未选择弹幕"
    @Published private(set) var revision = UUID()
    @Published var status: String?
    private var generation = UUID()
    private var activeItemID: UUID?

    private func seriesKeys(for item: MediaItem) -> [String] {
        guard case .episode(let series, let season, _, _) = item.identity else { return [] }
        let key = "lucent.danmaku.series.\(series).\(season)"
        guard let id = item.metadata?.providerID, id > 0 else { return [key] }
        return [key, "lucent.danmaku.series.\(id).\(season)"]
    }

    func load(for item: MediaItem, enabled: Bool, servers: [DandanplayClient.Server]) async {
        if activeItemID != item.id {
            activeItemID = item.id
            comments = []
            source = "未选择弹幕"
            revision = UUID()
        }
        if comments.isEmpty { await restore(for: item.id) }
        guard enabled, !Task.isCancelled else { return }
        let keys = seriesKeys(for: item)
        if !comments.isEmpty {
            // Promote older preferences indexed by metadata to the series/season key.
            if let key = keys.first, UserDefaults.standard.object(forKey: key) == nil {
                let existing = keys.dropFirst().compactMap { UserDefaults.standard.stringArray(forKey: $0) }.first
                let sourceParts = source.components(separatedBy: " · ")
                let server = servers.first { $0.name == sourceParts.first }
                if let existing {
                    UserDefaults.standard.set(existing, forKey: key)
                } else if let server, sourceParts.count == 3 {
                    UserDefaults.standard.set([server.id, sourceParts[1]], forKey: key)
                }
            }
            return
        }
        let request = generation
        let preference = keys.compactMap { UserDefaults.standard.stringArray(forKey: $0) }.first
        var ordered = servers
        if let preferredID = preference?.first, let index = ordered.firstIndex(where: { $0.id == preferredID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }
        for server in ordered {
            guard !Task.isCancelled, generation == request else { return }
            do {
                let preferredTitle = preference?.first == server.id ? preference?.last : nil
                guard let match = try await DandanplayClient.exactMatch(for: item, server: server, preferredTitle: preferredTitle) else { continue }
                let data = try await DandanplayClient.comments(episodeID: match.id, server: server)
                guard !Task.isCancelled, generation == request else { return }
                try await installMatch(match, data: data, item: item)
                return
            } catch {
                guard generation == request else { return }
            }
        }
    }

    func installMatch(_ match: DandanplayClient.Episode, data: Data, item: MediaItem) async throws {
        guard activeItemID == item.id else { throw CancellationError() }
        try await install(data: data, source: "\(match.server.name) · \(match.anime) · \(match.title)", itemID: item.id)
        for key in seriesKeys(for: item) {
            UserDefaults.standard.set([match.server.id, match.anime], forKey: key)
        }
    }
    private struct Saved: Codable, Sendable { let comments: [DanmakuComment]; let source: String }
    private static func url(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Danmaku", isDirectory: true).appendingPathComponent(id.uuidString + ".json")
    }
    func restore(for id: UUID) async {
        let request = UUID(); generation = request
        let url = Self.url(id)
        let saved = await Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url), data.count <= 25_000_000 else { return Optional<Saved>.none }
            return try? JSONDecoder().decode(Saved.self, from: data)
        }.value
        guard generation == request, !Task.isCancelled, let saved else { return }
        comments = saved.comments; source = saved.source; revision = UUID()
    }
    func install(data: Data, source: String, itemID: UUID) async throws {
        let request = UUID(); generation = request
        let url = Self.url(itemID)
        let values = try await Task.detached(priority: .userInitiated) {
            let values = try DanmakuParser.parse(data)
            guard !values.isEmpty else { throw DanmakuError.noComments }
            let encoded = try JSONEncoder().encode(Saved(comments: values, source: source))
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoded.write(to: url, options: .atomic)
            return values
        }.value
        guard generation == request, !Task.isCancelled else { throw CancellationError() }
        comments = values; self.source = source; revision = UUID(); status = nil
    }
    func clear(for id: UUID) {
        generation = UUID(); comments = []; source = "未选择弹幕"; revision = UUID()
        try? FileManager.default.removeItem(at: Self.url(id))
    }
}

/// Precomputes collision-free lanes; drawing only visits the current time window.
struct DanmakuLayout: Sendable {
    struct Entry: Sendable { let comment: DanmakuComment; let lane: Int; let width: Double }
    let entries: [Entry]
    let duration: Double
    let lanes: Int
    init(comments: [DanmakuComment], width: Double, height: Double, fontSize: Double, area: Double, duration: Double) {
        self.duration = duration
        lanes = max(1, min(24, Int(max(0, height - 80) * area / (fontSize + 9))))
        var moving = [Entry?](repeating: nil, count: lanes)
        var fixed = [Double](repeating: -.infinity, count: lanes)
        var result: [Entry] = []
        for comment in comments {
            let length = comment.text.unicodeScalars.reduce(0.0) { $0 + ($1.value < 128 ? 0.62 : 1) }
            let textWidth = max(fontSize, length * fontSize) + 16
            if comment.mode == .scroll {
                if let lane = moving.indices.first(where: { index in
                    guard let previous = moving[index] else { return true }
                    let gap = comment.time - previous.comment.time
                    let oldSpeed = (width + previous.width) / duration
                    let speed = (width + textWidth) / duration
                    let cleared = gap * oldSpeed - previous.width
                    guard cleared > 24 else { return false }
                    return speed <= oldSpeed || cleared - (speed - oldSpeed) * max(0, duration - gap) > 24
                }) {
                    let entry = Entry(comment: comment, lane: lane, width: textWidth)
                    moving[lane] = entry; result.append(entry)
                }
            } else if let lane = fixed.indices.first(where: { fixed[$0] <= comment.time }) {
                fixed[lane] = comment.time + duration
                result.append(.init(comment: comment, lane: lane, width: textWidth))
            }
        }
        entries = result
    }
    func active(at time: Double) -> ArraySlice<Entry> {
        func lower(_ target: Double) -> Int {
            var lo = 0, hi = entries.count
            while lo < hi { let mid = (lo + hi) / 2; if entries[mid].comment.time < target { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        return entries[lower(time - duration)..<lower(time + 0.00001)]
    }
}

private enum DanmakuFontSize {
    static let defaultValue = 16.0

    static func normalized(_ value: Double) -> Double {
        value == 17 ? defaultValue : value
    }
}

struct DanmakuOverlay: View {
    let comments: [DanmakuComment]
    let time: Double
    let playing: Bool
    let rate: Double
    @AppStorage("lucent.danmaku.opacity") private var opacity = 0.8
    @AppStorage("lucent.danmaku.fontSize") private var savedFontSize = DanmakuFontSize.defaultValue
    @AppStorage("lucent.danmaku.area") private var area = 0.5
    @AppStorage("lucent.danmaku.duration") private var duration = 12.0
    @AppStorage("lucent.danmaku.offset") private var offset = 0.0
    @AppStorage("lucent.danmaku.blocked") private var blocked = ""
    @State private var layout: DanmakuLayout?
    @State private var anchorDate = Date()
    @State private var anchorTime: Double?

    private func displayTime(at date: Date) -> Double {
        guard playing else { return time }
        return (anchorTime ?? time) + max(0, date.timeIntervalSince(anchorDate)) * rate
    }

    private func syncClock(force: Bool = false) {
        let now = Date()
        guard force || anchorTime == nil || abs(displayTime(at: now) - time) > 0.12 else { return }
        anchorDate = now
        anchorTime = time
    }

    var body: some View {
        let fontSize = DanmakuFontSize.normalized(savedFontSize)
        GeometryReader { geometry in
            TimelineView(.animation(paused: !playing)) { frame in
                Canvas { context, size in
                    guard let layout else { return }
                    let clock = displayTime(at: frame.date) - offset
                    for entry in layout.active(at: clock) {
                        let comment = entry.comment
                        let progress = min(1, max(0, (clock - comment.time) / layout.duration))
                        let x = comment.mode == .scroll ? size.width - progress * (size.width + entry.width) : (size.width - entry.width) / 2
                        let top = 12.0 + Double(entry.lane) * (fontSize + 9)
                        let y = comment.mode == .bottom ? size.height - 100 - Double(entry.lane) * (fontSize + 9) : top
                        let color = Color(red: Double((comment.color >> 16) & 255) / 255,
                                          green: Double((comment.color >> 8) & 255) / 255,
                                          blue: Double(comment.color & 255) / 255)
                        let text = Text(comment.text).font(.system(size: fontSize, weight: .semibold)).foregroundColor(color)
                        var shadow = context
                        shadow.addFilter(.shadow(color: .black.opacity(0.9), radius: 1, x: 0, y: 1))
                        shadow.draw(text, at: CGPoint(x: x, y: y), anchor: .topLeading)
                    }
                }
            }
            .task(id: "\(geometry.size)|\(comments.count)|\(fontSize)|\(area)|\(duration)|\(blocked)") {
                let comments = self.comments, size = geometry.size
                let words = blocked.components(separatedBy: .newlines).filter { !$0.isEmpty }
                let font = fontSize, area = area, duration = duration
                let value = await Task.detached(priority: .userInitiated) {
                    DanmakuLayout(comments: comments.filter { comment in !words.contains { comment.text.localizedCaseInsensitiveContains($0) } },
                                  width: size.width, height: size.height, fontSize: font, area: area, duration: duration)
                }.value
                guard !Task.isCancelled else { return }; layout = value
            }
        }
        .onChange(of: time, initial: true) { _, _ in syncClock() }
        .onChange(of: playing) { _, _ in syncClock(force: true) }
        .onChange(of: rate) { _, _ in syncClock(force: true) }
        .opacity(opacity).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DanmakuSettingsView: View {
    @ObservedObject var model: DanmakuModel
    let item: MediaItem
    let close: () -> Void
    @AppStorage("lucent.danmaku.enabled") private var enabled = false
    @AppStorage("lucent.danmaku.opacity") private var opacity = 0.8
    @AppStorage("lucent.danmaku.fontSize") private var savedFontSize = DanmakuFontSize.defaultValue
    @AppStorage("lucent.danmaku.area") private var area = 0.5
    @AppStorage("lucent.danmaku.duration") private var duration = 12.0
    @AppStorage("lucent.danmaku.offset") private var offset = 0.0
    @AppStorage(CustomDanmakuServers.key) private var customServersData = Data()
    @AppStorage("lucent.danmaku.selectedServer") private var selectedServerID = "official"
    @State private var query = ""
    private var servers: [DandanplayClient.Server] {
        // 弹弹play 官方源仅在代码内置凭据已配置时展示。
        (DandanplayCredentials.isConfigured ? [.official] : [])
            + CustomDanmakuServers.available(customServersData)
    }
    private var selectedServer: DandanplayClient.Server? {
        servers.first(where: { $0.id == selectedServerID }) ?? servers.first
    }
    @State private var matches: [DandanplayClient.Episode] = []
    @State private var busy = false
    @State private var searched = false
    @State private var status: String?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                settingsSection("弹幕状态") {
                    Toggle("显示弹幕", isOn: $enabled)
                        .tint(.gray)
                    LabeledContent("当前来源", value: model.source == "未选择弹幕" ? "未选择弹幕".lucentLocalized : model.source)
                    if !model.comments.isEmpty { Button("移除此影片弹幕", role: .destructive) { model.clear(for: item.id) } }
                }
                settingsSection("手动匹配") {
                    settingsMenu("来源", value: servers.isEmpty ? "未配置" : selectedServer?.name ?? "未配置") {
                        Picker("来源", selection: $selectedServerID) {
                            ForEach(servers) { server in Text(server.name).tag(server.id) }
                        }
                    }.disabled(busy || servers.isEmpty)
                    TextField("影片或剧集名称", text: $query)
                        .submitLabel(.search)
                        .onSubmit { if query.count >= 2 && !busy { search() } }
                    Button("搜索弹幕", systemImage: "magnifyingglass") { search() }.disabled(query.count < 2 || busy)
                    if item.metadata != nil {
                        Button("按影片资料匹配当前集", systemImage: "sparkles") { search(precise: true) }.disabled(busy)
                    }
                    if busy { ProgressView() }
                    if let status { Text(LocalizedStringKey(status)).font(.footnote).foregroundStyle(.secondary) }
                    if searched && !busy && matches.isEmpty { Text("没有匹配结果，请尝试原文名称。 ").foregroundStyle(.secondary) }
                    ForEach(matches) { match in
                        Button {
                            busy = true; status = nil
                            Task {
                                defer { busy = false }
                                do {
                                    let data = try await DandanplayClient.comments(episodeID: match.id, server: match.server)
                                    try await model.installMatch(match, data: data, item: item)
                                    enabled = true; close()
                                } catch { status = DanmakuError.message(for: error) }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.anime).font(.system(size: PlayerControlStyle.scaled(14)))
                                Text(match.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(busy)
                    }

                }
                settingsSection("显示") {
                    displayPicker("不透明度", selection: $opacity, values: [0.2, 0.4, 0.6, 0.8, 1]) {
                        $0.formatted(.percent.precision(.fractionLength(0)))
                    }
                    displayPicker("字号", selection: Binding(
                        get: { DanmakuFontSize.normalized(savedFontSize) },
                        set: { savedFontSize = $0 }
                    ), values: [14, DanmakuFontSize.defaultValue, 20, 24, 28, 32, 36]) {
                        $0.formatted(.number.precision(.fractionLength(0...2)))
                    }
                    displayPicker("显示区域", selection: $area, values: [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1]) {
                        $0.formatted(.percent.precision(.fractionLength(0)))
                    }
                    displayPicker("滚动时长", selection: $duration, values: [4, 6, 8, 10, 12, 14]) {
                        $0.formatted(.number.precision(.fractionLength(0...2))) + " s"
                    }
                }
                settingsSection("时间同步") {
                    LabeledContent("时间偏移") {
                        HStack {
                            Button { offset = max(-120, offset - 0.5) } label: {
                                Image(systemName: "minus")
                            }
                            .accessibilityLabel("提前半秒")
                            .disabled(offset <= -120)
                            Text("\(offset.formatted(.number.precision(.fractionLength(1)))) 秒")
                                .monospacedDigit()
                            Button { offset = min(120, offset + 0.5) } label: {
                                Image(systemName: "plus")
                            }
                            .accessibilityLabel("延后半秒")
                            .disabled(offset >= 120)
                        }
                    }
                    Text("正值延后，负值提前。").font(.caption).foregroundStyle(.secondary)
                    Button("重置偏移") { offset = 0 }.disabled(offset == 0)
                }
            }
            .font(.system(size: PlayerControlStyle.scaled(13)))
            .padding(16)
        }
            .task {
                query = item.identity?.seriesName ?? item.metadata?.localizedTitle ?? item.title
                selectedServerID = selectedServer?.id ?? selectedServerID
            }
            .onChange(of: selectedServerID) { _, _ in matches = []; searched = false; status = nil }
            .onChange(of: customServersData) { _, _ in
                selectedServerID = selectedServer?.id ?? selectedServerID
                matches = []; searched = false; status = nil
            }
    }

    private func settingsSection<Content: View>(_ title: String?, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(LocalizedStringKey(title)).font(.system(size: PlayerControlStyle.scaled(12), weight: .semibold)).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 12, content: content)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 14))
        }
    }
    private func search(precise: Bool = false) {
        guard let endpoint = selectedServer else {
            status = "请先在设置的弹幕服务中配置自定义弹幕服务器。"
            return
        }
        busy = true; status = nil; matches = []
        Task {
            defer { busy = false }
            do {
                let episode: Int?
                if case .episode(_, _, let number, _) = item.identity { episode = number } else { episode = nil }
                let values = try await DandanplayClient.search(query,
                    tmdbID: precise ? item.metadata?.providerID : nil,
                    movie: item.identity?.seriesName == nil, episode: precise ? episode : nil, server: endpoint)
                guard endpoint == selectedServer, !Task.isCancelled else { return }
                matches = values
                searched = true
                if precise && matches.isEmpty { status = "资料未匹配到弹幕，可改用片名搜索后手动选集。" }
            }
            catch { status = DanmakuError.message(for: error) }
        }
    }
    private func displayPicker(_ title: LocalizedStringKey, selection: Binding<Double>,
                               values: [Double], format: @escaping (Double) -> String) -> some View {
        let current = selection.wrappedValue
        let options = values.contains(current) ? values : (values + [current]).sorted()
        return settingsMenu(title, value: format(current)) {
            Picker(title, selection: selection) {
                ForEach(options, id: \.self) { value in
                    Text(format(value)).tag(value)
                }
            }
        }
    }

    private func settingsMenu<Content: View>(_ title: LocalizedStringKey, value: String,
                                              @ViewBuilder content: () -> Content) -> some View {
        LabeledContent(title) {
            Menu(content: content) {
                Text(value)
                    .font(.system(size: PlayerControlStyle.scaled(13)))
                    .lineLimit(1)
            }
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(value))
        }
    }
}
