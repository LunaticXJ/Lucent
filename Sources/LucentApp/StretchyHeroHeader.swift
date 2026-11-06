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
