import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared semantic styles. Video overlays intentionally stay dark; ordinary pages follow appearance.
enum LucentUI {
    #if os(tvOS)
    static let libraryColumnCount = 6
    static let libraryOverviewColumnCount = 4
    static let sourceContentWidth: CGFloat = 1600
    static let detailContentWidth: CGFloat = 1400
    static let detailHeroContentWidth: CGFloat = 960
    static let detailTitleWidth: CGFloat = 460
    static let detailTitleHeight: CGFloat = 170
    #else
    static let libraryColumnCount = 3
    static let libraryOverviewColumnCount = 2
    static let sourceContentWidth: CGFloat = 1100
    static let detailContentWidth: CGFloat = 780
    static let detailHeroContentWidth: CGFloat = 660
    static let detailTitleWidth: CGFloat = 250
    static let detailTitleHeight: CGFloat = 100
    #endif
    static let posterAspectRatio: CGFloat = 2.0 / 3.0
    #if os(tvOS)
    static let controlSize: CGFloat = 72
    static let fieldHeight: CGFloat = 80
    static let pageInset: CGFloat = 60
    static let cardRadius: CGFloat = 20
    static let sectionRadius: CGFloat = 28
    #else
    static let controlSize: CGFloat = 44
    static let fieldHeight: CGFloat = 52
    static let pageInset: CGFloat = 20
    static let cardRadius: CGFloat = 14
    static let sectionRadius: CGFloat = 22
    #endif
    static func detailSize(_ value: CGFloat) -> CGFloat {
        #if os(tvOS)
        value * 1.6
        #else
        value
        #endif
    }
    static var mediaInfoCardHeight: CGFloat? {
        #if os(tvOS)
        nil
        #else
        365
        #endif
    }
    static let switchTint = Color(red: 0.16, green: 0.72, blue: 0.39)
    static let selectionTint = Color.gray
    static let ratingTint = Color.yellow
    static var page: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color("AppBackground")
        #endif
    }
    static var panel: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #elseif os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color.primary.opacity(0.08)
        #endif
    }
}

enum LucentSurfaceRole: Equatable { case standard, videoOverlay }
struct LucentGlass<Surface: InsettableShape>: ViewModifier {
    let shape: Surface
    var role: LucentSurfaceRole = .standard
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(role == .videoOverlay ? Color(white: 0.12) : LucentUI.panel, in: shape)
                .overlay(shape.strokeBorder(role == .videoOverlay ? Color.white.opacity(0.14) : Color.primary.opacity(0.12)))
        } else if #available(iOS 26, macOS 26, tvOS 26, *) {
            if role == .videoOverlay {
                content.glassEffect(.regular.tint(.black.opacity(0.42)).interactive(interactive), in: shape)
            } else { content.glassEffect(.regular.interactive(interactive), in: shape) }
        } else {
            if role == .videoOverlay {
                content.background(.regularMaterial, in: shape)
                    .overlay(shape.strokeBorder(.white.opacity(0.12)))
            } else { content.background(.regularMaterial, in: shape) }
        }
    }
}

struct LucentArtworkPlaceholder: View {
    var symbol = "film"
    var showsSymbol = true
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(colors: scheme == .dark ? [Color(white: 0.12), Color(white: 0.18)] : [Color(white: 0.94), Color(white: 0.87)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            if showsSymbol {
                Image(systemName: symbol).font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.secondary).accessibilityHidden(true)
            }
        }.accessibilityHidden(true)
    }
}

struct LucentRatingBadge: View {
    let rating: Double
    var body: some View {
        if rating.isFinite && rating > 0 {
            Text(rating.formatted(.number.precision(.fractionLength(1))))
                .font(.caption2.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.white).padding(.horizontal, 5).padding(.vertical, 3)
                .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 5))
                .accessibilityLabel(Text("评分 \(rating.formatted(.number.precision(.fractionLength(1))))"))
        }
    }
}

struct LucentCountBadge: View {
    let count: Int
    var body: some View {
        if count > 0 {
            Text(String(count)).font(.caption.weight(.semibold)).monospacedDigit()
                .foregroundStyle(.white).padding(.horizontal, 6).frame(minHeight: 22)
                .background(Color(red: 0.02, green: 0.57, blue: 0.94), in: Capsule())
        }
    }
}

struct LucentLoadingView: View {
    var title: String? = nil
    var body: some View {
        Group {
            if let title { ProgressView(LocalizedStringKey(title)) }
            else { ProgressView() }
        }.accessibilityLabel(Text(LocalizedStringKey(title ?? "正在加载")))
    }
}

struct LucentStateView: View {
    let title: String
    var symbol = "tray"
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some View {
        ContentUnavailableView {
            Label(LocalizedStringKey(title), systemImage: symbol)
        } description: {
            if let message { Text(LocalizedStringKey(message)) }
        } actions: {
            if let actionTitle, let action { Button(LocalizedStringKey(actionTitle), action: action).buttonStyle(.bordered) }
        }
    }
}

struct LucentSettingsPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.lucentScrollBackgroundHidden()
            .environment(\.defaultMinListRowHeight, LucentUI.controlSize)
            .background(LucentUI.page).tint(.gray)
            #if os(iOS)
            .listSectionSpacing(.compact)
            #endif
            #if !os(tvOS)
            .toggleStyle(SwitchToggleStyle(tint: LucentUI.switchTint))
            #endif
            #if os(macOS)
            .formStyle(.grouped)
            #endif
    }
}

struct LucentSettingsRow: View {
    let title: String
    let icon: String
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.system(size: LucentUI.controlSize == 72 ? 28 : 17, weight: .medium)).foregroundStyle(.primary)
                .frame(width: LucentUI.controlSize == 72 ? 36 : 24, height: LucentUI.controlSize == 72 ? 36 : 24)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title)).font(.body).foregroundStyle(.primary)
            Spacer(minLength: 6)
        }.padding(.vertical, 4).contentShape(Rectangle())
    }
}

struct LucentFormField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    @ViewBuilder var body: some View {
        #if os(tvOS)
        LabeledContent(LocalizedStringKey(title)) { content }
        #else
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary).padding(.leading, 15)
            content.padding(.horizontal, 18).frame(minHeight: LucentUI.fieldHeight)
                .background(LucentUI.panel, in: Capsule())
        }
        #endif
    }
}

struct LucentPasswordInput: View {
    @Binding var text: String
    @Binding var visible: Bool
    let placeholder: String
    var body: some View {
        HStack {
            Group {
                if visible { TextField(LocalizedStringKey(placeholder), text: $text) }
                else { SecureField(LocalizedStringKey(placeholder), text: $text) }
            }.textContentType(.password).lucentTextInput().autocorrectionDisabled()
            Button { visible.toggle() } label: {
                Image(systemName: visible ? "eye.slash" : "eye").foregroundStyle(.secondary)
                    .frame(minWidth: LucentUI.controlSize, minHeight: LucentUI.controlSize)
            }.buttonStyle(.plain).accessibilityLabel(visible ? "隐藏密码" : "显示密码")
        }
    }
}

struct LucentToolbarButton: View {
    let symbol: String
    let label: String
    var role: LucentSurfaceRole = .standard
    let action: () -> Void
    @ViewBuilder var body: some View {
        if #available(iOS 26, macOS 26, tvOS 26, *) {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.regular)
            .buttonSizing(.flexible)
            .frame(width: LucentUI.controlSize, height: LucentUI.controlSize)
            .accessibilityLabel(LocalizedStringKey(label))
        } else {
            Button(action: action) {
                Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                    .frame(width: LucentUI.controlSize, height: LucentUI.controlSize)
                    .modifier(LucentGlass(shape: Circle(), role: role, interactive: true))
            }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(label))
        }
    }
}

struct LucentSheetToolbar: ToolbarContent {
    let close: () -> Void
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("关闭", systemImage: "xmark", action: close)
        }
        ToolbarItem(placement: .confirmationAction) {
            if let actionTitle, let action { Button(LocalizedStringKey(actionTitle), action: action) }
        }
    }
}

struct LucentSynopsisSheet: View {
    let title: String
    let text: String
    let close: () -> Void
    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text).font(.body).lineSpacing(6).lucentSelectableText()
                    .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            }.navigationTitle(title).lucentNavigationTitleStyle()
                .toolbar { LucentSheetToolbar(close: close, actionTitle: "复制") { LucentClipboard.copy(text) } }
        }.modifier(LucentSheetStyle(role: .reader))
    }
}

struct LucentSkeleton: View {
    var radius: CGFloat = 12
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(LinearGradient(colors: scheme == .dark
                ? [.white.opacity(0.07), .white.opacity(0.14), .white.opacity(0.07)]
                : [.black.opacity(0.04), .black.opacity(0.08), .black.opacity(0.04)],
                startPoint: .topLeading, endPoint: .bottomTrailing)).accessibilityHidden(true)
    }
}

struct LucentRemoteArtwork: View {
    let request: URLRequest?
    let cacheKey: String
    var maximumPixels = 600
    var symbol = "film"
    @State private var image: LucentPlatformImage?
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LucentArtworkPlaceholder(symbol: symbol, showsSymbol: image == nil)
                if let image {
                    Image(lucentImage: image).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height).clipped()
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped().accessibilityHidden(true)
            .task(id: "\(cacheKey)|\(request?.url?.absoluteString ?? "")") {
                image = nil
                guard let request, let url = request.url else { return }
                let data: Data?
                if url.isFileURL {
                    data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                } else {
                    data = try? await LocalMediaCache.shared.imageData(key: cacheKey) {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw URLError(.badServerResponse) }
                        return data
                    }
                }
                guard let data, !Task.isCancelled else { return }
                let decoded = await ArtworkImageDecoder.image(data: data, key: cacheKey, maximumPixelSize: maximumPixels)
                guard !Task.isCancelled else { return }
                image = decoded
            }
    }
}

struct LucentPlayButton: View {
    var resumeTime: String? = nil
    var episodeLabel: String? = nil
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                ZStack {
                    // Reserve the same two-line height while centering the visible label.
                    VStack(spacing: 2) {
                        Text("开始播放").font(.headline)
                        Text(" ").font(.caption)
                    }
                    .hidden().accessibilityHidden(true)
                    VStack(spacing: 2) {
                    Text(LocalizedStringKey(resumeTime == nil ? "开始播放" : "继续播放")).font(.headline)
                    if let episodeLabel {
                        Text(resumeTime.map { "\(episodeLabel) \($0)" } ?? episodeLabel)
                            .font(.caption).monospacedDigit()
                    } else if let resumeTime {
                        Text("上次播放到：\(resumeTime)").font(.caption)
                    }
                    }
                }
            }
        }.lucentNativeGlassButton(expands: true)
            .frame(maxWidth: LucentUI.controlSize == 72 ? 560 : 330, minHeight: LucentUI.controlSize == 72 ? 88 : 54)
            .disabled(!enabled).opacity(enabled ? 1 : 0.45)
    }
}

struct LucentEditorToolbar: ToolbarContent {
    let actionTitle: String
    var busy = false
    var canSave = true
    let close: () -> Void
    let save: () -> Void
    var body: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(action: close) { Image(systemName: "chevron.left") }.accessibilityLabel("返回").disabled(busy)
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(LocalizedStringKey(actionTitle), action: save).disabled(busy || !canSave)
        }
    }
}

struct LucentSheetStyle: ViewModifier {
    enum Role { case reader, editor }
    let role: Role
    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content.presentationDetents(role == .reader ? [.medium, .large] : [.large])
            .presentationDragIndicator(.visible)
        #endif
    }
}

/// Shared geometry for media-library and favorites poster cards.
struct LucentCatalogPosterLayout<Artwork: View, Caption: View>: View {
    @ViewBuilder var artwork: () -> Artwork
    @ViewBuilder var caption: () -> Caption
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            artwork()
            caption()
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

struct LucentPosterCaption: View {
    let title: String
    var subtitle: String? = nil
    var lines = 2
    var reservesSpace = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.primary)
                .lineLimit(lines, reservesSpace: reservesSpace).frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

extension View {
    /// Semantic shorthand for video controls and drawers, with one glass implementation.
    func lucentVideoGlass(radius: CGFloat = 100) -> some View {
        modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), role: .videoOverlay))
    }
}

/// Collection titles and actions are owned by the system navigation bar.
private struct LucentCollectionChrome<Trailing: View>: ViewModifier {
    let title: String
    let trailing: Trailing
    @ViewBuilder func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationTitle(LocalizedStringKey(title))
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(false)
            .toolbar(.visible, for: .navigationBar)
            .toolbarRole(.navigationStack)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { trailing } }
        #else
        content.navigationTitle(LocalizedStringKey(title))
            .toolbar { ToolbarItem(placement: .primaryAction) { trailing } }
        #endif
    }
}

extension View {
    func lucentCollectionChrome<Trailing: View>(title: String,
        @ViewBuilder trailing: () -> Trailing) -> some View {
        modifier(LucentCollectionChrome(title: title, trailing: trailing()))
    }
}

/// Elapsed / total for both local and server-backed continue-watching cards.
struct LucentPlaybackTimeCaption: View {
    let position: Double
    let duration: Double?
    var onArtwork = false
    private var total: Double? { duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } }
    private var elapsed: String { clock(min(max(0, position.isFinite ? position : 0), total ?? .greatestFiniteMagnitude)) }
    var body: some View {
        Group {
            if let total { Text("\(elapsed) / \(clock(total))") }
            else { Text("已播放 \(elapsed)") }
        }
        .font(.caption2).monospacedDigit()
        .foregroundStyle(onArtwork ? Color.white : Color.secondary).lineLimit(1)
    }
    private func clock(_ value: Double) -> String {
        let seconds = Int(min(max(0, value), Double(Int.max / 2)))
        if seconds >= 3600 { return "\(seconds / 3600):" + String(format: "%02d:%02d", seconds / 60 % 60, seconds % 60) }
        return "\(seconds / 60):" + String(format: "%02d", seconds % 60)
    }
}

struct LucentPlaybackProgressOverlay: View {
    let position: Double
    let duration: Double?
    var progress: Double? = nil
    private var fraction: Double {
        if let progress, progress.isFinite { return min(1, max(0, progress)) }
        guard let duration, duration.isFinite, duration > 0, position.isFinite else { return 0 }
        return min(1, max(0, position / duration))
    }
    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            LucentPlaybackTimeCaption(position: position, duration: duration, onArtwork: true)
                .frame(maxWidth: .infinity, alignment: .trailing)
            ProgressView(value: fraction).tint(.white)
        }
        .padding(10)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.65)], startPoint: .top, endPoint: .bottom))
        .allowsHitTesting(false)
    }
}

struct LucentCircularMenu<Content: View>: View {
    var role: LucentSurfaceRole = .standard
    @ViewBuilder let content: () -> Content
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var body: some View {
        if #available(iOS 26, macOS 26, tvOS 26, *) {
            nativeMenu
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .controlSize(.regular)
                .frame(width: LucentUI.controlSize, height: LucentUI.controlSize)
            } else {
            nativeMenu
                .buttonStyle(.plain)
                .frame(width: LucentUI.controlSize, height: LucentUI.controlSize)
                .modifier(LucentGlass(shape: Circle(), role: role))
        }
    }
    private var nativeMenu: some View {
        Menu(content: content) {
            Image(systemName: "ellipsis")
                .font(.system(size: 19, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .accessibilityLabel("更多")
    }
}

/// Metadata updates stay within the visible card rather than invalidating the enclosing homepage.
struct LucentCatalogCaption: View {
    let title: String
    let yearText: String?
    var source: EmbySource? = nil
    var item: JellyfinItem? = nil
    @State private var detail: JellyfinItem?
    var body: some View {
        LucentPosterCaption(title: title, subtitle: detail?.displayYearText ?? yearText ?? " ", lines: 1)
            .task(id: "\(source?.id.uuidString ?? "")|\(item?.id ?? "")") {
                guard let source, let item, ["Movie", "Series", "Episode"].contains(item.type),
                      item.displayYear == nil,
                      let token = try? KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else { return }
                let key = "\(source.id)|\(source.baseAddress)|\(source.userID)|\(item.id)"
                if let cached = CatalogCaptionCache.entries[key], Date().timeIntervalSince(cached.0) < 300 {
                    detail = cached.1
                    return
                }
                let loaded = try? await ServerDetailClient.item(baseAddress: source.baseAddress,
                    userID: source.userID, itemID: item.id, token: token)
                guard !Task.isCancelled else { return }
                detail = loaded
                if let loaded {
                    if CatalogCaptionCache.entries.count >= 256 {
                        CatalogCaptionCache.entries = CatalogCaptionCache.entries.filter { Date().timeIntervalSince($0.value.0) < 300 }
                        if CatalogCaptionCache.entries.count >= 256 { CatalogCaptionCache.entries.removeAll() }
                    }
                    CatalogCaptionCache.entries[key] = (Date(), loaded)
                }
            }
    }
}

@MainActor private enum CatalogCaptionCache {
    static var entries: [String: (Date, JellyfinItem)] = [:]
}

enum DetailPosterPalette {
    static func lightColor(from image: LucentPlatformImage) -> Color {
        let fallback = Color(red: 0.94, green: 0.95, blue: 0.96)
        #if os(macOS)
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return fallback }
        #else
        guard let cgImage = image.cgImage else { return fallback }
        #endif
        let width = 24, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return fallback
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        var bins = [Double](repeating: 0, count: 512)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Int(pixels[index]), g = Int(pixels[index + 1]), b = Int(pixels[index + 2])
            let high = max(r, g, b), low = min(r, g, b)
            guard high >= 28, low <= 225, pixels[index + 3] >= 128 else { continue }
            let bin = ((r >> 5) << 6) | ((g >> 5) << 3) | (b >> 5)
            bins[bin] += 0.2 + Double(high - low) / 255
        }
        guard let best = bins.indices.max(by: { bins[$0] < bins[$1] }), bins[best] > 0 else { return fallback }
        let values = [Double((best >> 6) & 7), Double((best >> 3) & 7), Double(best & 7)]
        let peak = max(values.max() ?? 0, 1)
        let light = values.map { (218 + $0 / peak * 24) / 255 }
        return Color(red: light[0], green: light[1], blue: light[2])
    }
}

extension View {
    @ViewBuilder func lucentGlassScrollSurface() -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, *) {
            self.scrollClipDisabled().scrollEdgeEffectHidden(true, for: .all)
        } else {
            self.scrollClipDisabled()
        }
    }
}

extension View {
    @ViewBuilder func lucentNativeGlassButton(circle: Bool = false, expands: Bool = false) -> some View {
        if #available(iOS 26, macOS 26, tvOS 26, *) {
            self.buttonStyle(.glass)
                .buttonBorderShape(circle ? .circle : .capsule)
                .controlSize(.small)
                .buttonSizing(expands ? .flexible : .fitted)
        } else if circle {
            self.buttonStyle(.plain).modifier(LucentGlass(shape: Circle(), interactive: true))
        } else {
            self.buttonStyle(.plain).modifier(LucentGlass(shape: Capsule(), interactive: true))
        }
    }
}

struct LucentArtworkSizing: ViewModifier {
    var stretches = false
    @ViewBuilder func body(content: Content) -> some View {
        if stretches { content } else { content.scaledToFill() }
    }
}
