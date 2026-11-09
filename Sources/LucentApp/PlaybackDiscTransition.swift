import SwiftUI

private struct DiscTransitionLayout {
    let width: CGFloat
    let top: CGFloat

    var trayWidth: CGFloat { min(width * 0.30, 126) }
    var trayHeight: CGFloat { trayWidth + 12 }
    var diameter: CGFloat { trayWidth * 0.88 }
    var trayCenter: CGFloat { top + trayHeight * 0.53 }
    var discCenter: CGFloat { trayCenter + trayWidth * 1.15 }
}

private enum DiscMotion {
    static let handoff: CGFloat = 0.55

    static func page(_ progress: CGFloat) -> CGFloat {
        min(1, progress / handoff)
    }

    static func landing(_ progress: CGFloat) -> CGFloat {
        max(0, (progress - handoff) / (1 - handoff))
    }
}

nonisolated private struct DiscBackdrop: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        Color.black
            .opacity(Double(DiscMotion.page(progress)))
            .ignoresSafeArea()
    }
}

nonisolated private struct DiscTravel: AnimatableModifier {
    var progress: CGFloat
    let centerX: CGFloat
    let layout: DiscTransitionLayout
    var drawerOpen: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(progress, drawerOpen) }
        set {
            progress = newValue.first
            drawerOpen = newValue.second
        }
    }

    func body(content: Content) -> some View {
        let landing = DiscMotion.landing(progress)
        let retreat = (1 - drawerOpen) * layout.trayHeight
        return content
            .rotationEffect(.degrees((1 - landing) * -32))
            .scaleEffect((1.12 - landing * 0.12) * (0.45 + drawerOpen * 0.55))
            .opacity(Double(DiscMotion.page(progress)))
            .position(x: centerX,
                      y: layout.discCenter + (layout.trayCenter - layout.discCenter) * landing - retreat)
    }
}

private struct DiscPageMask: Shape {
    var progress: CGFloat
    let topOverflow: CGFloat

    func path(in bounds: CGRect) -> Path {
        guard progress > 0 else { return Path(bounds.insetBy(dx: -10_000, dy: -10_000)) }
        // The hero draws above its layout bounds, under the transparent navigation bar.
        let rect = CGRect(x: bounds.minX, y: bounds.minY - topOverflow,
                          width: bounds.width, height: bounds.height + topOverflow)
        let side = min(rect.width, rect.height)
        let width = rect.width + (side - rect.width) * progress
        let height = rect.height + (side - rect.height) * progress
        let bounds = CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
        return RoundedRectangle(cornerRadius: side * progress / 2).path(in: bounds)
    }
}

nonisolated private struct DiscPageMorph: AnimatableModifier {
    var progress: CGFloat
    let canvas: CGRect
    let pageFrame: CGRect
    let layout: DiscTransitionLayout

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        let progress = DiscMotion.page(progress)
        let topOverflow = pageFrame.isEmpty ? 0 : max(0, pageFrame.minY - canvas.minY)
        let pageCenter = CGPoint(x: pageFrame.midX, y: pageFrame.midY - topOverflow / 2)
        let discCenter = CGPoint(x: canvas.midX, y: canvas.minY + layout.discCenter)
        let side = max(1, min(pageFrame.width, pageFrame.height + topOverflow))
        let scale = 1 + (layout.diameter * 1.12 / side - 1) * progress
        return content
            .clipShape(DiscPageMask(progress: progress, topOverflow: topOverflow))
            .scaleEffect(scale)
            .offset(x: (discCenter.x - pageCenter.x) * progress,
                    y: (discCenter.y - pageCenter.y) * progress + (scale - 1) * topOverflow / 2)
            .opacity(1 - Double(progress))
    }
}

/// A lightweight optical-disc vignette. Does not snapshot or transform the video layer,
/// so HDR/Dolby Vision surfaces remain under their existing native presentation owner.
struct PlaybackDiscTransition: View {
    let item: MediaItem
    let inserting: Bool
    @Binding var progress: CGFloat
    let completed: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen: CGFloat = 0
    @State private var visibility = 0.0
    @State private var artwork: LucentPlatformImage?

    var body: some View {
        GeometryReader { geometry in
            let top = Self.islandBottom(fallback: geometry.safeAreaInsets.top)
            let layout = DiscTransitionLayout(width: geometry.size.width, top: top)
            let trayWidth = layout.trayWidth
            let trayHeight = layout.trayHeight
            let diameter = layout.diameter
            let retreat = (1 - drawerOpen) * trayHeight
            if reduceMotion {
                disc.frame(width: diameter, height: diameter)
                    .opacity(visibility)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            } else {
                ZStack(alignment: .top) {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(white: 0.065))
                        .overlay {
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                        }
                        .overlay {
                            Circle().fill(.black)
                                .overlay(Circle().strokeBorder(.white.opacity(0.12), lineWidth: 2))
                                .padding(9)
                        }
                        .overlay(alignment: .bottom) {
                            Capsule().fill(.white.opacity(0.35)).frame(width: 24, height: 2).padding(.bottom, 5)
                        }
                        .frame(width: trayWidth, height: trayHeight)
                        .scaleEffect(x: 0.45 + drawerOpen * 0.55, y: 1, anchor: .top)
                        .position(x: geometry.size.width / 2, y: top + trayHeight / 2 - retreat)
                    disc.frame(width: diameter, height: diameter)
                        .modifier(DiscTravel(progress: progress, centerX: geometry.size.width / 2,
                                             layout: layout, drawerOpen: drawerOpen))
                }
                .mask(alignment: .top) {
                    Rectangle().padding(.top, top)
                }
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        .task { await loadArtwork() }
        .task {
            do {
                if reduceMotion {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        progress = inserting ? 1 : 0
                        visibility = 1
                    }
                    try await Task.sleep(for: .milliseconds(160))
                    withAnimation(.easeInOut(duration: 0.15)) { visibility = 0 }
                    try await Task.sleep(for: .milliseconds(160))
                } else {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { drawerOpen = 1 }
                    try await Task.sleep(for: .milliseconds(420))
                    withAnimation(.easeInOut(duration: 0.62)) { progress = inserting ? 1 : 0 }
                    try await Task.sleep(for: .milliseconds(620))
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { drawerOpen = 0 }
                    try await Task.sleep(for: .milliseconds(420))
                }
                try Task.checkCancellation()
                completed()
            } catch { return }
        }
    }

    private func loadArtwork() async {
        let current = library.items.first { $0.id == item.id } ?? item
        if let url = library.posterURL(for: current), let image = LucentPlatformImage(contentsOf: url) {
            artwork = image
            return
        }
        var request: URLRequest?
        var cacheKey: String?
        switch current.location {
        case .embyItem(let sourceID, let itemID):
            if let source = library.embySources.first(where: { $0.id == sourceID }),
               let token = try? KeychainPasswordStore.embyToken(for: sourceID) {
                // Reuse the home poster's disk and decoded cache before fetching.
                for width in [525, 1800] {
                    if let cached = ArtworkImageDecoder.cachedImage(key: "\(sourceID)|\(itemID)|false", maximumPixelSize: width) {
                        artwork = cached; return
                    }
                }
                request = EmbyClient.posterRequest(source: source, token: token, itemID: itemID)
                cacheKey = "emby|\(sourceID)|\(itemID)|false|350"
            }
        case .jellyfinItem(let sourceID, let itemID):
            if let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
               let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID) {
                request = JellyfinClient.posterRequest(source: source, token: token, itemID: itemID)
            }
        case .plexItem(let sourceID, _, _):
            if let source = library.plexSources.first(where: { $0.id == sourceID }),
               let thumb = current.serverPosterKey,
               let token = try? KeychainPasswordStore.plexToken(for: sourceID) {
                request = PlexClient.posterRequest(source: source, token: token, thumb: thumb)
            }
        default: break
        }
        if request == nil, let url = current.metadata?.posterURL {
            request = URLRequest(url: url)
            cacheKey = "tmdb|\(url.absoluteString)"
        }
        guard var request, let url = request.url else { return }
        request.timeoutInterval = 2
        let imageRequest = request
        let key = cacheKey ?? "disc|\(current.id)|\(url.path)"
        guard let data = try? await LocalMediaCache.shared.imageData(key: key, fetch: {
            let (data, response) = try await URLSession.shared.data(for: imageRequest)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { throw URLError(.badServerResponse) }
            return data
        }), !Task.isCancelled else { return }
        artwork = await ArtworkImageDecoder.image(data: data, key: key, maximumPixelSize: 400)
    }

    fileprivate static func islandBottom(fallback: CGFloat) -> CGFloat {
        #if os(iOS)
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }?.windows.first { $0.isKeyWindow }
        return max(12, (window?.safeAreaInsets.top ?? fallback) - 8)
        #else
        return max(12, fallback)
        #endif
    }
    private var disc: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.gray, .white, .cyan.opacity(0.5), .gray, .white, .gray], center: .center))
            GeometryReader { geometry in
                if let artwork {
                    Image(lucentImage: artwork).resizable().scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipped()
                } else {
                    Text(item.catalogDisplayTitle).font(.caption2.bold()).multilineTextAlignment(.center)
                        .foregroundStyle(.black).padding(14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.clipShape(Circle()).padding(3)
            Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2)
            Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1).padding(5)
            Circle().fill(.white.opacity(0.6)).frame(width: 22, height: 22)
            Circle().fill(Color(white: 0.08)).frame(width: 10, height: 10)
            Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1).frame(width: 12, height: 12)
        }.clipShape(Circle()).shadow(color: .black.opacity(0.25), radius: 15, y: 8)
    }
}

private struct DiscPageMorphKey: EnvironmentKey {
    static let defaultValue: DiscPageMorph? = nil
}

private extension EnvironmentValues {
    var discPageMorph: DiscPageMorph? {
        get { self[DiscPageMorphKey.self] }
        set { self[DiscPageMorphKey.self] = newValue }
    }
}

private struct DetailDiscPageSurface: ViewModifier {
    @Environment(\.discPageMorph) private var morph
    @State private var frame = CGRect.zero

    func body(content: Content) -> some View {
        content
            .modifier(DiscPageMorph(progress: morph?.progress ?? 0, canvas: morph?.canvas ?? .zero,
                                    pageFrame: frame, layout: morph?.layout ?? DiscTransitionLayout(width: 0, top: 0)))
            .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frame = $0 }
    }
}

private struct DiscPlaybackControlsHiddenKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var discPlaybackControlsHidden: Bool {
        get { self[DiscPlaybackControlsHiddenKey.self] }
        set { self[DiscPlaybackControlsHiddenKey.self] = newValue }
    }
}

private struct DiscPlaybackPresentation<Destination: View>: ViewModifier {
    @Binding var requested: MediaItem?
    let destination: (MediaItem) -> Destination
    let usesDetailSurface: Bool
    @AppStorage("lucent.playback.discTransition") private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented: MediaItem?
    @State private var playbackCoverVisible = false
    @State private var disc: MediaItem?
    @State private var inserting = true
    @State private var pageProgress: CGFloat = 0
    @State private var canvas = CGRect.zero
    @State private var pageFrame = CGRect.zero
    @State private var lastItem: MediaItem?
    @State private var revealTask: Task<Void, Never>?
    @State private var portraitLayoutReady = false

    func body(content: Content) -> some View {
        let layout = DiscTransitionLayout(width: canvas.width, top: PlaybackDiscTransition.islandBottom(fallback: 0))
        let morph = DiscPageMorph(progress: reduceMotion ? 0 : pageProgress, canvas: canvas,
                                  pageFrame: pageFrame, layout: layout)
        ZStack {
            if controlsHidden { DiscBackdrop(progress: pageProgress) }
            Group {
                if usesDetailSurface {
                    content
                } else {
                    content.modifier(morph)
                }
            }
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { pageFrame = $0 }
                .opacity(reduceMotion ? 1 - Double(pageProgress) : 1)
                .environment(\.discPageMorph, usesDetailSurface ? morph : nil)
                .environment(\.discPlaybackControlsHidden, controlsHidden)
                .allowsHitTesting(disc == nil)
        }
            #if os(iOS)
            .navigationBarBackButtonHidden(controlsHidden)
            #endif
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.frame(in: .global), initial: true) { _, frame in
                        canvas = frame
                        portraitLayoutReady = frame.width > 0 && frame.height > frame.width
                    }
                }
                .ignoresSafeArea()
            }
            .overlay {
                if let disc {
                    PlaybackDiscTransition(item: disc, inserting: inserting, progress: $pageProgress) {
                        self.disc = nil
                        if inserting, let requested { present(requested) }
                    }.id(inserting ? "disc-in" : "disc-out")
                }
            }
            .lucentPlaybackPresentation(isPresented: $playbackCoverVisible, onDismiss: reveal) {
                ZStack {
                    Color.black.ignoresSafeArea()
                    if let presented { destination(presented).id(presented.id) }
                }
                #if os(iOS)
                .onAppear { LucentOrientationDelegate.setPlaybackPresented(true) }
                #endif
            }
            .onChange(of: requested?.id, initial: true) { _, id in
                guard id != nil, let requested else { return }
                revealTask?.cancel()
                lastItem = requested
                if presented != nil || !animatesDisc { present(requested); return }
                guard disc == nil else { return }
                inserting = true; disc = requested
            }
    }
    private var animatesDisc: Bool {
        #if os(tvOS)
        false // Apple TV has no Dynamic Island; use the native fullscreen presentation.
        #else
        enabled
        #endif
    }
    private var controlsHidden: Bool { disc != nil || presented != nil || pageProgress > 0 }

    private func present(_ item: MediaItem) {
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) {
            presented = item
            playbackCoverVisible = true
        }
    }
    #if os(iOS)
    private func portraitSceneIsSettled() -> Bool {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }),
              scene.interfaceOrientation == .portrait,
              let window = scene.windows.first(where: { $0.isKeyWindow }),
              window.bounds.height > window.bounds.width,
              let root = window.rootViewController else { return false }
        // UIKit retains a coordinator while the rotation/dismissal is in flight.
        var controllers = [root]
        while let controller = controllers.popLast() {
            if controller.transitionCoordinator != nil { return false }
            controllers.append(contentsOf: controller.children)
            if let presented = controller.presentedViewController { controllers.append(presented) }
        }
        return true
    }
    #endif

    private func reveal() {
        requested = nil
        presented = nil
        #if os(iOS)
        LucentOrientationDelegate.setPlaybackPresented(false)
        #endif
        guard animatesDisc, let lastItem else { pageProgress = 0; return }
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                // A rotation request is asynchronous. Never fall through on a timer
                // while the scene or the actual detail canvas is still landscape.
                var stablePortraitFrames = 0
                while stablePortraitFrames < 3 {
                    guard !Task.isCancelled else { return }
                    stablePortraitFrames = portraitLayoutReady && portraitSceneIsSettled() ? stablePortraitFrames + 1 : 0
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
            #endif
            guard !Task.isCancelled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageProgress = 1
                inserting = false
                disc = lastItem
            }
        }
    }
}

extension View {
    func discPlaybackCover<Destination: View>(item: Binding<MediaItem?>, usesDetailSurface: Bool = false,
        @ViewBuilder content: @escaping (MediaItem) -> Destination) -> some View {
        modifier(DiscPlaybackPresentation(requested: item, destination: content, usesDetailSurface: usesDetailSurface))
    }

    func detailDiscPageSurface() -> some View {
        modifier(DetailDiscPageSurface())
    }
}
