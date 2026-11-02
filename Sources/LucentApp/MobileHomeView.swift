#if os(iOS)
import SwiftUI
import UIKit
import Combine

struct HomeMatchedSource: ViewModifier {
    let key: String
    let namespace: Namespace.ID

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.matchedTransitionSource(id: key, in: namespace)
        } else {
            content
        }
    }
}

@MainActor
private enum HomePalette {
    static let background = Color(red: 0.055, green: 0.071, blue: 0.094)
    static let ink = Color.primary
    static let muted = Color.secondary
    static let isPad = UIDevice.current.userInterfaceIdiom == .pad
    static let inset: CGFloat = isPad ? 42 : 20
    static let continueWidth: CGFloat = isPad ? 285 : 185
    static let categoryWidth: CGFloat = isPad ? 250 : 165
    static let posterWidth: CGFloat = isPad ? 160 : 105
    static let sectionSpacing: CGFloat = isPad ? 38 : 30
}

private struct EmbyArtwork: View {
    let source: EmbySource
    let itemID: String
    let backdrop: Bool
    let width: Int
    var preferredURL: URL? = nil
    var softenBottom = false
    var onImage: ((UIImage) -> Void)? = nil
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LucentArtworkPlaceholder(symbol: backdrop ? "film.stack" : "film", showsSymbol: image == nil)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .overlay {
                        if softenBottom {
                            Image(uiImage: image).resizable().scaledToFill()
                                .blur(radius: 30)
                                .mask(LinearGradient(stops: [
                                    .init(color: .clear, location: 0.48),
                                    .init(color: .white.opacity(0.35), location: 0.68),
                                    .init(color: .white, location: 0.92)
                                ], startPoint: .top, endPoint: .bottom))
                        }
                    }
            }
        }
        .clipped()
        .task(id: "\(source.id)|\(itemID)|\(backdrop)|\(preferredURL?.absoluteString ?? "")") {
            image = nil
            let local = HomeSnapshotCache.localItems[itemID]
            let localPath = backdrop ? (local?.metadata?.backdropPath ?? local?.metadata?.posterPath) : local?.metadata?.posterPath
            let resolvedURL = preferredURL ?? localPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") }
            if let preferredURL = resolvedURL,
               let data = try? await LocalMediaCache.shared.imageData(
                   key: "tmdb|\(preferredURL.absoluteString)", fetch: {
                       let (data, response) = try await URLSession.shared.data(from: preferredURL)
                       guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
                       else { throw URLError(.badServerResponse) }
                       return data
                   }),
               let loaded = await ArtworkImageDecoder.image(data: data, key: preferredURL.absoluteString, maximumPixelSize: backdrop ? width : Int(Double(width) * 1.5)) {
                guard !Task.isCancelled else { return }
                image = loaded
                onImage?(loaded)
                return
            }
            guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                  !token.isEmpty else { return }
            for useBackdrop in backdrop ? [true, false] : [false] {
                guard let data = try? await LocalMediaCache.shared.imageData(
                    key: "emby|\(source.id)|\(itemID)|\(useBackdrop)|\(width)", fetch: {
                        try await EmbyClient.artwork(source: source, token: token,
                            itemID: itemID, backdrop: useBackdrop, maxWidth: width)
                    }),
                      let loaded = await ArtworkImageDecoder.image(data: data, key: "\(source.id)|\(itemID)|\(useBackdrop)", maximumPixelSize: backdrop ? width : Int(Double(width) * 1.5)) else { continue }
                guard !Task.isCancelled else { return }
                image = loaded
                onImage?(loaded)
                break
            }
        }
    }
}

private struct HomeShelf: Identifiable, Sendable {
    let view: MediaCard
    let items: [MediaCard]
    var id: String { view.id }
}

private struct HeroColors: Equatable { let dark: Color; let light: Color }

@MainActor private enum HomeSnapshotCache {
    struct Snapshot {
        let refreshID: UUID
        let loadedAt: Date
        let views: [MediaCard]
        let latest: [MediaCard]
        let continuing: [MediaCard]
        let continuingTotal: Int
        let shelves: [HomeShelf]
    }
    static var entries: [UUID: Snapshot] = [:]
    static var artworkLanguage = LocalizationPreferences.current.contentID
    static var artworks: [UUID: [String: TMDBService.DetailArtwork]] = [:]
    static var details: [UUID: [String: MediaCard]] = [:]
    static var themes: [UUID: [String: HeroColors]] = [:]
    static var selectedHeroIDs: [UUID: String] = [:]
    static var heroProgress: [UUID: Double] = [:]
    // Presentation-only context. Never persisted, authenticated or sent to a server.
    static let localContext = EmbySource(baseAddress: "", userID: "local")
    static var localItems: [String: MediaItem] = [:]
    static func trim(validSources: Set<UUID>) {
        let expired = entries.filter { !validSources.contains($0.key) || Date().timeIntervalSince($0.value.loadedAt) >= lifetime }.map(\.key)
        for id in expired { evict(id) }
        for id in entries.sorted(by: { $0.value.loadedAt > $1.value.loadedAt }).dropFirst(6).map(\.key) { evict(id) }
        let valid = Set(entries.keys)
        artworks = artworks.filter { valid.contains($0.key) }
        details = details.filter { valid.contains($0.key) }
        themes = themes.filter { valid.contains($0.key) }
        selectedHeroIDs = selectedHeroIDs.filter { validSources.contains($0.key) }
        heroProgress = heroProgress.filter { validSources.contains($0.key) }
    }
    static func evict(_ id: UUID) {
        entries[id] = nil; artworks[id] = nil; details[id] = nil; themes[id] = nil
    }
    static func releaseRebuildable() {
        entries.removeAll(); artworks.removeAll(); details.removeAll(); themes.removeAll(); localItems.removeAll()
    }
    static let lifetime: TimeInterval = 24 * 60 * 60
}

private struct HomeBrowserRoute: Identifiable, Hashable {
    let source: EmbySource
    let parentID: String?
    let title: String?
    var id: String { "\(source.id)|\(parentID ?? "root")" }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Waits for a clear direction before the enclosing scroll view can claim a hero swipe.
private final class HeroDirectionalPanGestureRecognizer: UIGestureRecognizer {
    private var startPoint: CGPoint?
    private(set) var horizontalTranslation: CGFloat = 0

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard touches.count == 1, let touch = touches.first, let view else {
            state = .failed
            return
        }
        startPoint = touch.location(in: view)
        horizontalTranslation = 0
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let startPoint, let touch = touches.first, let view else { return }
        let point = touch.location(in: view)
        let dx = point.x - startPoint.x
        let dy = point.y - startPoint.y
        horizontalTranslation = dx

        if state == .possible {
            if abs(dx) >= 16, abs(dx) > abs(dy) * 1.15 {
                state = .began
            } else if abs(dy) >= 38, abs(dy) > abs(dx) * 1.15 {
                state = .failed
            }
        } else if state == .began || state == .changed {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        state = state == .began || state == .changed ? .ended : .failed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        state = state == .began || state == .changed ? .cancelled : .failed
    }

    override func reset() {
        super.reset()
        startPoint = nil
        horizontalTranslation = 0
    }
}

private final class HeroGestureView: UIView {
    var horizontalPan: HeroDirectionalPanGestureRecognizer?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let horizontalPan else { return }
        var ancestor = superview
        while let view = ancestor {
            if let scrollView = view as? UIScrollView {
                scrollView.panGestureRecognizer.require(toFail: horizontalPan)
                break
            }
            ancestor = view.superview
        }
    }
}

private struct HeroGestureSurface: UIViewRepresentable {
    let onDrag: (CGFloat) -> Void
    let onEnd: (CGFloat) -> Void
    let onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(owner: self) }

    func makeUIView(context: Context) -> UIView {
        let view = HeroGestureView()
        view.backgroundColor = .clear
        let pan = HeroDirectionalPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        pan.cancelsTouchesInView = true
        view.addGestureRecognizer(pan)
        view.horizontalPan = pan
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap))
        tap.require(toFail: pan)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.owner = self }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var owner: HeroGestureSurface
        init(owner: HeroGestureSurface) { self.owner = owner }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            // Do not let the vertical scroll view move while a carousel pan is active.
            false
        }

        @objc func pan(_ recognizer: HeroDirectionalPanGestureRecognizer) {
            let translation = recognizer.horizontalTranslation
            switch recognizer.state {
            case .began, .changed: owner.onDrag(translation)
            case .ended, .cancelled, .failed: owner.onEnd(translation)
            default: break
            }
        }

        @objc func tap() { owner.onTap() }
    }
}

struct MobileHomeView: View {
    @Environment(\.appTheme) private var appTheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var systemColorScheme
    @AppStorage("lucent.home.autoplay") private var heroAutoplay = true
    @AppStorage(PlaybackProgressPolicy.minimumKey) private var minimumResumePercent = 5.0
    @AppStorage(PlaybackProgressPolicy.completionKey) private var completedPercent = 90.0
    @EnvironmentObject private var library: LibraryStore
    let showSources: () -> Void
    var preferredSourceID: UUID?
    var localLibrary = false
    var onCollectionChange: (Bool) -> Void = { _ in }
    let refreshID: UUID
    var showCacheSettings: () -> Void = {}
    @Binding var detailPresented: Bool
    var onScrollStateChange: (Bool) -> Void = { _ in }

    @State private var views: [MediaCard] = []
    @State private var latest: [MediaCard] = []
    @State private var continuing: [MediaCard] = []
    @State private var continuingTotal = 0
    @State private var shelves: [HomeShelf] = []
    @State private var isLoading = false
    @State private var hasLoadedHome = false
    @State private var localHomeGeneration = UUID()
    @State private var errorMessage: String?
    @State private var selectedItemID: UUID?
    @Namespace private var detailTransition
    @State private var selectedTransitionKey: String?
    @State private var browserRoute: HomeBrowserRoute?
    @State private var localCollection: LocalCatalogCollection?
    @State private var showAllContinuing = false
    @Environment(\.contentLocalizationID) private var contentLocalizationID
    @State private var heroArtworks: [String: TMDBService.DetailArtwork] = [:]
    @State private var heroDetails: [String: MediaCard] = [:]
    @State private var heroThemes: [String: HeroColors] = [:]
    @State private var heroIndex = 0
    @State private var indicatorIndex = 0
    @State private var outgoingHeroIndex: Int?
    @State private var heroReveal = 0.0
    @State private var heroForward = true
    @State private var heroTransitioning = false
    @State private var heroPauseUntil = Date.distantPast
    @State private var heroProgress = 0.0
    @State private var heroCycleStartedAt: Date?
    @State private var heroCycleStartProgress = 0.0
    @State private var heroIsVisible = false
    @State private var selectedTheme: HeroColors?
    @State private var heroDragX: CGFloat = 0
    @State private var heroDragTarget: Int?
    @State private var dockGestureHandled = false
    private var darkMode: Bool { appTheme.isDark(system: systemColorScheme) }
    private var fallbackTheme: Color {
        darkMode ? HomePalette.background : Color(red: 0.94, green: 0.95, blue: 0.96)
    }
    private var themeColor: Color {
        guard let selectedTheme else { return fallbackTheme }
        return darkMode ? selectedTheme.dark : selectedTheme.light
    }

    /// Use the same color transaction for the page and every poster's bottom gradient.
    /// Retain the current palette until the next image has actually been sampled.
    private func transitionHeroTheme(to id: String) {
        guard let colors = heroThemes[id], selectedTheme != colors else { return }
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.85)) {
            selectedTheme = colors
        }
    }

    private var source: EmbySource? {
        if localLibrary { return HomeSnapshotCache.localContext }
        return library.embySources.first { $0.id == preferredSourceID } ?? library.embySources.first
    }

    var body: some View {
        GeometryReader { viewport in
        ScrollView {
            if hasLoadedHome {
            VStack(alignment: .leading, spacing: 0) {
                if !latest.isEmpty {
                    StretchyHeroHeader(height: HomePalette.isPad ? 650 : max(460, viewport.size.height * 0.76)) { height, pull in
                        if latest.indices.contains(heroIndex) {
                            transitionSource(hero(height: height, pull: pull),
                                             key: "hero:\(latest[heroIndex].id)")
                        }
                    }
                    .frame(width: viewport.size.width)
                }
                LazyVStack(alignment: .leading, spacing: HomePalette.sectionSpacing) {
                    if latest.isEmpty {
                        HStack {
                            Text("首页").font(.title2.bold())
                        }
                    }
                    if let errorMessage {
                        Text(errorMessage)
                            .font(.subheadline)
                            .foregroundStyle(HomePalette.muted)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 18)))
                    }
                    if !continuing.isEmpty { continueSection }
                    if !views.isEmpty { mediaSection }
                    ForEach(shelves) { shelf in posterSection(shelf) }
                    if latest.isEmpty && !isLoading && source != nil && errorMessage == nil {
                        Text("暂无推荐影片，进入片源浏览全部内容。")
                            .foregroundStyle(HomePalette.muted)
                    }
                }
                .padding(.top, latest.isEmpty ? (HomePalette.isPad ? 76 : 66) : (HomePalette.isPad ? 30 : 20))
                .padding(.bottom, 56)
            }
            .frame(width: viewport.size.width, alignment: .leading)
            }
        }
        .simultaneousGesture(DragGesture(minimumDistance: 24)
            .onChanged { value in
                guard !dockGestureHandled,
                      abs(value.translation.height) > abs(value.translation.width) * 1.8,
                      abs(value.translation.height) > 64 else { return }
                dockGestureHandled = true
                onScrollStateChange(value.translation.height < 0)
            }
            .onEnded { _ in dockGestureHandled = false })
        }
        .background(themeColor)
        .ignoresSafeArea(edges: .top)
        .coordinateSpace(name: "lucentHeroScroll")
        .onAppear { heroIsVisible = true }
        .onDisappear {
            saveHeroPosition()
            heroIsVisible = false
        }
        .task(id: "\(source?.id.uuidString ?? "")|\(refreshID.uuidString)") { await loadHome() }
        .onChange(of: minimumResumePercent) { _, _ in Task { await loadHome() } }
        .onChange(of: completedPercent) { _, _ in Task { await loadHome() } }
        .task(id: contentLocalizationID) {
            if HomeSnapshotCache.artworkLanguage != contentLocalizationID {
                HomeSnapshotCache.artworks.removeAll()
                HomeSnapshotCache.artworkLanguage = contentLocalizationID
                heroArtworks.removeAll()
            }
            await loadHeroArtwork(at: heroIndex)
            if latest.count > 1 { await loadHeroArtwork(at: (heroIndex + 1) % latest.count) }
        }
        .task(id: "\(source?.id.uuidString ?? "")|\(latest.map(\.id).joined(separator: ","))") {
            guard !latest.isEmpty else { return }
            await loadHeroArtwork(at: heroIndex)
            if latest.count > 1 { await loadHeroArtwork(at: (heroIndex + 1) % latest.count) }
        }
        .task(id: "\(heroIndex)|\(heroAutoplay)|\(heroIsVisible)|\(latest.map(\.id).joined(separator: ","))") {
            guard heroIsVisible, latest.count > 1 else { return }
            await loadHeroArtwork(at: heroIndex)
            await loadHeroArtwork(at: (heroIndex + 1) % latest.count)
            guard heroAutoplay else { return }
            let remaining = heroPauseUntil.timeIntervalSinceNow
            if remaining > 0 {
                do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            let start = min(1, max(0, source.flatMap { HomeSnapshotCache.heroProgress[$0.id] } ?? 0))
            heroProgress = start
            heroCycleStartProgress = start
            heroCycleStartedAt = Date()
            let duration = max(0.01, 5 * (1 - start))
            withAnimation(.linear(duration: duration)) { heroProgress = 1 }
            do { try await Task.sleep(for: .seconds(duration)) } catch { return }
            guard !Task.isCancelled, heroIsVisible, !detailPresented else { return }
            advanceHero(to: (heroIndex + 1) % latest.count)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            HomeSnapshotCache.releaseRebuildable()
            ArtworkImageDecoder.clear()
        }
        .onChange(of: library.embySources.map(\.id)) { _, ids in
            HomeSnapshotCache.trim(validSources: Set(ids).union([HomeSnapshotCache.localContext.id]))
        }
        .onReceive(library.$items.dropFirst().throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)) { _ in
            guard localLibrary else { return }
            Task { @MainActor in await refreshLocalContinuing() }
        }
        .onReceive(library.$catalogStructureRevision.dropFirst().debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            guard localLibrary else { return }
            Task { @MainActor in await loadLocalHome() }
        }
        .onReceive(library.$fileSources.dropFirst().debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in
            guard localLibrary else { return }
            Task { @MainActor in await Task.yield(); await loadLocalHome() }
        }
        .navigationDestination(item: $localCollection) { collection in
            LocalCatalogCollectionView(collection: collection, detailPresented: $detailPresented).environmentObject(library)
        }
        .onChange(of: localCollection) { _, value in onCollectionChange(value != nil) }
        .navigationDestination(item: $selectedItemID) { id in
            detailDestination(id)
        }
        .onChange(of: selectedItemID) { _, newValue in
            detailPresented = newValue != nil
        }
        .sheet(isPresented:$showAllContinuing) {
            if let source { HomeContinuingList(source:source).environmentObject(library) }
        }
        .navigationDestination(item: $browserRoute) { route in
            EmbyBrowserView(source: route.source, parentID: route.parentID, title: route.title, embedded: true)
                .environmentObject(library)
        }
        .onChange(of: browserRoute?.id) { _, value in onCollectionChange(value != nil) }
    }

    private func hero(height: CGFloat, pull: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if latest.indices.contains(heroIndex), let source {
                    if let heroDragTarget, latest.indices.contains(heroDragTarget) {
                        heroArtwork(latest[heroDragTarget], source: source, size: geometry.size, pull: pull)
                        heroContent(latest[heroDragTarget], size: geometry.size)
                            .opacity(min(1, abs(heroDragX) / max(geometry.size.width, 1) * 2))
                            .allowsHitTesting(false)
                        heroArtwork(latest[heroIndex], source: source, size: geometry.size, pull: pull)
                            .mask(alignment: heroDragX < 0 ? .leading : .trailing) {
                                Rectangle().frame(width: max(0, geometry.size.width - abs(heroDragX)))
                            }
                            .allowsHitTesting(false)
                        heroContent(latest[heroIndex], size: geometry.size)
                            .offset(x: heroDragX)
                            .allowsHitTesting(false)
                    } else {
                        heroArtwork(latest[heroIndex], source: source, size: geometry.size, pull: pull)
                        heroContent(latest[heroIndex], size: geometry.size)
                    }
                    if heroDragTarget == nil, let outgoingHeroIndex, latest.indices.contains(outgoingHeroIndex) {
                        heroArtwork(latest[outgoingHeroIndex], source: source, size: geometry.size, pull: pull)
                            .mask(alignment: heroForward ? .leading : .trailing) {
                                Rectangle().frame(width: geometry.size.width * (1 - heroReveal))
                            }
                            .allowsHitTesting(false)
                        heroContent(latest[outgoingHeroIndex], size: geometry.size)
                            .offset(x: (heroForward ? -1 : 1) * geometry.size.width * heroReveal)
                            .allowsHitTesting(false)
                    }
                }
                HeroGestureSurface(onDrag: { dx in
                    guard latest.count > 1, !heroTransitioning else { return }
                    heroPauseUntil = Date().addingTimeInterval(8)
                    heroDragX = min(geometry.size.width, max(-geometry.size.width, dx))
                    heroDragTarget = (heroIndex + (dx < 0 ? 1 : -1) + latest.count) % latest.count
                }, onEnd: { dx in
                    guard let target = heroDragTarget else { return }
                    let shouldAdvance = abs(dx) > geometry.size.width * 0.30
                    heroTransitioning = true
                    if shouldAdvance {
                        rememberHeroSelection(at: target)
                        indicatorIndex = target
                        transitionHeroTheme(to: latest[target].id)
                    }
                    withAnimation(.interactiveSpring(response: 0.34, dampingFraction: 0.88)) {
                        heroDragX = shouldAdvance ? (heroDragX < 0 ? -geometry.size.width : geometry.size.width) : 0
                    }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(380))
                        if shouldAdvance {
                            withTransaction(Transaction(animation: nil)) {
                                heroIndex = target
                                rememberHeroSelection(at: target)
                                heroDragTarget = nil
                                heroDragX = 0
                            }
                            // The image may have become ready during the drag's settling animation.
                            transitionHeroTheme(to: latest[target].id)
                        } else {
                            heroDragTarget = nil
                            heroDragX = 0
                        }
                        heroTransitioning = false
                    }
                }, onTap: {
                        if heroDragTarget == nil, !heroTransitioning, latest.indices.contains(heroIndex) {
                            open(latest[heroIndex], transitionKey: "hero:\(latest[heroIndex].id)")
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Color.clear.frame(width: 1, height: 40)
                    Spacer()
                }
                .foregroundStyle(HomePalette.ink)
                .padding(.horizontal, HomePalette.inset)
                .padding(.top, HomePalette.isPad ? 72 : 60)
                if latest.count > 1 {
                    HStack(spacing: 0) {
                        ZStack(alignment: .leading) {
                            HStack(spacing: 0) {
                                ForEach(latest.indices, id: \.self) { index in
                                    Button {
                                        heroPauseUntil = Date().addingTimeInterval(8)
                                        advanceHero(to: index)
                                    } label: {
                                        Circle()
                                            .fill(Color.gray.opacity(index == indicatorIndex ? 0 : 0.65))
                                            .frame(width: 4, height: 4)
                                            .frame(width: 22, height: 30)
                                            .contentShape(Rectangle())
                                    }
                                    .accessibilityLabel("第 \(index + 1) 张：\(latest[index].name)")
                                }
                            }
                            Capsule()
                                .fill(Color.gray.opacity(0.35))
                                .frame(width: 18, height: 4)
                                .overlay(alignment: .leading) {
                                    Capsule()
                                        .fill(darkMode ? Color.white : Color.black)
                                        .frame(width: max(2, 18 * heroProgress), height: 4)
                                }
                                .offset(x: CGFloat(indicatorIndex) * 22 + 2)
                                .animation(.spring(response: 0.42, dampingFraction: 0.86), value: indicatorIndex)
                                .allowsHitTesting(false)
                        }
                        .frame(width: CGFloat(latest.count) * 22)
                    }
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(height: height)
    }

    private func heroArtwork(_ item: MediaCard, source: EmbySource, size: CGSize,
                             pull: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            EmbyArtwork(source: source, itemID: item.id,
                        backdrop: heroArtworks[item.id]?.posterURL == nil, width: 1200,
                        preferredURL: heroArtworks[item.id]?.posterURL,
                        softenBottom: true,
                        onImage: { image in
                            heroThemes[item.id] = Self.theme(from: image)
                            HomeSnapshotCache.themes[source.id] = heroThemes
                            if latest.indices.contains(heroIndex), latest[heroIndex].id == item.id {
                                transitionHeroTheme(to: item.id)
                            }
                        })
                .frame(width: size.width, height: size.height)
                .scaleEffect(1 + min(pull / max(size.height - pull, 1), 0.4), anchor: .top)
                .frame(maxHeight: .infinity, alignment: .top)
            LinearGradient(stops: [
                .init(color: .black.opacity(0.30), location: 0),
                .init(color: .clear, location: 0.30),
                .init(color: themeColor.opacity(0.12), location: 0.50),
                .init(color: themeColor.opacity(0.58), location: 0.72),
                .init(color: themeColor.opacity(0.88), location: 0.88),
                .init(color: themeColor, location: 1)
            ], startPoint: .top, endPoint: .bottom)
        }
        .frame(width: size.width, height: size.height)
    }

    private func heroContent(_ item: MediaCard, size: CGSize) -> some View {
        let displayItem = heroDetails[item.id] ?? item
        return VStack(spacing: 11) {
                if let artwork = heroArtworks[item.id] {
                    DetailTitleArtwork(url: artwork.logoURL,
                                       title: artwork.localizedTitle ?? item.name)
                        .frame(maxWidth: HomePalette.isPad ? 450 : size.width * 0.82,
                               minHeight: 100, maxHeight: 125)
                } else {
                    Color.clear.frame(height: 125)
                }
                HStack(spacing: 7) {
                    if let rating = displayItem.communityRating {
                        Image(systemName: "star.fill").foregroundStyle(LucentUI.ratingTint)
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                    }
                    if let date = heroDisplayDate(for: displayItem) { Text("·  " + date) }
                    if let genres = displayItem.genres, !genres.isEmpty {
                        Text("·  " + genres.prefix(2).joined(separator: "、")).lineLimit(1)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(darkMode ? Color.white : Color.black)
                if let overview = displayItem.overview, !overview.isEmpty {
                    Text(overview).font(.subheadline)
                        .foregroundStyle(darkMode ? Color.white.opacity(0.86) : Color.gray)
                        .lineLimit(3)
                        .frame(height: 63, alignment: .top)
                } else { Color.clear.frame(height: 63) }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.bottom, 72)
        .frame(width: size.width, height: size.height, alignment: .bottom)
        .accessibilityElement(children: .combine)
    }

    private func advanceHero(to target: Int) {
        guard latest.indices.contains(target), target != heroIndex, !heroTransitioning else { return }
        let previous = heroIndex
        heroTransitioning = true
        heroForward = target == (previous + 1) % latest.count || target > previous
        outgoingHeroIndex = previous
        heroReveal = 0
        heroIndex = target
        rememberHeroSelection(at: target)
        indicatorIndex = target
        transitionHeroTheme(to: latest[target].id)
        withAnimation(.easeOut(duration: 0.46)) {
            heroReveal = 1
        }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(470))
            outgoingHeroIndex = nil
            heroTransitioning = false
        }
    }

    private func rememberHeroSelection(at index: Int) {
        guard let source, latest.indices.contains(index) else { return }
        HomeSnapshotCache.selectedHeroIDs[source.id] = latest[index].id
        HomeSnapshotCache.heroProgress[source.id] = 0
        heroCycleStartedAt = nil
        withTransaction(Transaction(animation: nil)) { heroProgress = 0 }
    }

    private func saveHeroPosition() {
        guard let source, latest.indices.contains(heroIndex) else { return }
        HomeSnapshotCache.selectedHeroIDs[source.id] = latest[heroIndex].id
        let progress: Double
        if let startedAt = heroCycleStartedAt {
            progress = min(1, heroCycleStartProgress + Date().timeIntervalSince(startedAt) / 5)
        } else {
            progress = HomeSnapshotCache.heroProgress[source.id] ?? 0
        }
        HomeSnapshotCache.heroProgress[source.id] = progress
        heroCycleStartedAt = nil
        withTransaction(Transaction(animation: nil)) { heroProgress = progress }
    }

    private func isResumeCandidate(_ remote: MediaCard) -> Bool {
        homeResumeCandidate(remote.legacyPresentation, sourceID: source?.id, library: library)
    }

    private func loadHeroArtwork(at index: Int) async {
        guard latest.indices.contains(index), heroArtworks[latest[index].id] == nil else { return }
        let item = latest[index]
        if !localLibrary, let source,
           let embyToken = try? KeychainPasswordStore.embyToken(for: source.id), !embyToken.isEmpty,
           let detail = try? await ServerDetailClient.item(baseAddress: source.baseAddress,
               userID: source.userID, itemID: item.id, token: embyToken), !Task.isCancelled {
            heroDetails[item.id] = MediaCard(server: detail)
            HomeSnapshotCache.details[source.id] = heroDetails
        }
        guard let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else {
            heroArtworks[item.id] = TMDBService.DetailArtwork(posterURL: nil, logoURL: nil)
            return
        }
        let requestedLanguage = LocalizationPreferences.current.contentID
        let result = try? await TMDBService.detailArtwork(remote: (heroDetails[item.id] ?? item).legacyPresentation, metadata: nil,
            title: item.name, television: item.type == "Series",
            language: TMDBService.deviceLanguage, token: token,
            displayWidthPixels: Int(UIScreen.main.bounds.width * UIScreen.main.scale))
        guard !Task.isCancelled else { return }
        guard requestedLanguage == LocalizationPreferences.current.contentID else { return }
        heroArtworks[item.id] = result ?? TMDBService.DetailArtwork(posterURL: nil, logoURL: nil)
        if let source { HomeSnapshotCache.artworks[source.id] = heroArtworks }
    }

    private func heroDisplayDate(for item: MediaCard) -> String? {
        if let date = item.premiereDate, date.count >= 10 {
            return LocalizationPreferences.current.releaseDate(date) ?? String(date.prefix(10))
        }
        return item.productionYear.map(String.init)
    }

    private static func theme(from image: UIImage) -> HeroColors {
        let fallback = HeroColors(dark: HomePalette.background,
                                  light: Color(red: 0.94, green: 0.95, blue: 0.96))
        guard let cgImage = image.cgImage else { return fallback }
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
        let dark = values.map { (8 + $0 / peak * 42) / 255 }
        let light = values.map { (218 + $0 / peak * 24) / 255 }
        return HeroColors(dark: Color(red: dark[0], green: dark[1], blue: dark[2]),
                          light: Color(red: light[0], green: light[1], blue: light[2]))
    }

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                if localLibrary { localCollection = .continueWatching }
                else { showAllContinuing = true }
            } label: { heading("继续观看", count: continuingTotal) }.buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let source {
                        ForEach(continuing, id: \.id) { item in
                            Button { open(item, transitionKey: "continue:\(item.id)") } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottom) {
                                        EmbyArtwork(source: source, itemID: item.id,
                                                    backdrop: true, width: 500)
                                        LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                       startPoint: .center, endPoint: .bottom)
                                        if let rating = item.communityRating, rating > 0 {
                                            LucentRatingBadge(rating: rating)
                                                .frame(maxWidth: .infinity, alignment: .trailing)
                                                .padding(.trailing, 8).padding(.bottom, 22)
                                        }
                                        ProgressView(value: progress(item))
                                            .tint(.white)
                                            .padding(10)
                                    }
                                    .frame(width: HomePalette.continueWidth,
                                           height: HomePalette.isPad ? 160 : 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .modifier(HomeMatchedSource(key: "continue:\(item.id)",
                                                                namespace: detailTransition))
                                    Text(item.name).font(.subheadline.weight(.semibold))
                                        .foregroundStyle(HomePalette.ink).lineLimit(1)
                                    if let label = item.identity.episodeLabel {
                                        Text(label).font(.caption).foregroundStyle(HomePalette.muted)
                                            .lineLimit(1)
                                    }
                                }
                                .frame(width: HomePalette.continueWidth, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HomePalette.inset)
            }
        }
    }

    private var mediaSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                if localLibrary { localCollection = .mediaLibraries }
                else if let source { browserRoute = HomeBrowserRoute(source:source,parentID:nil,title:"我的媒体") }
            } label: { heading("我的媒体", count: views.count) }.buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    if let source {
                        ForEach(views, id: \.id) { view in
                            Button {
                                if localLibrary { localCollection = LocalCatalogCollection(rawValue: view.id) }
                                else { browserRoute = HomeBrowserRoute(source: source, parentID: view.id, title: view.name) }
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    if let first = shelves.first(where: { $0.id == view.id })?.items.first {
                                        EmbyArtwork(source: source, itemID: first.id,
                                                    backdrop: true, width: 500)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.isPad ? 145 : 120)
                                            .clipped()
                                    } else {
                                        LinearGradient(colors: [.init(red: 0.34, green: 0.51, blue: 0.52),
                                                                .init(red: 0.18, green: 0.27, blue: 0.36)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.isPad ? 145 : 120)
                                    }
                                    LinearGradient(colors: [.clear, .black.opacity(0.82)],
                                                   startPoint: .center, endPoint: .bottom)
                                        .frame(width: HomePalette.categoryWidth,
                                               height: HomePalette.isPad ? 145 : 120)
                                    Text(view.name)
                                        .font(.system(size: HomePalette.isPad ? 16 : 13,
                                                      weight: .semibold))
                                        .foregroundStyle(.white)
                                        .multilineTextAlignment(.leading)
                                        .lineLimit(2)
                                        .minimumScaleFactor(0.85)
                                        .frame(width: HomePalette.categoryWidth - 24,
                                               alignment: .leading)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .padding(12)
                                }
                                .frame(width: HomePalette.categoryWidth,
                                       height: HomePalette.isPad ? 145 : 120)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HomePalette.inset)
            }
        }
    }

    private func posterSection(_ shelf: HomeShelf) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                if let source {
                    if localLibrary { localCollection = LocalCatalogCollection(rawValue: shelf.view.id) }
                    else { browserRoute = HomeBrowserRoute(source: source, parentID: shelf.view.id, title: shelf.view.name) }
                }
            } label: {
                heading(shelf.view.name, count: nil)
            }
            .buttonStyle(.plain)
            if shelf.items.isEmpty {
                Text("打开媒体库查看全部")
                    .font(.subheadline)
                    .foregroundStyle(HomePalette.muted)
                    .padding(.horizontal, HomePalette.inset)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let source {
                        ForEach(shelf.items, id: \.id) { item in
                            Button { open(item, transitionKey: "shelf:\(shelf.id):\(item.id)") } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottomTrailing) {
                                        EmbyArtwork(source: source, itemID: item.id,
                                                    backdrop: false, width: 350)
                                        if let rating = item.communityRating ?? heroDetails[item.id]?.communityRating, rating > 0 {
                                            LucentRatingBadge(rating: rating)
                                                .padding(8)
                                        }
                                    }
                                    .frame(width: HomePalette.posterWidth,
                                           height: HomePalette.isPad ? 240 : 158)
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                    .modifier(HomeMatchedSource(key: "shelf:\(shelf.id):\(item.id)",
                                                                namespace: detailTransition))
                                    LucentPosterCaption(title: item.name, subtitle: item.productionYear.map(String.init), lines: 1)
                                }
                                .frame(width: HomePalette.posterWidth, alignment: .leading)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, HomePalette.inset)
            }
        }
    }

    private func heading(_ title: String, count: Int?) -> some View {
        HStack(spacing: 6) {
            Text(localLibrary ? title.lucentLocalized : title).font(HomePalette.isPad ? .title2.bold() : .title3.bold())
                .foregroundStyle(HomePalette.ink)
            Spacer()
            if let count { Text(String(count)).font(.subheadline).foregroundStyle(HomePalette.muted) }
            Image(systemName: "chevron.right").font(.caption.bold())
                .foregroundStyle(HomePalette.muted)
        }
        .padding(.horizontal, HomePalette.inset)
    }

    private func progress(_ item: MediaCard) -> Double {
        guard let total = item.runTimeTicks, total > 0 else { return 0 }
        return min(1, max(0, Double(item.userData?.playbackPositionTicks ?? 0) / Double(total)))
    }

    private func open(_ item: MediaCard, transitionKey: String? = nil) {
        if localLibrary {
            selectedTransitionKey = transitionKey
            selectedItemID = UUID(uuidString: item.id)
            return
        }
        guard let source else { return }
        if item.type != "Series" && item.isFolder == true {
            browserRoute = HomeBrowserRoute(source: source, parentID: item.id, title: item.name)
            return
        }
        selectedTransitionKey = transitionKey
        selectedItemID = library.openEmbyItem(sourceID: source.id, remote: item.legacyPresentation).id
    }

    private func transitionSource<Content: View>(_ content: Content, key: String) -> some View {
        content.modifier(HomeMatchedSource(key: key, namespace: detailTransition))
    }

    @ViewBuilder private func detailDestination(_ id: UUID) -> some View {
        if #available(iOS 18.0, *), let selectedTransitionKey {
            MediaDetailView(itemID: id)
                .environmentObject(library)
                .navigationTransition(.zoom(sourceID: selectedTransitionKey, in: detailTransition))
        } else {
            MediaDetailView(itemID: id).environmentObject(library)
        }
    }

    private func refreshLocalContinuing() async {
        let files = library.localLibraryItems.filter { $0.missingSince == nil }
        let result = await Task.detached(priority: .utility) {
            Dictionary(grouping: files.filter { $0.isInProgress && $0.metadata != nil }, by: \.catalogGroupID).values.compactMap { $0.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) } }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                .map { MediaCard(local: $0, asSeries: $0.identity?.seriesName != nil) }
        }.value
        guard !Task.isCancelled else { return }
        continuing = result; continuingTotal = result.count
        HomeSnapshotCache.localItems = Dictionary(files.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { _, last in last })
    }

    private func loadLocalHome() async {
        let files = library.localLibraryItems.filter { $0.missingSince == nil }
        HomeSnapshotCache.localItems = Dictionary(uniqueKeysWithValues: files.map { ($0.id.uuidString, $0) })
        let generation = UUID()
        localHomeGeneration = generation
        // Build each category once, and encode/decode presentation models away from scrolling.
        let result = await Task.detached(priority: .userInitiated) {
            let cards = LocalCatalogIndex(files: files).cards
            func mapped(_ values: [MediaItem]) -> [MediaCard] {
                values.map { MediaCard(local: $0, asSeries: $0.identity?.seriesName != nil) }
            }
            func category(_ value: LocalCatalogCollection) -> MediaCard {
                MediaCard(id: value.rawValue, title: value.title, kind: "CollectionFolder", isFolder: true)
            }
            let groups = Dictionary(grouping: files, by: \.catalogGroupID)
            let dates = groups.mapValues { $0.map(\.addedAt).max() ?? .distantPast }
            let ordered = cards.sorted { (dates[$0.catalogGroupID] ?? $0.addedAt) > (dates[$1.catalogGroupID] ?? $1.addedAt) }
            let categorized = Dictionary(grouping: ordered) { LocalCatalogCollection.category($0, members: groups[$0.catalogGroupID] ?? [$0]) }
            let shelves = LocalCatalogCollection.homeCategories.compactMap { value -> HomeShelf? in
                guard let values = categorized[value], !values.isEmpty else { return nil }
                return HomeShelf(view: category(value), items: mapped(Array(values.prefix(20))))
            }
            let continuing = mapped(LocalCatalogCollection.continueWatching.items(cards: cards, files: files))
            return (shelves, continuing, mapped(ordered))
        }.value
        guard !Task.isCancelled, localHomeGeneration == generation else { return }
        shelves = result.0
        views = result.0.map(\.view)
        continuing = result.1
        continuingTotal = continuing.count
        let available = result.2
        let context = HomeSnapshotCache.localContext.id
        let old = HomeSnapshotCache.entries[context]
        let preserve = old.map { $0.refreshID == refreshID && Date().timeIntervalSince($0.loadedAt) < HomeSnapshotCache.lifetime } ?? false
        let byID = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0) })
        let retained = preserve ? (old?.latest.compactMap { byID[$0.id] } ?? []) : []
        latest = retained + Array(available.filter { candidate in !retained.contains { $0.id == candidate.id } }.shuffled().prefix(max(0,8-retained.count)))
        if !hasLoadedHome {
            heroArtworks = HomeSnapshotCache.artworkLanguage == contentLocalizationID ? HomeSnapshotCache.artworks[context] ?? [:] : [:]
            heroThemes = HomeSnapshotCache.themes[context] ?? [:]
            heroIndex = HomeSnapshotCache.selectedHeroIDs[context].flatMap { id in latest.firstIndex { $0.id == id } } ?? 0
        }
        if !latest.indices.contains(heroIndex) { heroIndex = 0 }
        indicatorIndex = heroIndex
        selectedTheme = latest.indices.contains(heroIndex) ? heroThemes[latest[heroIndex].id] : nil
        HomeSnapshotCache.entries[context] = .init(refreshID:refreshID,loadedAt:preserve ? old!.loadedAt : Date(),views:views,latest:latest,continuing:continuing,continuingTotal:continuingTotal,shelves:shelves)
        hasLoadedHome = true
        errorMessage = files.isEmpty ? "请在片源页面添加存储并导入文件夹。" : nil
    }

    private func loadHome() async {
        HomeSnapshotCache.trim(validSources: Set(library.embySources.map(\.id)).union([HomeSnapshotCache.localContext.id]))
        if localLibrary { await loadLocalHome(); return }
        guard let source else {
            views = []; latest = []; continuing = []; continuingTotal = 0; shelves = []
            heroIndex = 0; indicatorIndex = 0
            heroArtworks = [:]; heroDetails = [:]; heroThemes = [:]
            selectedTheme = nil
            hasLoadedHome = false
            return
        }
        if let snapshot = HomeSnapshotCache.entries[source.id],
           snapshot.refreshID == refreshID,
           Date().timeIntervalSince(snapshot.loadedAt) < HomeSnapshotCache.lifetime {
            views = snapshot.views
            latest = snapshot.latest
            continuing = snapshot.continuing.filter(isResumeCandidate)
            continuingTotal = snapshot.continuingTotal
            shelves = snapshot.shelves
            heroArtworks = HomeSnapshotCache.artworkLanguage == contentLocalizationID ? HomeSnapshotCache.artworks[source.id] ?? [:] : [:]
            heroDetails = HomeSnapshotCache.details[source.id] ?? [:]
            heroThemes = HomeSnapshotCache.themes[source.id] ?? [:]
            let selectedID = HomeSnapshotCache.selectedHeroIDs[source.id]
            heroIndex = selectedID.flatMap { id in latest.firstIndex(where: { $0.id == id }) } ?? 0
            indicatorIndex = heroIndex
            heroProgress = HomeSnapshotCache.heroProgress[source.id] ?? 0
            selectedTheme = latest.indices.contains(heroIndex) ? heroThemes[latest[heroIndex].id] : nil
            hasLoadedHome = true
            errorMessage = nil
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false; hasLoadedHome = true }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                errorMessage = "Emby 登录已失效，请在片源页面更新令牌。"
                return
            }
            async let viewsRequest = EmbyClient.browse(source: source, token: token, parentID: nil)
            async let latestRequest = EmbyClient.latest(source: source, token: token)
            async let resumeRequest = EmbyClient.resume(source: source, token: token)
            let (viewPage, recentMovies, resumePage) = try await (viewsRequest, latestRequest, resumeRequest)
            try Task.checkCancellation()
            let fetchedViews = viewPage.items.map { MediaCard(server: $0) }
            let candidates = recentMovies.map { MediaCard(server: $0) }.filter { $0.type == "Movie" || $0.type == "Series" }
            let fetchedLatest = Array(candidates.shuffled().prefix(8))
            let fetched = try await withThrowingTaskGroup(of: (String, [MediaCard]).self) { group in
                for view in fetchedViews {
                    group.addTask {
                        let page = try await EmbyClient.featured(
                            source: source, token: token, parentID: view.id,
                            itemTypes: EmbyClient.featuredItemTypes(for: view.legacyPresentation))
                        return (view.id, page.items.map { MediaCard(server: $0) })
                    }
                }
                var results: [String: [MediaCard]] = [:]
                for try await (id, items) in group { results[id] = items }
                return results
            }
            try Task.checkCancellation()
            views = fetchedViews
            latest = fetchedLatest
            heroIndex = 0
            indicatorIndex = 0
            HomeSnapshotCache.selectedHeroIDs[source.id] = latest.first?.id
            HomeSnapshotCache.heroProgress[source.id] = 0
            heroProgress = 0
            outgoingHeroIndex = nil
            heroArtworks = [:]
            heroDetails = [:]
            heroThemes = [:]
            HomeSnapshotCache.artworks[source.id] = [:]
            HomeSnapshotCache.details[source.id] = [:]
            HomeSnapshotCache.themes[source.id] = [:]
            selectedTheme = nil
            continuing = resumePage.items.map { MediaCard(server: $0) }.filter(isResumeCandidate)
            continuingTotal = resumePage.totalCount
            shelves = views.map { HomeShelf(view: $0, items: fetched[$0.id] ?? []) }
            do { try await library.synchronizeServerHome(sourceID: source.id, emby: true) }
            catch is CancellationError { return }
            catch { errorMessage = "首页已刷新，部分已打开条目未能同步，请稍后重试。" }
            // A successfully fetched empty library is authoritative too; replace stale snapshots.
            HomeSnapshotCache.entries[source.id] = .init(
                refreshID: refreshID, loadedAt: Date(), views: views, latest: latest,
                continuing: resumePage.items.map { MediaCard(server: $0) }, continuingTotal: continuingTotal, shelves: shelves)
        } catch {
            errorMessage = "无法读取推荐内容：\(error.localizedDescription)"
        }
    }
}

@MainActor private func homeResumeCandidate(_ remote: JellyfinItem, sourceID: UUID?, library: LibraryStore) -> Bool {
    if let sourceID, let local = library.items.first(where: { item in
        switch item.location {
        case .embyItem(let id, let remoteID), .jellyfinItem(let id, let remoteID): return id == sourceID && remoteID == remote.id
        default: return false
        }
    }), (local.stateUpdatedAt ?? .distantPast) >= (remote.remoteStateDate ?? .distantPast) {
        return local.isInProgress
    }
    return PlaybackProgressPolicy.current.resumePosition(
        position: Double(remote.userData?.playbackPositionTicks ?? 0) / 10_000_000,
        duration: remote.runTimeTicks.map { Double($0) / 10_000_000 }, watched: remote.userData?.played == true) > 0
}

private struct HomeContinuingList: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let source: EmbySource
    @State private var items: [JellyfinItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedID: UUID?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:160))],alignment:.leading,spacing:18) {
                    ForEach(items,id:\.id) { item in
                        Button { selectedID = library.openEmbyItem(sourceID:source.id,remote:item).id } label: {
                            VStack(alignment:.leading,spacing:8) {
                                EmbyArtwork(source:source,itemID:item.id,backdrop:true,width:600)
                                    .frame(height:110).clipShape(RoundedRectangle(cornerRadius:14))
                                Text(item.seriesName ?? item.name).font(.subheadline).lineLimit(1)
                                if let label = item.identity.episodeLabel { Text(label).font(.caption).foregroundStyle(.secondary) }
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
                if loading { ProgressView() }
                if let error { Text(error).foregroundStyle(.secondary).padding() }
                if !loading && error == nil && items.isEmpty { ContentUnavailableView("暂无继续观看内容",systemImage:"play.circle") }
            }
            .navigationTitle("继续观看").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement:.cancellationAction) { Button("完成") { dismiss() } } }
            .navigationDestination(item:$selectedID) { id in MediaDetailView(itemID:id).environmentObject(library) }
            .task {
                defer { loading = false }
                do {
                    guard let token = try KeychainPasswordStore.embyToken(for:source.id) else { throw URLError(.userAuthenticationRequired) }
                    items = try await EmbyClient.resume(source:source,token:token,limit:10000).items
                        .filter { homeResumeCandidate($0, sourceID: source.id, library: library) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

private enum SearchEntry: Identifiable, Sendable {
    case emby(EmbySource, JellyfinItem)
    case jellyfin(JellyfinSource, JellyfinItem)
    case plex(PlexSource, PlexItem)

    var id: String {
        switch self {
        case .emby(let source, let item): "emby|\(source.id)|\(item.id)"
        case .jellyfin(let source, let item): "jellyfin|\(source.id)|\(item.id)"
        case .plex(let source, let item): "plex|\(source.id)|\(item.ratingKey)"
        }
    }
    var title: String {
        switch self {
        case .emby(_, let item), .jellyfin(_, let item): item.name
        case .plex(_, let item): item.title
        }
    }
    var year: String? {
        switch self {
        case .emby(_, let item), .jellyfin(_, let item): item.productionYear.map(String.init)
        case .plex(_, let item): item.year.map(String.init)
        }
    }
}

private struct SearchGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let entries: [SearchEntry]
}

private struct SearchRemotePoster: View {
    let request: URLRequest?
    let cacheKey: String
    var body: some View { LucentRemoteArtwork(request: request, cacheKey: cacheKey) }
}

struct MobileSearchView: View {
    @EnvironmentObject private var library: LibraryStore
    let catalog: String
    @Binding var detailPresented: Bool
    @Binding var query: String
    @Binding var submittedQuery: String

    @State private var scope = "server"
    @State private var groups: [SearchGroup] = []
    @State private var localResults: [MediaItem] = []
    @State private var recommendations: [SearchEntry] = []
    @State private var localRecommendations: [MediaItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItemID: UUID?
    @State private var recommendationBatch = 0
    @AppStorage("lucent.search.history") private var historyJSON = "[]"

    private let columns = [GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12),
                           GridItem(.flexible(), spacing: 12)]

    private var term: String { submittedQuery.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var history: [String] {
        (try? JSONDecoder().decode([String].self, from: Data(historyJSON.utf8))) ?? []
    }
    private func groupedLocalTitles(_ items: [MediaItem]) -> [MediaItem] {
        var seenSeries = Set<String>()
        return items.filter { item in
            guard let series = item.identity?.seriesName else { return true }
            return seenSeries.insert(series.folding(options: [.caseInsensitive, .diacriticInsensitive],
                                                    locale: .current)).inserted
        }
    }
    private var hasResults: Bool {
        scope == "library" ? !localResults.isEmpty : groups.contains { !$0.entries.isEmpty }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    Text(term.isEmpty ? "搜索" : "搜索：\(term)")
                        .font(.system(size: 31, weight: .bold))
                        .padding(.top, 20)

                    if !localResults.isEmpty || groups.contains(where: { !$0.entries.isEmpty }) {
                        MobileSegmentedTabs(options: [("媒体库", "library"),
                                                      ("影视服务器", "server")],
                                            selection: $scope)
                    }

                    if term.isEmpty {
                        emptySearchContent
                    } else {
                        searchResultsContent
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 36)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .toolbar(.hidden, for: .navigationBar)
            .task(id: catalog) { scope = catalog == "library" ? "library" : "server" }
            .task(id: term) { await search() }
            .task(id: recommendationBatch) { await loadRecommendations() }
            .navigationDestination(item: $selectedItemID) { id in
                MediaDetailView(itemID: id).environmentObject(library)
            }
            .onChange(of: selectedItemID) { _, value in
                detailPresented = value != nil
            }
        }
        .searchable(text: $query, prompt: "搜索影片和剧集")
        .onSubmit(of: .search) {
            submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    @ViewBuilder private var emptySearchContent: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("最近搜索").font(.headline)
                    Spacer()
                    Button("清除") { historyJSON = "[]" }
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(history, id: \.self) { value in
                            Button {
                                query = value
                                submittedQuery = value
                            } label: {
                                Label(value, systemImage: "clock")
                                    .font(.subheadline)
                                    .padding(.horizontal, 14).padding(.vertical, 10)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        recommendationContent
    }

    @ViewBuilder private var recommendationContent: some View {
        if (scope == "library" && !localRecommendations.isEmpty) ||
            (scope == "server" && !recommendations.isEmpty) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("推荐观看").font(.title3.bold())
                    Spacer()
                    Button {
                        recommendationBatch += 1
                    } label: {
                        Label("换一批", systemImage: "arrow.clockwise")
                            .font(.subheadline)
                    }
                }
                if scope == "library" {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(localRecommendations) { item in
                            Button { selectedItemID = item.id } label: {
                                posterCard(title: item.identity?.seriesName ?? item.title, subtitle: nil) {
                                    if let url = library.posterURL(for: item) {
                                        LocalPosterView(url: url)
                                    } else {
                                        posterPlaceholder
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(recommendations) { entry in
                            entryButton(entry)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResultsContent: some View {
        if loading && scope == "server" {
            ProgressView("正在搜索…")
                .frame(maxWidth: .infinity).padding(.top, 36)
        }
        if let errorMessage {
            Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
        }
        if scope == "library", !localResults.isEmpty {
            resultSection(title: "媒体库", count: localResults.count) {
                ForEach(localResults) { item in
                    Button { selectedItemID = item.id } label: {
                        posterCard(title: item.identity?.seriesName ?? item.title, subtitle: nil) {
                            if let url = library.posterURL(for: item) {
                                LocalPosterView(url: url)
                            } else {
                                posterPlaceholder
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if scope == "server" {
            ForEach(groups) { group in
                if !group.entries.isEmpty {
                    resultSection(title: group.title, count: group.entries.count) {
                        ForEach(group.entries) { entry in entryButton(entry) }
                    }
                }
            }
        }
        if (!loading || scope == "library") && errorMessage == nil && !hasResults {
            VStack(alignment: .leading, spacing: 18) {
                Text("没有找到“\(term)”")
                    .font(.subheadline).foregroundStyle(.secondary)
                recommendationContent
            }
            .padding(.top, 16)
        }
    }

    private func resultSection<Content: View>(
        title: String, count: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.title3.bold())
                Text("\(count)").font(.caption).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 20, content: content)
        }
    }

    private func entryButton(_ entry: SearchEntry) -> some View {
        Button { open(entry) } label: {
            posterCard(title: entry.title, subtitle: entry.year) {
                entryPoster(entry)
            }
        }
        .buttonStyle(.plain)
    }

    private func posterCard<Poster: View>(
        title: String, subtitle: String?, @ViewBuilder poster: @escaping () -> Poster
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .aspectRatio(2.0 / 3.0, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        poster()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 13))
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var posterPlaceholder: some View {
        Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
    }

    @ViewBuilder private func entryPoster(_ entry: SearchEntry) -> some View {
        switch entry {
        case .emby(let source, let item):
            EmbyArtwork(source: source, itemID: item.id, backdrop: false, width: 360)
        case .jellyfin(let source, let item):
            SearchRemotePoster(
                request: (try? KeychainPasswordStore.jellyfinToken(for: source.id))
                    .flatMap { JellyfinClient.posterRequest(source: source, token: $0, itemID: item.id) },
                cacheKey: "search|jellyfin|\(source.id)|\(item.id)")
        case .plex(let source, let item):
            SearchRemotePoster(
                request: (try? KeychainPasswordStore.plexToken(for: source.id)).flatMap { token in
                    item.thumb.flatMap { PlexClient.posterRequest(source: source, token: token, thumb: $0) }
                },
                cacheKey: "search|plex|\(source.id)|\(item.ratingKey)")
        }
    }

    private func open(_ entry: SearchEntry) {
        switch entry {
        case .emby(let source, let item):
            selectedItemID = library.openEmbyItem(sourceID: source.id, remote: item).id
        case .jellyfin(let source, let item):
            selectedItemID = library.openJellyfinItem(sourceID: source.id, remote: item).id
        case .plex(let source, let item):
            if let opened = library.openPlexItem(sourceID: source.id, remote: item) {
                selectedItemID = opened.id
            } else {
                Task {
                    guard let token = try? KeychainPasswordStore.plexToken(for: source.id),
                          let detailed = try? await PlexClient.item(
                            source: source, token: token, ratingKey: item.ratingKey) else { return }
                    selectedItemID = library.openPlexItem(sourceID: source.id, remote: detailed)?.id
                }
            }
        }
    }

    private func search() async {
        guard !term.isEmpty else {
            groups = []
            localResults = []
            errorMessage = nil
            loading = false
            return
        }
        let searchTerm = term
        remember(searchTerm)
        localResults = groupedLocalTitles(library.localLibraryItems.filter {
            $0.missingSince == nil &&
            ($0.title.localizedStandardContains(searchTerm) ||
             ($0.identity?.seriesName?.localizedStandardContains(searchTerm) ?? false))
        })
        loading = true
        groups = []
        errorMessage = nil
        let emby = library.embySources
        let jellyfin = library.jellyfinSources
        let plex = library.plexSources
        let found = await withTaskGroup(of: SearchGroup?.self) { taskGroup in
            for source in emby {
                taskGroup.addTask {
                    guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                          !token.isEmpty,
                          let page = try? await EmbyClient.search(
                            source: source, token: token, term: searchTerm),
                          !page.items.isEmpty else { return nil }
                    return SearchGroup(id: "emby|\(source.id)", title: source.name,
                        entries: page.items.map { .emby(source, $0) })
                }
            }
            for source in jellyfin {
                taskGroup.addTask {
                    guard let token = try? KeychainPasswordStore.jellyfinToken(for: source.id),
                          !token.isEmpty,
                          let items = try? await JellyfinClient.search(
                            source: source, token: token, term: searchTerm),
                          !items.isEmpty else { return nil }
                    return SearchGroup(id: "jellyfin|\(source.id)", title: source.name,
                        entries: items.map { .jellyfin(source, $0) })
                }
            }
            for source in plex {
                taskGroup.addTask {
                    guard let token = try? KeychainPasswordStore.plexToken(for: source.id),
                          !token.isEmpty,
                          let items = try? await PlexClient.search(
                            source: source, token: token, term: searchTerm),
                          !items.isEmpty else { return nil }
                    return SearchGroup(id: "plex|\(source.id)", title: source.name,
                        entries: items.map { .plex(source, $0) })
                }
            }
            var results: [SearchGroup] = []
            for await group in taskGroup {
                if let group { results.append(group) }
            }
            return results
        }
        guard !Task.isCancelled else { return }
        groups = found.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        loading = false
    }

    private func loadRecommendations() async {
        localRecommendations = Array(groupedLocalTitles(library.localLibraryItems.filter {
            $0.missingSince == nil
        }).shuffled().prefix(9))
        let emby = library.embySources
        let jellyfin = library.jellyfinSources
        let plex = library.plexSources
        let found = await withTaskGroup(of: [SearchEntry].self) { taskGroup in
            for source in emby {
                taskGroup.addTask {
                    guard let token = try? KeychainPasswordStore.embyToken(for: source.id),
                          let items = try? await EmbyClient.latest(
                            source: source, token: token, limit: 24) else { return [] }
                    return items.map { .emby(source, $0) }
                }
            }
            for source in jellyfin {
                taskGroup.addTask {
                    guard let token = try? KeychainPasswordStore.jellyfinToken(for: source.id),
                          let items = try? await JellyfinClient.browsePage(
                            source: source, token: token, limit: 24) else { return [] }
                    return items.map { .jellyfin(source, $0) }
                }
            }
            for source in plex {
                taskGroup.addTask {
                    guard let token = try? KeychainPasswordStore.plexToken(for: source.id),
                          let items = try? await PlexClient.browsePage(
                            source: source, token: token, limit: 24) else { return [] }
                    return items.map { .plex(source, $0) }
                }
            }
            var entries: [SearchEntry] = []
            for await items in taskGroup { entries.append(contentsOf: items) }
            return entries
        }
        guard !Task.isCancelled else { return }
        recommendations = Array(found.shuffled().prefix(9))
    }

    private func remember(_ value: String) {
        let entries = Array(([value] + history.filter { $0 != value }).prefix(10))
        if let data = try? JSONEncoder().encode(entries),
           let encoded = String(data: data, encoding: .utf8) {
            historyJSON = encoded
        }
    }
}
#endif
