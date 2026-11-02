import SwiftUI
import UniformTypeIdentifiers

@MainActor final class DanmakuModel: ObservableObject {
    @Published private(set) var comments: [DanmakuComment] = []
    @Published private(set) var source = "未选择弹幕"
    @Published private(set) var revision = UUID()
    @Published var status: String?
    private var generation = UUID()
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
        guard generation == request, !Task.isCancelled else { return }
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

struct DanmakuOverlay: View {
    let comments: [DanmakuComment]
    let time: Double
    let playing: Bool
    let rate: Double
    @AppStorage("lucent.danmaku.opacity") private var opacity = 0.8
    @AppStorage("lucent.danmaku.fontSize") private var fontSize = 22.0
    @AppStorage("lucent.danmaku.area") private var area = 0.5
    @AppStorage("lucent.danmaku.duration") private var duration = 8.0
    @AppStorage("lucent.danmaku.offset") private var offset = 0.0
    @AppStorage("lucent.danmaku.blocked") private var blocked = ""
    @State private var layout: DanmakuLayout?
    @State private var anchorDate = Date()

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playing)) { frame in
                Canvas { context, size in
                    guard let layout else { return }
                    let advance = playing ? min(0.5, max(0, frame.date.timeIntervalSince(anchorDate))) * rate : 0
                    let clock = time + advance - offset
                    for entry in layout.active(at: clock) {
                        let comment = entry.comment
                        let progress = min(1, max(0, (clock - comment.time) / layout.duration))
                        let x = comment.mode == .scroll ? size.width - progress * (size.width + entry.width) : (size.width - entry.width) / 2
                        let top = 36.0 + Double(entry.lane) * (fontSize + 9)
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
        .onChange(of: time) { _, _ in anchorDate = Date() }
        .onChange(of: playing) { _, _ in anchorDate = Date() }
        .opacity(opacity).allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct DanmakuSettingsView: View {
    @ObservedObject var model: DanmakuModel
    let item: MediaItem
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lucent.danmaku.enabled") private var enabled = false
    @AppStorage("lucent.danmaku.opacity") private var opacity = 0.8
    @AppStorage("lucent.danmaku.fontSize") private var fontSize = 22.0
    @AppStorage("lucent.danmaku.area") private var area = 0.5
    @AppStorage("lucent.danmaku.duration") private var duration = 8.0
    @AppStorage("lucent.danmaku.offset") private var offset = 0.0
    @AppStorage("lucent.danmaku.blocked") private var blocked = ""
    @State private var query = ""
    @State private var matches: [DandanplayClient.Episode] = []
    @State private var busy = false
    @State private var searched = false
    @State private var status: String?
    @State private var importer = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示弹幕", isOn: $enabled)
                    LabeledContent("当前来源", value: model.source)
                    #if !os(tvOS)
                    Button("从文件导入", systemImage: "folder.badge.plus") { importer = true }.disabled(busy)
                    #endif
                    if !model.comments.isEmpty { Button("移除此影片弹幕", role: .destructive) { model.clear(for: item.id) } }
                }
                Section("在线匹配 · 弹弹play") {
                    TextField("影片或剧集名称", text: $query).submitLabel(.search).onSubmit { search() }
                    Button("搜索匹配的剧集", systemImage: "magnifyingglass") { search() }.disabled(query.count < 2 || busy)
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
                                    let data = try await DandanplayClient.comments(episodeID: match.id)
                                    try await model.install(data: data, source: "弹弹play · \(match.anime) · \(match.title)", itemID: item.id)
                                    enabled = true; dismiss()
                                } catch { status = error.localizedDescription }
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.anime).font(.subheadline)
                                Text(match.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }.disabled(busy)
                    }
                    NavigationLink("服务配置") { PlaybackServicesView() }
                }
                Section("显示") {
                    slider("不透明度", value: $opacity, range: 0.2...1, formatted: "\(Int(opacity * 100))%")
                    slider("字号", value: $fontSize, range: 14...36, formatted: "\(Int(fontSize))")
                    Picker("显示区域", selection: $area) {
                        Text("上方四分之一").tag(0.25); Text("上半屏").tag(0.5); Text("全屏").tag(1.0)
                    }
                    slider("滚动时长", value: $duration, range: 4...14, formatted: "\(Int(duration)) 秒")
                    LucentValueSlider(value: $offset, range: -120...120, step: 0.5)
                    Text("时间偏移：\(offset.formatted(.number.precision(.fractionLength(1)))) 秒")
                    Text("正值延后，负值提前。 ").font(.caption).foregroundStyle(.secondary)
                }
                Section("屏蔽词 · 每行一个") {
                    #if os(tvOS)
                    TextField("屏蔽词", text: $blocked)
                    #else
                    TextEditor(text: $blocked).frame(minHeight: 80)
                    #endif
                }
            }
            .navigationTitle("弹幕").lucentNavigationTitleStyle()
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { query = item.identity?.seriesName ?? item.metadata?.localizedTitle ?? item.title }
            #if !os(tvOS)
            .fileImporter(isPresented: $importer, allowedContentTypes: [.xml, .json]) { result in
                Task {
                    do {
                        let url = try result.get(), scoped = url.startAccessingSecurityScopedResource()
                        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size > 0, size <= DanmakuParser.maximumBytes else { throw DanmakuError.invalidFile }
                        let data = try Data(contentsOf: url)
                        try await model.install(data: data, source: url.lastPathComponent, itemID: item.id)
                        enabled = true; dismiss()
                    } catch { status = error.localizedDescription }
                }
            }
            #endif
        }
    }
    private func search(precise: Bool = false) {
        busy = true; status = nil; matches = []
        Task {
            defer { busy = false }
            do {
                let episode: Int?
                if case .episode(_, _, let number, _) = item.identity { episode = number } else { episode = nil }
                matches = try await DandanplayClient.search(query,
                    tmdbID: precise ? item.metadata?.providerID : nil,
                    movie: item.identity?.seriesName == nil, episode: precise ? episode : nil)
                searched = true
                if precise && matches.isEmpty { status = "资料未匹配到弹幕，可改用片名搜索后手动选集。" }
            }
            catch { status = error.localizedDescription }
        }
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, formatted: String) -> some View {
        VStack {
            HStack { Text(title); Spacer(); Text(formatted).foregroundStyle(.secondary) }
            LucentValueSlider(value: value, range: range, step: 0.05)
        }.padding(.vertical, 3)
    }
}
