import SwiftUI

/// Expands artwork into the scroll view's rubber-band space while keeping its top at y = 0.
struct StretchyHeroHeader<Content: View>: View {
    @Environment(\.displayScale) private var displayScale
    @State private var pull: CGFloat = 0
    let height: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            let artworkHeight = ((height + pull) * displayScale).rounded(.up) / displayScale
            content(artworkHeight, pull)
                .frame(width: proxy.size.width, height: artworkHeight, alignment: .top)
                .offset(y: -pull)
        }
        .frame(height: height)
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { proxy in
            // Deduplicate negative scrolling offsets: only rubber-band stretch affects layout.
            (max(0, proxy.frame(in: .scrollView(axis: .vertical)).minY) * displayScale).rounded() / displayScale
        } action: { pull = $0 }
        #endif
    }
}

/// Finish the fade before the artwork bounds so the shared page background
/// supplies the pixels on both sides of the scroll content boundary.
struct HeroArtworkFade: View {
    var body: some View {
        LinearGradient(stops: [
            .init(color: .black, location: 0.30),
            .init(color: .black.opacity(0.88), location: 0.50),
            .init(color: .black.opacity(0.42), location: 0.72),
            .init(color: .black.opacity(0.12), location: 0.88),
            .init(color: .clear, location: 0.96),
            .init(color: .clear, location: 1)
        ], startPoint: .top, endPoint: .bottom)
    }
}
