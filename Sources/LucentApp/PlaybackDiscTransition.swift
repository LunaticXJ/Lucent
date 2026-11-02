import SwiftUI

/// A lightweight optical-disc vignette. Does not snapshot or transform the video layer,
/// so HDR/Dolby Vision surfaces remain under their existing native presentation owner.
struct PlaybackDiscTransition: View {
    let item: MediaItem
    let inserting: Bool
    let completed: () -> Void
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var progress = 0.0
    @State private var artwork: LucentPlatformImage?

    var body: some View {
        GeometryReader { geometry in
            let diameter = min(geometry.size.width * 0.78, 340)
            let value = inserting ? progress : 1 - progress
            let x = geometry.size.width / 2 + (geometry.size.width * 0.36) * value
            let y = geometry.size.height / 2 - (geometry.size.height * 0.40) * value
            disc
                .frame(width: diameter, height: diameter)
                .rotationEffect(.degrees(reduceMotion ? 0 : value * 210))
                .scaleEffect(reduceMotion ? 1 : 1 - value * 0.86)
                .opacity(inserting ? (progress > 0.9 ? (1 - progress) * 10 : 1) : min(1, (1 - progress) * 4))
                .position(x: reduceMotion ? geometry.size.width / 2 : x,
                          y: reduceMotion ? geometry.size.height / 2 : y)
        }
        .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
        .task {
            if let url = library.posterURL(for: item) { artwork = LucentPlatformImage(contentsOf: url) }
            else if let url = item.metadata?.posterURL,
                    let data = try? await LocalMediaCache.shared.imageData(key: "tmdb|\(url.absoluteString)", fetch: {
                        let (data, response) = try await URLSession.shared.data(from: url)
                        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { throw URLError(.badServerResponse) }
                        return data
                    }) {
                artwork = LucentPlatformImage(data: data)
            }
        }
        .task {
            let duration = reduceMotion ? 0.18 : 0.62
            withAnimation(.easeInOut(duration: duration)) { progress = 1 }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard !Task.isCancelled else { return }; completed()
        }
    }
    private var disc: some View {
        ZStack {
            Circle().fill(AngularGradient(colors: [.gray, .white, .cyan.opacity(0.5), .gray, .white, .gray], center: .center))
            if let artwork { Image(lucentImage: artwork).resizable().scaledToFill().clipShape(Circle()).padding(6).opacity(0.82) }
            Circle().strokeBorder(.white.opacity(0.7), lineWidth: 2)
            Circle().strokeBorder(.black.opacity(0.25), lineWidth: 1).padding(5)
            Circle().fill(.white.opacity(0.6)).frame(width: 44, height: 44)
            Circle().fill(Color(white: 0.08)).frame(width: 20, height: 20)
            Circle().strokeBorder(.white.opacity(0.8), lineWidth: 1).frame(width: 23, height: 23)
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

    func body(content: Content) -> some View {
        content
            .opacity(pageOpacity)
            .allowsHitTesting(disc == nil)
            .overlay {
                if let disc {
                    PlaybackDiscTransition(item: disc, inserting: inserting) {
                        self.disc = nil
                        if inserting, let requested { present(requested) }
                    }.id(inserting ? "disc-in" : "disc-out")
                }
            }
            .lucentPlaybackPresentation(item: $presented, onDismiss: reveal) { item in destination(item) }
            .onChange(of: requested?.id, initial: true) { _, id in
                guard id != nil, let requested else { return }
                lastItem = requested
                if presented != nil || !enabled { present(requested); return }
                guard disc == nil else { return }
                inserting = true; disc = requested
                withAnimation(.easeInOut(duration: reduceMotion ? 0.18 : 0.55)) { pageOpacity = 0 }
            }
    }
    private func present(_ item: MediaItem) {
        #if os(iOS)
        LucentOrientationDelegate.setPlaybackPresented(true)
        #endif
        var transaction = Transaction(animation: nil); transaction.disablesAnimations = true
        withTransaction(transaction) { presented = item }
    }
    private func reveal() {
        requested = nil
        #if os(iOS)
        LucentOrientationDelegate.setPlaybackPresented(false)
        #endif
        guard enabled, let lastItem else { pageOpacity = 1; return }
        revealTask?.cancel()
        revealTask = Task { @MainActor in
            #if os(iOS)
            if UIDevice.current.userInterfaceIdiom == .phone {
                for _ in 0..<60 {
                    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
                    if scene?.interfaceOrientation.isPortrait == true { break }
                    do { try await Task.sleep(for: .milliseconds(16)) } catch { return }
                }
            }
            #endif
            guard !Task.isCancelled else { return }
            inserting = false; disc = lastItem
            withAnimation(.easeInOut(duration: reduceMotion ? 0.18 : 0.62)) { pageOpacity = 1 }
        }
    }
}

extension View {
    func discPlaybackCover<Destination: View>(item: Binding<MediaItem?>,
        @ViewBuilder content: @escaping (MediaItem) -> Destination) -> some View {
        modifier(DiscPlaybackPresentation(requested: item, destination: content))
    }
}
