import SwiftUI

/// Expands artwork into the scroll view's rubber-band space while keeping its top at y = 0.
struct StretchyHeroHeader<Content: View>: View {
    let height: CGFloat
    @ViewBuilder let content: (CGFloat, CGFloat) -> Content

    var body: some View {
        GeometryReader { proxy in
            // Global window coordinates keep the artwork's top fixed at the physical screen edge.
            #if os(iOS)
            let pull = max(0, proxy.frame(in: .global).minY)
            #else
            let pull: CGFloat = 0
            #endif
            content(height + pull, pull)
                .frame(width: proxy.size.width, height: height + pull, alignment: .top)
                .offset(y: -pull)
        }
        .frame(height: height)
    }
}
