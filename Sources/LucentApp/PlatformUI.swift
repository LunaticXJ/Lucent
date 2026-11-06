import SwiftUI
#if os(macOS)
import AppKit
typealias LucentPlatformImage = NSImage
#else
import UIKit
typealias LucentPlatformImage = UIImage
#endif

extension Image {
    init(lucentImage: LucentPlatformImage) {
        #if os(macOS)
        self.init(nsImage: lucentImage)
        #else
        self.init(uiImage: lucentImage)
        #endif
    }
}

enum LucentClipboard {
    static func copy(_ text: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #elseif os(iOS)
        UIPasteboard.general.string = text
        #endif
    }
}

extension View {
    @ViewBuilder func lucentHideTopScrollEdge() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) { scrollEdgeEffectHidden(true, for: .top) }
        else { self }
        #else
        self
        #endif
    }

    @ViewBuilder func lucentTabRoot() -> some View {
        #if os(iOS)
        toolbar(.visible, for: .tabBar)
        #else
        self
        #endif
    }
    /// Navigation destinations own tab visibility; roots explicitly restore visibility after popping.
    @ViewBuilder func lucentSecondaryPage() -> some View {
        #if os(iOS)
        toolbar(.hidden, for: .tabBar)
        #else
        self
        #endif
    }

    @ViewBuilder func lucentNavigationTitleStyle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func lucentTextInput() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }
    @ViewBuilder func lucentURLInput() -> some View {
        #if os(iOS)
        keyboardType(.URL)
        #else
        self
        #endif
    }
    @ViewBuilder func lucentTimeInput() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }
    @ViewBuilder func lucentDirectoryListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.automatic)
        #endif
    }
    @ViewBuilder func lucentSelectableText() -> some View {
        #if os(tvOS)
        self
        #else
        textSelection(.enabled)
        #endif
    }
}

/// Remote-friendly value selection uses the same persisted binding as touch/keyboard sliders.
struct LucentValueSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.05
    var body: some View {
        #if os(tvOS)
        HStack {
            Button("减小", systemImage: "minus") { value = max(range.lowerBound, value - step) }
            Text(value.formatted(.number.precision(.fractionLength(0...2)))).monospacedDigit()
            Button("增大", systemImage: "plus") { value = min(range.upperBound, value + step) }
        }
        #else
        Slider(value: $value, in: range, step: step)
        #endif
    }
}

#if !os(iOS)
struct HomeMatchedSource: ViewModifier {
    let key: String
    let namespace: Namespace.ID
    func body(content: Content) -> some View { content }
}

struct NativePlaybackInputSettings: View {
    @AppStorage("lucent.player.seekInterval") private var interval = 10.0
    var body: some View {
        Form {
            Section("播放控制") {
                Picker("快进 / 快退间隔", selection: $interval) {
                    ForEach([5.0, 10, 15, 30], id: \.self) { Text("\(Int($0)) 秒").tag($0) }
                }
                #if os(macOS)
                LabeledContent("播放 / 暂停", value: "空格")
                LabeledContent("快退 / 快进", value: "← / →")
                LabeledContent("关闭面板 / 返回", value: "Esc")
                #else
                LabeledContent("播放 / 暂停", value: "遥控器播放键")
                LabeledContent("选择控件", value: "方向键与确认键")
                LabeledContent("返回", value: "遥控器返回键")
                #endif
            }
        }.modifier(LucentSettingsPageStyle()).navigationTitle("播放控制")
    }
}
#endif

@MainActor enum LucentDisplay {
    static var maximumArtworkPixels: Int {
        #if os(macOS)
        Int((NSScreen.main?.frame.width ?? 1440) * (NSScreen.main?.backingScaleFactor ?? 2))
        #else
        Int(UIScreen.main.bounds.width * UIScreen.main.scale)
        #endif
    }
}
#if !os(macOS)
extension UIImage {
    convenience init?(contentsOf url: URL) { self.init(contentsOfFile: url.path) }
}
#endif
extension View {
    @ViewBuilder func lucentContentButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.card)
        #else
        buttonStyle(.plain)
        #endif
    }
    @ViewBuilder func lucentFullScreen<Destination: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Destination) -> some View {
        #if os(macOS)
        sheet(isPresented: isPresented) { content().frame(minWidth: 800, minHeight: 600) }
        #else
        fullScreenCover(isPresented: isPresented, content: content)
        #endif
    }
    @ViewBuilder func lucentSeasonPicker<Destination: View>(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> Destination) -> some View {
        #if os(tvOS)
        sheet(isPresented: isPresented) {
            NavigationStack { content().toolbar { Button("完成") { isPresented.wrappedValue = false } } }
        }
        #else
        popover(isPresented: isPresented, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { content() }
        #endif
    }
}

extension View {
    @ViewBuilder func lucentPlaybackPresentation<Destination: View>(item: Binding<MediaItem?>,
        onDismiss: @escaping () -> Void, @ViewBuilder content: @escaping (MediaItem) -> Destination) -> some View {
        #if os(macOS)
        sheet(item: item, onDismiss: onDismiss) { content($0).frame(minWidth: 1000, minHeight: 600) }
        #else
        fullScreenCover(item: item, onDismiss: onDismiss, content: content)
        #endif
    }
}

extension View {
    @ViewBuilder func lucentScrollBackgroundHidden() -> some View {
        #if os(tvOS)
        self
        #else
        scrollContentBackground(.hidden)
        #endif
    }
}

struct LucentDisclosure<Content: View, Label: View>: View {
    @ViewBuilder let content: () -> Content
    @ViewBuilder let label: () -> Label
    @State private var expanded = false
    var body: some View {
        #if os(tvOS)
        VStack(alignment: .leading, spacing: 16) {
            Button { expanded.toggle() } label: {
                HStack { label(); Spacer(); Image(systemName: expanded ? "chevron.up" : "chevron.down") }
            }
            if expanded { content() }
        }
        #else
        DisclosureGroup(content: content, label: label)
        #endif
    }
}

#if !os(iOS)
/// Scope sleep prevention to active playback and release it when the player leaves.
@MainActor final class NativePlaybackActivity: ObservableObject {
    #if os(macOS)
    private var activity: NSObjectProtocol?
    #else
    private var previousIdleTimer: Bool?
    #endif
    func update(playing: Bool) {
        #if os(macOS)
        if playing, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleDisplaySleepDisabled], reason: "Lucent 正在播放影片")
        } else if !playing, let activity {
            ProcessInfo.processInfo.endActivity(activity); self.activity = nil
        }
        #else
        if playing {
            if previousIdleTimer == nil { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
            UIApplication.shared.isIdleTimerDisabled = true
        } else if let previousIdleTimer {
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimer; self.previousIdleTimer = nil
        }
        #endif
    }
}
#endif

/// Capture the initial midpoint once, then move with the title content.
struct LucentPosterLoadingIndicator: View {
    #if os(iOS)
    @State private var safeTop: CGFloat?
    #else
    private let safeTop: CGFloat? = 0
    #endif
    @State private var initialTitleTop: CGFloat?
    @State private var initialOffset: CGFloat?
    var body: some View {
        GeometryReader { title in
            ProgressView()
                .accessibilityLabel("正在加载海报")
                .position(x: title.size.width / 2, y: initialOffset ?? 0)
                .opacity(initialOffset == nil ? 0 : 1)
                .onAppear {
                    if initialTitleTop == nil { initialTitleTop = title.frame(in: .global).minY }
                    resolveInitialOffset()
                }
                .onChange(of: safeTop) { _, _ in resolveInitialOffset() }
        }
        .allowsHitTesting(false)
        #if os(iOS)
        .background(PosterSafeAreaAnchor { safeTop = $0 }.frame(width: 0, height: 0))
        #endif
    }
    private func resolveInitialOffset() {
        guard initialOffset == nil, let initialTitleTop, let safeTop else { return }
        initialOffset = (safeTop - initialTitleTop) / 2
    }
}

#if os(iOS)
private struct PosterSafeAreaAnchor: UIViewRepresentable {
    let changed: (CGFloat) -> Void
    func makeUIView(context: Context) -> Anchor { Anchor(changed: changed) }
    func updateUIView(_ view: Anchor, context: Context) { view.changed = changed; view.report() }
    final class Anchor: UIView {
        var changed: (CGFloat) -> Void
        private var last: CGFloat?
        init(changed: @escaping (CGFloat) -> Void) { self.changed = changed; super.init(frame: .zero); isUserInteractionEnabled = false }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); report() }
        override func safeAreaInsetsDidChange() { super.safeAreaInsetsDidChange(); report() }
        override func layoutSubviews() { super.layoutSubviews(); report() }
        func report() {
            guard let window else { return }
            let top = window.safeAreaInsets.top
            guard last != top else { return }
            last = top
            DispatchQueue.main.async { [weak self] in self?.changed(top) }
        }
    }
}
#endif

extension View {
    @ViewBuilder func lucentPlayerButtonStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.bordered)
        #else
        buttonStyle(.plain)
        #endif
    }
}

extension View {
    /// Allows the remote focus engine to scroll informational shelves without fake buttons.
    @ViewBuilder func lucentReadableFocus() -> some View {
        #if os(tvOS)
        focusable().accessibilityElement(children: .combine)
        #else
        self
        #endif
    }
}

extension View {
    @ViewBuilder func lucentPlaybackHorizontalPadding() -> some View {
        #if os(tvOS)
        padding(.horizontal, LucentUI.pageInset)
        #else
        padding(.horizontal)
        #endif
    }
}

extension View {
    @ViewBuilder func lucentFormActionStyle() -> some View {
        #if os(tvOS)
        buttonStyle(.automatic)
        #else
        buttonStyle(.plain)
        #endif
    }
    @ViewBuilder func lucentHierarchicalPresentation<Destination: View>(isPresented: Binding<Bool>,
        onDismiss: @escaping () -> Void, @ViewBuilder destination: @escaping () -> Destination) -> some View {
        #if os(tvOS)
        navigationDestination(isPresented: isPresented, destination: destination)
            .onChange(of: isPresented.wrappedValue) { wasPresented, presented in
                if wasPresented && !presented { onDismiss() }
            }
        #else
        sheet(isPresented: isPresented, onDismiss: onDismiss, content: destination)
        #endif
    }
}
