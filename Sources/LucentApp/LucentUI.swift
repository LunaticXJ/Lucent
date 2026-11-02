import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Shared semantic styles. Video overlays intentionally stay dark; ordinary pages follow appearance.
enum LucentUI {
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
                    .environment(\.colorScheme, .dark)
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
                .font(.caption.weight(.semibold)).monospacedDigit()
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
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 17, weight: .medium)).foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 9))
                .accessibilityHidden(true)
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
            Spacer(minLength: 6)
        }.frame(minHeight: LucentUI.controlSize).contentShape(Rectangle())
    }
}

struct LucentFormField<Content: View>: View {
    let title: String
    let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(LocalizedStringKey(title)).font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary).padding(.leading, 15)
            content.padding(.horizontal, 18).frame(minHeight: LucentUI.fieldHeight)
                .background(LucentUI.panel, in: Capsule())
        }
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
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 19, weight: .medium))
                .frame(width: LucentUI.controlSize, height: LucentUI.controlSize)
                .modifier(LucentGlass(shape: Circle(), role: role, interactive: true))
        }.buttonStyle(.plain).accessibilityLabel(LocalizedStringKey(label))
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
    var enabled = true
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                VStack(spacing: 2) {
                    Text(LocalizedStringKey(resumeTime == nil ? "开始播放" : "继续播放")).font(.headline)
                    if let resumeTime { Text("上次播放到：\(resumeTime)").font(.caption) }
                }
            }.padding(.vertical, 8).frame(maxWidth: 330, minHeight: 54)
                .foregroundStyle(.black).background(.white, in: Capsule())
        }.buttonStyle(.plain).disabled(!enabled).opacity(enabled ? 1 : 0.45)
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

struct LucentPosterCaption: View {
    let title: String
    var subtitle: String? = nil
    var lines = 2
    var reservesSpace = true
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
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
