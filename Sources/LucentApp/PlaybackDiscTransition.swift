import SwiftUI

/// A lightweight optical-disc vignette. Does not snapshot or transform the video layer,
/// so HDR/Dolby Vision surfaces remain under their existing native presentation owner.
struct PlaybackDiscTransition: View {
    let item: MediaItem
    let inserting: Bool
    var movementStarted: () -> Void = {}
    let completed: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = 0.0
    @State private var landing = 0.0
    @State private var visibility = 0.0
    @State private var artwork: LucentPlatformImage?

    var body: some View {
        GeometryReader { geometry in
            let trayWidth = min(geometry.size.width * 0.30, 126)
            let trayHeight = trayWidth + 12
            let diameter = trayWidth * 0.88
            let top = islandBottom(fallback: geometry.safeAreaInsets.top)
            let trayCenter = top + trayHeight * 0.53
            let startY = trayCenter + trayWidth * 1.15
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
                        .rotationEffect(.degrees((1 - landing) * -32))
                        .scaleEffect((1.12 - landing * 0.12) * (0.45 + drawerOpen * 0.55))
                        .opacity(visibility)
                        .position(x: geometry.size.width / 2,
                                  y: startY + (trayCenter - startY) * landing - retreat)
                }
                .mask(alignment: .top) {
                    Rectangle().padding(.top, top)
                }
            }
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        .task {
            await loadArtwork()
            guard !Task.isCancelled else { return }
            if reduceMotion {
                withAnimation(.easeInOut(duration: 0.15)) {
                    if inserting { movementStarted() }
                    visibility = 1
                }
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
                withAnimation(.easeInOut(duration: 0.15)) {
                    if !inserting { movementStarted() }
                    visibility = 0
                }
                do { try await Task.sleep(for: .milliseconds(160)) } catch { return }
            } else {
                landing = inserting ? 0 : 1
                visibility = inserting ? 0 : 1
                // Entry opens briskly and flows straight into landing; exit keeps
                // its longer ejection beat so the loaded disc remains perceptible.
                withAnimation(.spring(response: inserting ? 0.30 : 0.44,
                                      dampingFraction: inserting ? 0.74 : 0.68)) { drawerOpen = 1 }
                do { try await Task.sleep(for: .milliseconds(inserting ? 340 : 580)) } catch { return }
                withAnimation(.easeInOut(duration: 0.42)) {
                    movementStarted()
                    landing = inserting ? 1 : 0
                    visibility = inserting ? 1 : 0
                }
                do { try await Task.sleep(for: .milliseconds(420)) } catch { return }
                withAnimation(.spring(response: 0.36, dampingFraction: 0.74)) { drawerOpen = 0 }
                do { try await Task.sleep(for: .milliseconds(480)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            completed()
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

    private func islandBottom(fallback: CGFloat) -> CGFloat {
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

private struct DiscPlaybackPresentation<Destination: View>: ViewModifier {
    @Binding var requested: MediaItem?
    let destination: (MediaItem) -> Destination
    @AppStorage("lucent.playback.discTransition") private var enabled = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var presented: MediaItem?
    @State private var disc: MediaItem?
    @State private var inserting = true
    @State private var pageOpacity = 1.0
    @State private var lastItem: MediaItem?
    @State private var revealTask: Task<Void, Never>?
    @State private var portraitLayoutReady = false

    func body(content: Content) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()
            content.opacity(pageOpacity)
                .allowsHitTesting(disc == nil)
        }
            .background {
                GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size, initial: true) { _, size in
                        portraitLayoutReady = size.width > 0 && size.height > size.width
                    }
                }
            }
            .overlay {
                if let disc {
                    PlaybackDiscTransition(item: disc, inserting: inserting, movementStarted: {
                        // Shares the disc movement's animation transaction and exact duration.
                        pageOpacity = inserting ? 0 : 1
                    }) {
                        self.disc = nil
                        if inserting, let requested { present(requested) }
                    }.id(inserting ? "disc-in" : "disc-out")
                }
            }
            .lucentPlaybackPresentation(item: $presented, onDismiss: reveal) { item in destination(item) }
            .onChange(of: requested?.id, initial: true) { _, id in
                guard id != nil, let requested else { return }
                revealTask?.cancel()
                lastItem = requested
                if presented != nil || !enabled { present(requested); return }
                guard disc == nil else { return }
                inserting = true; disc = requested
            }
    }
    private func present(_ item: MediaItem) {
        #if os(iOS)
        LucentOrientationDelegate.setPlaybackPresented(true)
        #endif
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { presented = item }
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
        #if os(iOS)
        LucentOrientationDelegate.setPlaybackPresented(false, forceUpdate: true)
        #endif
        guard enabled, let lastItem else { pageOpacity = 1; return }
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
                pageOpacity = 0
                inserting = false
                disc = lastItem
            }
        }
    }
}

extension View {
    func discPlaybackCover<Destination: View>(item: Binding<MediaItem?>,
        @ViewBuilder content: @escaping (MediaItem) -> Destination) -> some View {
        modifier(DiscPlaybackPresentation(requested: item, destination: content))
    }
}
