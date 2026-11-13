#if os(iOS)
import SwiftUI
import UIKit
import Combine

struct HomeMatchedSource: ViewModifier {
    let key: String
    let namespace: Namespace.ID
    var sourceBackground: Color? = nil

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            if let sourceBackground {
                content.matchedTransitionSource(id: key, in: namespace) { source in
                    source.background(sourceBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 0))
                        .shadow(color: .clear, radius: 0)
                }
            } else {
                content.matchedTransitionSource(id: key, in: namespace)
            }
        } else {
            content
        }
    }
}

struct HomeCollectionZoom: ViewModifier {
    let key: String?
    let namespace: Namespace.ID
    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18.0, *), let key {
            content.navigationTransition(.zoom(sourceID: key, in: namespace))
        } else { content }
    }
}

/// A quiet, adaptive introduction rather than an error panel or an empty canvas.
struct HomeLibraryEmptyState: View {
    let action: () -> Void
    var aggregateLibrary = false

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                ForEach([-1, 1, 0], id: \.self) { position in
                    RoundedRectangle(cornerRadius: 18)
                        .fill(LinearGradient(colors: [Color.primary.opacity(0.035), Color.primary.opacity(0.10)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay {
                            Image(systemName: position == 0 ? "play.fill" : position < 0 ? "film" : "tv")
                                .font(.system(size: position == 0 ? 30 : 24, weight: .light))
                                .foregroundStyle(.primary.opacity(position == 0 ? 0.8 : 0.35))
                        }
                        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.primary.opacity(0.08)))
                        .frame(width: 92, height: 136)
                        .rotationEffect(.degrees(Double(position) * 12))
                        .offset(x: CGFloat(position) * 70, y: position == 0 ? -8 : 10)
                        .shadow(color: .black.opacity(0.05), radius: 14, y: 10)
                }
            }
            .frame(height: 180)
            .accessibilityHidden(true)

            VStack(spacing: 12) {
                Text(aggregateLibrary ? "空空如也" : "你的私人影院")
                    .font(.largeTitle.bold())
                Text(aggregateLibrary ? "添加文件源并扫描电影与剧集，开始建立你的媒体库。" : "连接影视服务器，或导入存储中的电影与剧集。")
                    .font(.body).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineSpacing(5)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: action) {
                HStack(spacing: 12) {
                    if aggregateLibrary {
                        Text("配置聚合媒体库").frame(maxWidth: .infinity, alignment: .center)
                    } else {
                        Image(systemName: "plus")
                        Text("添加片源")
                        Spacer(minLength: 16)
                        Image(systemName: "arrow.right")
                    }
                }
                .font(.headline)
                .padding(.horizontal, 22).padding(.vertical, 17)
                .foregroundStyle(Color(uiColor: .systemBackground))
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 18))
            }
            .buttonStyle(.plain)
            .frame(maxWidth: 320)

            if !aggregateLibrary {
                HStack(spacing: 20) {
                    Label("影视服务器", systemImage: "server.rack")
                    Label("存储", systemImage: "externaldrive")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: 520)
        .padding(.horizontal, 28).padding(.vertical, 32)
        .frame(maxWidth: .infinity)
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
    static let categoryHeight: CGFloat = categoryWidth * (isPad ? 160 / 285 : 110 / 185)
    static let posterWidth: CGFloat = isPad ? 160 : 105
    static let sectionSpacing: CGFloat = isPad ? 38 : 30
}

struct EmbyArtwork: View {
    let source: EmbySource
    let itemID: String
    let backdrop: Bool
    let width: Int
    var stretchesImage = false
    var preferredURL: URL? = nil
    var targetPixelSize: CGSize? = nil
    var maximumDecodedPixels = 8_000_000
    var softenBottom = false
    var placeholderColor: Color? = nil
    var onImage: ((UIImage) -> Void)? = nil
    var onLoadingChange: ((Bool) -> Void)? = nil
    @State private var artworkLoading = true
    @State private var image: UIImage?
    @State private var imageIdentity: String?
    @State private var softenedImage: UIImage?
    @State private var softenedIdentity: ObjectIdentifier?
    var loadsImage = true
    var allowsPortraitFallback = true
    private var identity: String { "\(source.id)|\(itemID)" }
    private var pixelSize: Int { targetPixelSize == nil ? (backdrop ? width : Int(Double(width) * 1.5)) : 4096 }
    private var resolvedURL: URL? {
        let local = HomeSnapshotCache.localItems[itemID]
        let path = backdrop ? (local?.metadata?.backdropPath ?? (allowsPortraitFallback ? local?.metadata?.posterPath : nil)) : local?.metadata?.posterPath
        return preferredURL ?? path.flatMap { URL(string: "https://image.tmdb.org/t/p/\(targetPixelSize == nil ? "w780" : "original")\($0)") }
    }
    private var displayedImage: UIImage? {
        if imageIdentity == identity, let image { return image }
        if let url = resolvedURL, let cached = ArtworkImageDecoder.cachedImage(key: url.absoluteString, maximumPixelSize: pixelSize, targetPixelSize: targetPixelSize, maximumDecodedPixels: maximumDecodedPixels) { return cached }
        for useBackdrop in backdrop && allowsPortraitFallback ? [true, false] : [backdrop] {
            if let cached = ArtworkImageDecoder.cachedImage(key: "\(source.id)|\(itemID)|\(useBackdrop)", maximumPixelSize: pixelSize, targetPixelSize: targetPixelSize, maximumDecodedPixels: maximumDecodedPixels) { return cached }
        }
        return nil
    }
    private func install(_ loaded: UIImage) async {
        guard imageIdentity != identity || image !== loaded else { return }
        // Keep the previous complete frame until its replacement is ready.
        let prepared = softenBottom ? await ArtworkImageDecoder.softenedImage(loaded) : nil
        guard !Task.isCancelled else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            image = loaded
            imageIdentity = identity
            softenedImage = prepared
            softenedIdentity = prepared == nil ? nil : ObjectIdentifier(loaded)
        }
        onImage?(loaded)
    }

    var body: some View {
        let readyImage = displayedImage
        ZStack {
            if let placeholderColor { placeholderColor }
            else if readyImage == nil { LucentArtworkPlaceholder(symbol: backdrop ? "film.stack" : "film") }
            if let image = readyImage {
                Image(uiImage: image).resizable().modifier(LucentArtworkSizing(stretches: stretchesImage))
                    .overlay {
                        if softenBottom, softenedIdentity == ObjectIdentifier(image), let softenedImage {
                            Image(uiImage: softenedImage).resizable().scaledToFill()
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
        .onChange(of: readyImage == nil && artworkLoading, initial: true) { _, loading in onLoadingChange?(loading) }
        .task(id: softenBottom ? readyImage.map(ObjectIdentifier.init) : nil) {
            guard softenBottom, let image = readyImage, softenedIdentity != ObjectIdentifier(image) else { return }
            let prepared = await ArtworkImageDecoder.softenedImage(image)
            guard !Task.isCancelled else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                softenedImage = prepared
                softenedIdentity = prepared == nil ? nil : ObjectIdentifier(image)
            }
        }
        .task(id: "\(source.id)|\(itemID)|\(backdrop)|\(preferredURL?.absoluteString ?? "")|\(loadsImage)|\(width)|\(targetPixelSize?.width ?? 0)x\(targetPixelSize?.height ?? 0)|\(maximumDecodedPixels)") {
            artworkLoading = true
            defer { artworkLoading = false }
            guard loadsImage else { return }
            if let url = resolvedURL,
               let cached = ArtworkImageDecoder.cachedImage(key: url.absoluteString, maximumPixelSize: pixelSize, targetPixelSize: targetPixelSize, maximumDecodedPixels: maximumDecodedPixels) {
                await install(cached)
                return
            }
            if resolvedURL == nil, targetPixelSize == nil, let cached = displayedImage { await install(cached); return }
            if let cached = displayedImage { await install(cached) }
            if let preferredURL = resolvedURL,
               let data = try? await LocalMediaCache.shared.imageData(
                   key: "tmdb|\(preferredURL.absoluteString)", fetch: {
                       let (data, response) = try await URLSession.shared.data(from: preferredURL)
                       guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true
                       else { throw URLError(.badServerResponse) }
                       return data
                   }),
               let loaded = await ArtworkImageDecoder.image(data: data, key: preferredURL.absoluteString, maximumPixelSize: pixelSize, targetPixelSize: targetPixelSize, maximumDecodedPixels: maximumDecodedPixels) {
                guard !Task.isCancelled else { return }
                await install(loaded)
                return
            }
            for useBackdrop in backdrop && allowsPortraitFallback ? [true, false] : [backdrop] {
                guard let data = try? await LocalMediaCache.shared.imageData(
                    key: "emby|\(source.id)|\(itemID)|\(useBackdrop)|\(width)", fetch: {
                        guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else { throw URLError(.userAuthenticationRequired) }
                        return try await EmbyClient.artwork(source: source, token: token,
                            itemID: itemID, backdrop: useBackdrop, maxWidth: width)
                    }),
                      let loaded = await ArtworkImageDecoder.image(data: data, key: "\(source.id)|\(itemID)|\(useBackdrop)", maximumPixelSize: pixelSize, targetPixelSize: targetPixelSize, maximumDecodedPixels: maximumDecodedPixels) else { continue }
                guard !Task.isCancelled else { return }
                await install(loaded)
                break
            }
        }
    }
}

/// Prepare only visible resume covers from disk, without requests or credentials.
@MainActor private func prepareContinuingCovers(_ items: [MediaCard], source: EmbySource) async {
    let count = min(6, max(1, Int(ceil(UIScreen.main.bounds.width / HomePalette.continueWidth)) + 1))
    for item in items.prefix(count) {
        guard !Task.isCancelled else { return }
        let artworkID = item.legacyPresentation.seriesId ?? item.id
        let decodedKey = "\(source.id)|\(artworkID)|true"
        guard ArtworkImageDecoder.cachedImage(key: decodedKey, maximumPixelSize: 600) == nil,
              let data = await ArtworkDiskStore.shared.read("emby|\(source.id)|\(artworkID)|true|600") else { continue }
        _ = await ArtworkImageDecoder.image(data: data, key: decodedKey, maximumPixelSize: 600)
    }
}

private struct HomeShelf: Identifiable, Sendable {
    let view: MediaCard
    let items: [MediaCard]
    var id: String { view.id }
}

private final class HeroThemeImage {
    weak var image: UIImage?
    init(_ image: UIImage) { self.image = image }
}

private struct HeroColors: Equatable { let dark: Color; let light: Color }

@MainActor private enum HomeSnapshotCache {
    struct Snapshot {
        let refreshID: UUID
        var context: String? = nil
        let loadedAt: Date
        let views: [MediaCard]
        let latest: [MediaCard]
        var continuing: [MediaCard]
        var continuingTotal: Int
        let shelves: [HomeShelf]
    }
    static var entries: [UUID: Snapshot] = [:]
    static var artworkLanguage = LocalizationPreferences.current.contentID
    static var artworks: [UUID: [String: TMDBService.DetailArtwork]] = [:]
    static var details: [UUID: [String: MediaCard]] = [:]
    static var themes: [UUID: [String: HeroColors]] = [:]
    static var selectedHeroIDs: [UUID: String] = [:]
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
    }
    static func evict(_ id: UUID) {
        entries[id] = nil; artworks[id] = nil; details[id] = nil; themes[id] = nil
    }
    static func releaseRebuildable() {
        entries.removeAll(); artworks.removeAll(); details.removeAll(); themes.removeAll(); localItems.removeAll()
    }
    static let lifetime: TimeInterval = 24 * 60 * 60
}

/// Read the owning window, retaining its last active dimensions through system snapshots.
private struct HomeWindowSizeReader: UIViewRepresentable {
    @Environment(\.scenePhase) private var scenePhase
    let onChange: (CGSize) -> Void
    func makeUIView(context: Context) -> Anchor { Anchor(onChange: onChange) }
    func updateUIView(_ view: Anchor, context: Context) {
        view.onChange = onChange
        if scenePhase == .active { view.reportSize() }
    }
    final class Anchor: UIView {
        var onChange: (CGSize) -> Void
        private var reportedSize: CGSize?
        init(onChange: @escaping (CGSize) -> Void) {
            self.onChange = onChange
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() { super.didMoveToWindow(); reportSize() }
        override func layoutSubviews() { super.layoutSubviews(); reportSize() }
        func reportSize() {
            guard let window, window.windowScene?.activationState == .foregroundActive else { return }
            let size = window.bounds.size
            guard size.width > 0, size.height > 0, size != reportedSize else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window === window,
                      window.windowScene?.activationState == .foregroundActive,
                      self.reportedSize != size else { return }
                self.reportedSize = size
                self.onChange(size)
            }
        }
    }
}

private enum HomeHeroLayout {
    static func height(windowSize: CGSize?, viewportSize: CGSize, isPad: Bool, scale: CGFloat) -> CGFloat {
        let size = windowSize ?? viewportSize
        let windowHeight = isPad ? size.height : max(size.width, size.height)
        return ((isPad ? 650 : max(460, windowHeight * 0.76)) * scale).rounded(.up) / scale
    }
}

private struct HomeBrowserRoute: Identifiable, Hashable {
    let source: EmbySource
    let parentID: String?
    let title: String?
    var collectionType: String? = nil
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
    @AppStorage(PlaybackProgressPolicy.minimumKey) private var minimumResumePercent = 5.0
    @AppStorage(PlaybackProgressPolicy.completionKey) private var completedPercent = 90.0
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.displayScale) private var displayScale
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
    // Temporary comparison build for isolating scrolling from home refresh work.
    private let pausesHomeRefreshForComparison = true
    @State private var observedRefreshID: UUID?
    @State private var displayedHomeContext: String?
    private var homeContext: String {
        source.map { HomeStartupCache.context(source: $0, language: contentLocalizationID) } ?? "no-source"
    }
    @State private var manualRefreshSourceID: UUID?

    private var canRefreshServerShelves: Bool {
        !pausesHomeRefreshForComparison || (manualRefreshSourceID != nil && manualRefreshSourceID == source?.id)
    }
    @State private var cachedContinuing: [MediaCard] = []
    @State private var cachedContinuingTotal = 0

    private var continuing: [MediaCard] {
        guard !localLibrary, let source,
              let page = library.embyContinuingPages[source.id] else { return cachedContinuing }
        return page.items.map { remote in
            let card = MediaCard(server: remote)
            let metadata = HomeSnapshotCache.details[source.id]?[card.id]
            return metadata.map { card.preservingMetadata(from: $0) } ?? card
        }.filter(isResumeCandidate)
    }

    private var continuingTotal: Int {
        guard !localLibrary, let source else { return cachedContinuingTotal }
        return library.embyContinuingPages[source.id]?.totalCount ?? cachedContinuingTotal
    }
    @State private var shelves: [HomeShelf] = []
    @State private var shelfErrors: [String: String] = [:]
    @State private var isLoading = false
    @State private var hasLoadedHome = false
    @State private var localHomeGeneration = UUID()
    @State private var errorMessage: String?
    @State private var selectedItemID: UUID?
    @Namespace private var detailTransition
    @State private var selectedTransitionKey: String?
    @State private var browserRoute: HomeBrowserRoute?
    @State private var localCollection: LocalCatalogCollection?
    @State private var collectionTransitionKey: String?
    @State private var showAllContinuing = false
    @Environment(\.contentLocalizationID) private var contentLocalizationID
    @State private var heroLogoConnection: (sourceID: UUID, token: String)?
    @State private var heroArtworks: [String: TMDBService.DetailArtwork] = [:]
    @State private var heroDetails: [String: MediaCard] = [:]
    @State private var heroLoading: [String: Bool] = [:]
    @State private var heroThemeImages: [String: HeroThemeImage] = [:]
    @State private var restoredSnapshotKey: String?
    @State private var homeLoadID = UUID()
    @State private var heroThemes: [String: HeroColors] = [:]
    @State private var heroIndex = 0
    @State private var indicatorIndex = 0
    @State private var outgoingHeroIndex: Int?
    @State private var heroReveal = 0.0
    @State private var heroForward = true
    @State private var heroTransitioning = false
    @State private var heroWindowSize: CGSize?
    @State private var selectedTheme: HeroColors?
    @State private var heroDragX: CGFloat = 0
    @State private var heroSettleTask: Task<Void, Never>?
    @State private var heroDragTarget: Int?
    @State private var dockGestureHandled = false
    @State private var homeScrollIsActive = false
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

    private var hasHomeContent: Bool {
        !latest.isEmpty || !continuing.isEmpty || !views.isEmpty || !shelves.isEmpty
    }

    var body: some View {
        GeometryReader { viewport in
        let heroHeight = HomeHeroLayout.height(windowSize: heroWindowSize, viewportSize: viewport.size,
                                               isPad: HomePalette.isPad, scale: displayScale)
        ScrollView {
            if !hasHomeContent && source != nil && (!hasLoadedHome || isLoading) {
                ProgressView("正在加载首页")
                    .frame(maxWidth: .infinity, minHeight: max(440, viewport.size.height * 0.75))
                    .padding(.top, 66)
            } else if !hasHomeContent && errorMessage == nil {
                HomeLibraryEmptyState(action: showSources, aggregateLibrary: localLibrary)
                    .frame(minHeight: max(480, viewport.size.height - 140))
                    .padding(.top, HomePalette.isPad ? 76 : 66)
                    .padding(.bottom, 44)
            } else if hasLoadedHome {
            VStack(alignment: .leading, spacing: 0) {
                if !latest.isEmpty {
                    StretchyHeroHeader(height: heroHeight) { height, pull in
                        if latest.indices.contains(heroIndex) {
                            hero(height: height, pull: pull, baseHeight: heroHeight)
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
        .onScrollPhaseChange { _, phase in
            homeScrollIsActive = phase != .idle
        }
        .lucentHideTopScrollEdge()
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
        .background(HomeWindowSizeReader { heroWindowSize = $0 }.frame(width: 0, height: 0))
        .background(themeColor)
        .ignoresSafeArea(edges: .top)
        .coordinateSpace(name: "lucentHeroScroll")
        .onChange(of: "\(source?.id.uuidString ?? "")|\(latest.map(\.id).joined(separator: "|"))") { _, _ in
            heroSettleTask?.cancel()
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                outgoingHeroIndex = nil
                heroDragTarget = nil
                heroDragX = 0
                heroTransitioning = false
            }
        }
        .onDisappear {
            heroSettleTask?.cancel()
            outgoingHeroIndex = nil
            heroDragTarget = nil
            heroDragX = 0
            heroTransitioning = false
        }
        .task(id: source?.id) {
            heroLogoConnection = nil
            guard !localLibrary, let source,
                  let token = try? KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else { return }
            heroLogoConnection = (source.id, token)
        }
        .task(id: "\(homeContext)|\(refreshID.uuidString)") {
            let manual = observedRefreshID.map { $0 != refreshID } ?? false
            observedRefreshID = refreshID
            if manual { manualRefreshSourceID = source?.id }
            else if manualRefreshSourceID != source?.id { manualRefreshSourceID = nil }
            await loadHome(manualRefresh: manual)
        }
        .onChange(of: minimumResumePercent) { _, _ in Task { await loadHome() } }
        .onChange(of: completedPercent) { _, _ in Task { await loadHome() } }
        .task(id: "\(homeContext)|\(heroIndex)|\(latest.map(\.id).joined(separator: ","))") {
            if HomeSnapshotCache.artworkLanguage != contentLocalizationID {
                HomeSnapshotCache.artworks.removeAll()
                HomeSnapshotCache.artworkLanguage = contentLocalizationID
                heroArtworks.removeAll()
            }
            guard !latest.isEmpty else { return }
            await loadHeroArtwork(at: heroIndex)
            if latest.count > 1 { await loadHeroArtwork(at: (heroIndex + 1) % latest.count) }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didReceiveMemoryWarningNotification)) { _ in
            HomeSnapshotCache.releaseRebuildable()
            ArtworkImageDecoder.clear()
        }
        .onChange(of: library.embySources.map(\.id)) { _, ids in
            HomeSnapshotCache.trim(validSources: Set(ids).union([HomeSnapshotCache.localContext.id]))
        }
        .onReceive(library.$items.dropFirst().throttle(for: .milliseconds(750), scheduler: RunLoop.main, latest: true)) { _ in
            guard !pausesHomeRefreshForComparison, localLibrary else { return }
            Task { @MainActor in await refreshLocalContinuing() }
        }
        .onReceive(library.$catalogStructureRevision.dropFirst().debounce(for: .milliseconds(250), scheduler: RunLoop.main)) { _ in
            guard !pausesHomeRefreshForComparison, localLibrary else { return }
            Task { @MainActor in await loadLocalHome() }
        }
        .onReceive(library.$fileSources.dropFirst().debounce(for: .milliseconds(200), scheduler: RunLoop.main)) { _ in
            guard !pausesHomeRefreshForComparison, localLibrary else { return }
            Task { @MainActor in await Task.yield(); await loadLocalHome() }
        }
        .navigationDestination(item: $localCollection) { collection in
            Group {
                LocalCatalogCollectionView(collection: collection, detailPresented: $detailPresented,
                                           onBack: { withAnimation { localCollection = nil } }).environmentObject(library)
                    .modifier(HomeCollectionZoom(key: collectionTransitionKey, namespace: detailTransition))
            }.lucentSecondaryPage()
        }
        .onChange(of: localCollection != nil || browserRoute != nil || showAllContinuing) { _, value in onCollectionChange(value) }
        .navigationDestination(item: $selectedItemID) { id in
            Group {
                detailDestination(id)
            }.lucentSecondaryPage()
        }
        .onChange(of: selectedItemID) { _, newValue in
            detailPresented = newValue != nil
        }
        .navigationDestination(isPresented: $showAllContinuing) {
            if let source {
                HomeContinuingList(source: source, onBack: { withAnimation { showAllContinuing = false } })
                    .environmentObject(library)
                    .lucentSecondaryPage()
            }
        }
        .navigationDestination(item: $browserRoute) { route in
            Group {
                EmbyBrowserView(source: route.source, parentID: route.parentID, title: route.title, embedded: true, collectionTypeHint: route.collectionType,
                                onBack: { withAnimation { browserRoute = nil } })
                    .environmentObject(library)
                    .modifier(HomeCollectionZoom(key: collectionTransitionKey, namespace: detailTransition))
            }.lucentSecondaryPage()
        }
        .onChange(of: browserRoute?.id) { _, value in onCollectionChange(value != nil) }
    }

    private var mountedHeroIndices: [Int] {
        guard latest.indices.contains(heroIndex) else { return [] }
        let count = latest.count
        var indices: Set<Int> = [heroIndex, (heroIndex + 1) % count, (heroIndex + count - 1) % count]
        if let outgoingHeroIndex, latest.indices.contains(outgoingHeroIndex) { indices.insert(outgoingHeroIndex) }
        if let heroDragTarget, latest.indices.contains(heroDragTarget) { indices.insert(heroDragTarget) }
        return indices.sorted()
    }

    private func hero(height: CGFloat, pull: CGFloat, baseHeight: CGFloat) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                if latest.indices.contains(heroIndex), let source {
                    ForEach(mountedHeroIndices, id: \.self) { index in
                        heroLayer(latest[index], index: index, source: source, size: geometry.size, pull: pull, baseHeight: baseHeight)
                    }
                }
                HeroGestureSurface(onDrag: { dx in
                    guard latest.count > 1, !heroTransitioning else { return }
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
                    heroSettleTask?.cancel()
                    heroSettleTask = Task { @MainActor in
                        do { try await Task.sleep(for: .milliseconds(380)) } catch { return }
                        guard latest.indices.contains(target) else { return }
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
                            open(latest[heroIndex], transitionKey: nil)
                        }
                    })
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .zIndex(5)
                HStack {
                    Color.clear.frame(width: 1, height: 40)
                    Spacer()
                }
                .foregroundStyle(HomePalette.ink)
                .padding(.horizontal, HomePalette.inset)
                .padding(.top, HomePalette.isPad ? 72 : 60)
                if latest.count > 1 {
                    HStack(spacing: 0) {
                        ForEach(latest.indices, id: \.self) { index in
                            let distance = abs(index - indicatorIndex)
                            let diameter: CGFloat = distance == 0 ? 8 : distance == 1 ? 6 : 4
                            Button {
                                advanceHero(to: index)
                            } label: {
                                Circle()
                                    .fill(index == indicatorIndex ? (darkMode ? Color.white : Color.black) : Color.gray.opacity(0.65))
                                    .frame(width: diameter, height: diameter)
                                    .frame(width: 22, height: 30)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("第 \(index + 1) 张：\(latest[index].name)")
                            .accessibilityAddTraits(index == indicatorIndex ? .isSelected : [])
                        }
                    }
                    .animation(.easeInOut(duration: 0.25), value: indicatorIndex)
                    .frame(maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 14)
                    .zIndex(10)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .frame(height: height)
    }

    // Keep each slide's identity stable across manual drag and settling.
    private func heroLayer(_ item: MediaCard, index: Int, source: EmbySource,
                           size: CGSize, pull: CGFloat, baseHeight: CGFloat) -> some View {
        let current = index == heroIndex
        let incoming = index == heroDragTarget
        let outgoing = heroDragTarget == nil && index == outgoingHeroIndex
        let dragging = current && heroDragTarget != nil
        let visible = current || incoming || outgoing
        let coverage = outgoing ? 1 - heroReveal : (dragging ? 1 - abs(heroDragX) / max(size.width, 1) : 1)
        let nearby = index == (heroIndex + 1) % max(latest.count, 1) || index == (heroIndex + latest.count - 1) % max(latest.count, 1)
        return ZStack {
            heroArtwork(item, source: source, size: size, pull: pull, baseHeight: baseHeight, loadsImage: visible || nearby)
                .mask(alignment: outgoing ? (heroForward ? .leading : .trailing) : (heroDragX < 0 ? .leading : .trailing)) {
                    Rectangle().frame(width: size.width * max(0, coverage), height: size.height)
                }
            if visible {
                heroContent(item, size: size)
                    .opacity(incoming ? min(1, abs(heroDragX) / max(size.width, 1) * 2) : 1)
                    .offset(x: outgoing ? (heroForward ? -1 : 1) * size.width * heroReveal : (dragging ? heroDragX : 0))
            }
        }
        .opacity(visible ? 1 : 0)
        .zIndex(outgoing || dragging ? 2 : (visible ? 1 : 0))
        .allowsHitTesting(false)
    }

    private func heroArtwork(_ item: MediaCard, source: EmbySource, size: CGSize,
                             pull: CGFloat, baseHeight: CGFloat, loadsImage: Bool = true) -> some View {
        ZStack(alignment: .bottom) {
            EmbyArtwork(source: source, itemID: item.id,
                        // Decode once off the scroll offset: rubber-band stretch stays a cheap scaleEffect.
                        backdrop: heroArtworks[item.id]?.posterURL == nil,
                        width: min(4096, Int((max(size.width, baseHeight * 16 / 9) * displayScale).rounded(.up))),
                        preferredURL: heroArtworks[item.id]?.posterURL,
                        targetPixelSize: CGSize(width: (size.width * displayScale).rounded(), height: (baseHeight * displayScale).rounded()),
                        maximumDecodedPixels: 8_000_000,
                        softenBottom: true,
                        placeholderColor: themeColor,
                        onImage: { image in
                            if heroThemeImages[item.id]?.image !== image {
                                let colors = Self.theme(from: image)
                                heroThemeImages[item.id] = HeroThemeImage(image)
                                if heroThemes[item.id] != colors { heroThemes[item.id] = colors }
                                HomeSnapshotCache.themes[source.id] = heroThemes
                            }
                            if latest.indices.contains(heroIndex), latest[heroIndex].id == item.id {
                                transitionHeroTheme(to: item.id)
                            }
                        }, onLoadingChange: { loading in
                            if heroLoading[item.id] != loading { heroLoading[item.id] = loading }
                        }, loadsImage: loadsImage)
                .frame(width: size.width, height: size.height)
                .scaleEffect(1 + min(pull / max(baseHeight, 1), 0.4), anchor: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .visualEffect { effect, geometry in
                    // Cancel only upward page movement for the image; the overlay stays in the scroll flow.
                    effect.offset(y: max(0, -geometry.frame(in: .scrollView(axis: .vertical)).minY))
                }
            LinearGradient(colors: [.black.opacity(0.30), .clear],
                           startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.30))
        }
        .frame(width: size.width, height: size.height)
        .mask { HeroArtworkFade() }
    }

    private func heroLogoRequest(_ item: MediaCard) -> URLRequest? {
        guard !localLibrary, let source, let connection = heroLogoConnection,
              connection.sourceID == source.id else { return nil }
        return ServerDetailClient.logoRequest(baseAddress: source.baseAddress, token: connection.token, itemID: item.id)
    }

    private func heroContent(_ item: MediaCard, size: CGSize) -> some View {
        let displayItem = heroDetails[item.id] ?? item
        return VStack(spacing: 11) {
                DetailTitleArtwork(url: heroArtworks[item.id]?.logoURL,
                                   title: heroArtworks[item.id]?.localizedTitle ?? item.name,
                                   fallbackRequest: heroLogoRequest(item))
                    .frame(maxWidth: HomePalette.isPad ? 450 : size.width * 0.82,
                           minHeight: 100, maxHeight: 125)
                    .overlay(alignment: .top) {
                        if heroLoading[item.id] == true { LucentPosterLoadingIndicator() }
                    }
                HStack(spacing: 7) {
                    let rating = displayItem.communityRating
                    let date = heroDisplayDate(for: displayItem)
                    let showsRating = (rating ?? 0) > 0
                    if let rating, rating > 0 {
                        Image(systemName: "star.fill").foregroundStyle(.orange)
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                    }
                    if let date {
                        Text((showsRating ? "·  " : "") + date)
                    }
                    if let genres = displayItem.genres, !genres.isEmpty {
                        Text((showsRating || date != nil ? "·  " : "") + genres.prefix(2).joined(separator: "、")).lineLimit(1)
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(darkMode ? Color.white : Color.black)
                if let overview = displayItem.overview, !overview.isEmpty {
                    Text(overview).font(.footnote)
                        .foregroundStyle(darkMode ? Color.white.opacity(0.86) : Color.gray)
                        .lineLimit(3)
                        .frame(height: 54, alignment: .top)
                } else { Color.clear.frame(height: 54) }
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
        .padding(.bottom, 42)
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
        heroSettleTask?.cancel()
        heroSettleTask = Task { @MainActor in
            do { try await Task.sleep(for: .milliseconds(470)) } catch { return }
            outgoingHeroIndex = nil
            heroTransitioning = false
        }
    }

    private func rememberHeroSelection(at index: Int) {
        guard let source, latest.indices.contains(index) else { return }
        let id = latest[index].id
        HomeSnapshotCache.selectedHeroIDs[source.id] = id
        guard !localLibrary else { return }
        let context = HomeStartupCache.context(source: source, language: contentLocalizationID)
        Task { await HomeStartupCache.shared.update(id: source.id, context: context, selection: id) }
    }

    private func isResumeCandidate(_ remote: MediaCard) -> Bool {
        homeResumeCandidate(remote.legacyPresentation, sourceID: source?.id, localItems: library.items)
    }

    private func loadHeroArtwork(at index: Int) async {
        guard localLibrary || canRefreshServerShelves,
              !Task.isCancelled, let source, latest.indices.contains(index) else { return }
        let item = latest[index]
        guard heroArtworks[item.id] == nil,
              let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else { return }
        let context = homeContext
        let requestedLanguage = LocalizationPreferences.current.contentID
        let result = try? await TMDBService.detailArtwork(remote: (heroDetails[item.id] ?? item).legacyPresentation, metadata: nil,
            title: item.name, television: item.type == "Series",
            language: TMDBService.deviceLanguage, token: token,
            displayWidthPixels: Int(UIScreen.main.bounds.width * UIScreen.main.scale))
        // A transient request failure must remain retryable on the next selection.
        guard let result, !Task.isCancelled, context == homeContext,
              requestedLanguage == LocalizationPreferences.current.contentID else { return }
        heroArtworks[item.id] = result
        HomeSnapshotCache.artworks[source.id] = heroArtworks
        if !localLibrary {
            await HomeStartupCache.shared.update(id: source.id, context: context, artworkID: item.id, artwork: result)
        }
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
                collectionTransitionKey = nil
                if localLibrary { localCollection = .continueWatching }
                else { showAllContinuing = true }
            } label: { heading("继续观看", count: nil) }.buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let source {
                        ForEach(continuing, id: \.id) { item in
                            let key = "continuing:\(source.id):\(item.id)"
                            Button { open(item, transitionKey: key) } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottom) {
                                        EmbyArtwork(source: source, itemID: item.legacyPresentation.seriesId ?? item.id,
                                                    backdrop: true, width: 600, allowsPortraitFallback: false)
                                        LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                                       startPoint: .center, endPoint: .bottom)
                                        LucentPlaybackProgressOverlay(
                                            position: Double(item.userData?.playbackPositionTicks ?? 0) / 10_000_000,
                                            duration: item.runTimeTicks.map { Double($0) / 10_000_000 }, progress: progress(item))
                                    }
                                    .frame(width: HomePalette.continueWidth,
                                           height: HomePalette.isPad ? 160 : 110)
                                    .clipShape(RoundedRectangle(cornerRadius: 16))
                                    .modifier(HomeMatchedSource(key: key, namespace: detailTransition, sourceBackground: themeColor))
                                    HomeContinuingCaption(item: item,
                                        cachedYear: library.cardMetadata[LibraryStore.cardKey(sourceID: source.id, itemID: item.id)]?.year)
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
                collectionTransitionKey = nil
                if localLibrary { localCollection = .mediaLibraries }
                else if let source { browserRoute = HomeBrowserRoute(source:source,parentID:nil,title:"我的媒体") }
            } label: { heading("我的媒体", count: nil) }.buttonStyle(.plain)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    if let source {
                        ForEach(views, id: \.id) { view in
                            let key = "media:\(source.id):\(view.id)"
                            Button {
                                collectionTransitionKey = key
                                if localLibrary { localCollection = LocalCatalogCollection(rawValue: view.id) }
                                else { browserRoute = HomeBrowserRoute(source: source, parentID: view.id, title: view.name, collectionType: view.legacyPresentation.collectionType) }
                            } label: {
                                ZStack(alignment: .bottomLeading) {
                                    if !localLibrary {
                                        EmbyArtwork(source: source, itemID: view.id,
                                                    backdrop: false, width: 500, stretchesImage: true)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.categoryHeight)
                                            .clipped()
                                    } else if let first = shelves.first(where: { $0.id == view.id })?.items.first,
                                              let item = HomeSnapshotCache.localItems[first.id] {
                                        LocalCatalogArtwork(item: item, landscape: true, backdropOnly: true)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.categoryHeight)
                                            .clipped()
                                    } else {
                                        LinearGradient(colors: [.init(red: 0.34, green: 0.51, blue: 0.52),
                                                                .init(red: 0.18, green: 0.27, blue: 0.36)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing)
                                            .frame(width: HomePalette.categoryWidth,
                                                   height: HomePalette.categoryHeight)
                                    }
                                    LinearGradient(colors: [.clear, .black.opacity(0.82)],
                                                   startPoint: .center, endPoint: .bottom)
                                        .frame(width: HomePalette.categoryWidth,
                                               height: HomePalette.categoryHeight)
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
                                       height: HomePalette.categoryHeight)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                .modifier(HomeMatchedSource(key: key, namespace: detailTransition, sourceBackground: themeColor))
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
                collectionTransitionKey = nil
                if let source {
                    if localLibrary { localCollection = LocalCatalogCollection(rawValue: shelf.view.id) }
                    else { browserRoute = HomeBrowserRoute(source: source, parentID: shelf.view.id, title: shelf.view.name, collectionType: shelf.view.legacyPresentation.collectionType) }
                }
            } label: {
                heading(shelf.view.name, count: nil)
            }
            .buttonStyle(.plain)
            if let error = shelfErrors[shelf.id] {
                Text(error).font(.caption).foregroundStyle(.secondary).padding(.horizontal, HomePalette.inset)
            }
            if shelf.items.isEmpty && shelfErrors[shelf.id] == nil {
                Text("打开媒体库查看全部")
                    .font(.subheadline)
                    .foregroundStyle(HomePalette.muted)
                    .padding(.horizontal, HomePalette.inset)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 14) {
                    if let source {
                        ForEach(shelf.items, id: \.id) { item in
                            let metadata = library.cardMetadata[LibraryStore.cardKey(sourceID: source.id, itemID: item.id)]
                            Button { open(item, transitionKey: "shelf:\(shelf.id):\(item.id)") } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    ZStack(alignment: .bottomTrailing) {
                                        EmbyArtwork(source: source, itemID: item.id,
                                                    backdrop: false, width: LucentUI.catalogPosterRequestWidth)
                                        if let rating = metadata?.rating ?? item.communityRating ?? heroDetails[item.id]?.communityRating, rating > 0 {
                                            LucentRatingBadge(rating: rating)
                                                .padding(4)
                                        }
                                    }
                                    .frame(width: HomePalette.posterWidth,
                                           height: HomePalette.isPad ? 240 : 158)
                                    .clipShape(RoundedRectangle(cornerRadius: 15))
                                    .modifier(HomeMatchedSource(key: "shelf:\(shelf.id):\(item.id)",
                                                                namespace: detailTransition))
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(metadata?.title ?? item.name).font(.footnote.weight(.medium))
                                            .foregroundStyle(HomePalette.ink)
                                            .lineLimit(1, reservesSpace: true)
                                        Text(metadata?.year ?? item.yearText ?? " ").font(.caption)
                                            .foregroundStyle(HomePalette.muted)
                                            .lineLimit(1, reservesSpace: true)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
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
            collectionTransitionKey = nil
            browserRoute = HomeBrowserRoute(source: source, parentID: item.id, title: item.name)
            return
        }
        selectedTransitionKey = transitionKey
        selectedItemID = library.openEmbyItem(sourceID: source.id, remote: item.legacyPresentation).id
    }

    private func transitionSource<Content: View>(_ content: Content, key: String) -> some View {
        content.modifier(HomeMatchedSource(key: key, namespace: detailTransition, sourceBackground: themeColor))
    }

    @ViewBuilder private func detailDestination(_ id: UUID) -> some View {
        if #available(iOS 18.0, *), let selectedTransitionKey {
            MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } })
                .environmentObject(library)
                .navigationTransition(.zoom(sourceID: selectedTransitionKey, in: detailTransition))
        } else {
            MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
        }
    }

    private func refreshLocalContinuing() async {
        let files = library.localLibraryItems.filter { $0.missingSince == nil }
        let result = await Task.detached(priority: .utility) {
            Dictionary(grouping: files.filter { $0.isInProgress && $0.metadata != nil }, by: \.catalogGroupID).values.compactMap { $0.max { ($0.lastPlayedAt ?? .distantPast) < ($1.lastPlayedAt ?? .distantPast) } }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                .map { MediaCard(local: $0, asSeries: $0.identity?.seriesName != nil) }
        }.value
        guard !Task.isCancelled else { return }
        cachedContinuing = result; cachedContinuingTotal = result.count
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
        cachedContinuing = result.1
        cachedContinuingTotal = continuing.count
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
        errorMessage = nil
    }

    private func waitForHomeScrollToSettle() async throws {
        while homeScrollIsActive {
            try await Task.sleep(for: .milliseconds(150))
        }
        try Task.checkCancellation()
    }

    private func loadHome(manualRefresh: Bool = false) async {
        let context = homeContext
        if displayedHomeContext != context {
            displayedHomeContext = context
            views = []; latest = []; cachedContinuing = []; cachedContinuingTotal = 0; shelves = []
            heroIndex = 0; indicatorIndex = 0; outgoingHeroIndex = nil
            heroArtworks = [:]; heroDetails = [:]; heroThemes = [:]; heroThemeImages = [:]
            selectedTheme = nil
            restoredSnapshotKey = nil
            hasLoadedHome = false
            errorMessage = nil
        }
        let requestID = UUID()
        homeLoadID = requestID
        var wasCancelled = false
        func isCancellation(_ error: Error) -> Bool {
            Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled
        }
        HomeSnapshotCache.trim(validSources: Set(library.embySources.map(\.id)).union([HomeSnapshotCache.localContext.id]))
        if localLibrary { await loadLocalHome(); return }
        guard let source else {
            views = []; latest = []; cachedContinuing = []; cachedContinuingTotal = 0; shelves = []
            heroIndex = 0; indicatorIndex = 0
            heroArtworks = [:]; heroDetails = [:]; heroThemes = [:]
            selectedTheme = nil
            hasLoadedHome = false
            return
        }
        if let snapshot = HomeSnapshotCache.entries[source.id],
           !manualRefresh, snapshot.context == context, snapshot.refreshID == refreshID,
           Date().timeIntervalSince(snapshot.loadedAt) < HomeSnapshotCache.lifetime {
            isLoading = false
            let snapshotKey = "\(source.id)|\(snapshot.refreshID)|\(snapshot.loadedAt.timeIntervalSinceReferenceDate)|\(minimumResumePercent)|\(completedPercent)"
            let resumed = snapshot.continuing.filter(isResumeCandidate)
            if hasLoadedHome, restoredSnapshotKey == snapshotKey, continuing.map(\.id) == resumed.map(\.id) { return }
            await prepareContinuingCovers(resumed, source: source)
            guard !Task.isCancelled, homeLoadID == requestID else { return }
            restoredSnapshotKey = snapshotKey
            views = snapshot.views
            latest = snapshot.latest
            cachedContinuing = resumed
            cachedContinuingTotal = snapshot.continuingTotal
            shelves = snapshot.shelves
            heroArtworks = HomeSnapshotCache.artworkLanguage == contentLocalizationID ? HomeSnapshotCache.artworks[source.id] ?? [:] : [:]
            heroDetails = HomeSnapshotCache.details[source.id] ?? [:]
            heroThemes = HomeSnapshotCache.themes[source.id] ?? [:]
            let selectedID = HomeSnapshotCache.selectedHeroIDs[source.id]
            heroIndex = selectedID.flatMap { id in latest.firstIndex(where: { $0.id == id }) } ?? 0
            indicatorIndex = heroIndex
            selectedTheme = latest.indices.contains(heroIndex) ? heroThemes[latest[heroIndex].id] : nil
            hasLoadedHome = true
            errorMessage = nil
            return
        }
        shelfErrors = [:]
        let startupContext = HomeStartupCache.context(source: source, language: contentLocalizationID)
        var restoredStartup = false
        if !manualRefresh, let seed = await HomeStartupCache.shared.read(id: source.id, context: startupContext) {
            guard !Task.isCancelled, homeLoadID == requestID else { return }
            let resumed = seed.continuing.filter(isResumeCandidate)
            await prepareContinuingCovers(resumed, source: source)
            guard !Task.isCancelled, homeLoadID == requestID else { return }
            views = seed.views
            latest = seed.latest
            cachedContinuing = resumed
            cachedContinuingTotal = seed.continuingTotal
            shelves = seed.shelves.map { HomeShelf(view: $0.view, items: $0.items) }
            heroArtworks = seed.artworks
            HomeSnapshotCache.artworks[source.id] = seed.artworks
            heroIndex = seed.selectedHeroID.flatMap { id in latest.firstIndex { $0.id == id } } ?? 0
            indicatorIndex = heroIndex
            hasLoadedHome = true
            restoredStartup = true
        }
        if pausesHomeRefreshForComparison && !manualRefresh && restoredStartup {
            isLoading = false
            hasLoadedHome = true
            errorMessage = nil
            return
        }
        if !restoredStartup { manualRefreshSourceID = source.id }
        isLoading = true
        errorMessage = nil
        defer {
            if homeLoadID == requestID {
                isLoading = false
                if !wasCancelled && !Task.isCancelled { hasLoadedHome = true }
            }
        }
        do {
            guard let token = try KeychainPasswordStore.embyToken(for: source.id), !token.isEmpty else {
                errorMessage = "Emby 登录已失效，请在片源页面更新令牌。"
                return
            }
            async let viewsRequest = EmbyClient.browse(source: source, token: token, parentID: nil)
            async let latestRequest = EmbyClient.latest(source: source, token: token)
            async let resumeRequest = library.refreshEmbyContinuing(source: source, token: token)
            let recentMovies = try await latestRequest
            let priorIDs = latest.map(\.id)
            let fetchedLatest = await Task.detached(priority: .utility) {
                let candidates = recentMovies.map { MediaCard(server: $0) }
                    .filter { $0.type == "Movie" || $0.type == "Series" }
                let byID = Dictionary(candidates.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let prior = priorIDs.compactMap { byID[$0] }
                let retainedIDs = Set(priorIDs)
                return Array((prior + candidates.filter { !retainedIDs.contains($0.id) }.shuffled()).prefix(8))
            }.value
            try Task.checkCancellation()
            guard homeLoadID == requestID else { return }
            let (viewPage, resumePage) = try await (viewsRequest, resumeRequest)
            try Task.checkCancellation()
            guard homeLoadID == requestID else { return }
            let requestedAt = Date()
            var results: [String: [MediaCard]] = [:]
            var errors: [String: String] = [:]
            for start in stride(from: 0, to: viewPage.items.count, by: 4) {
                try Task.checkCancellation()
                let batch = viewPage.items[start..<min(start + 4, viewPage.items.count)]
                await withTaskGroup(of: (String, [MediaCard]?, String?).self) { group in
                    for view in batch {
                        group.addTask {
                            do {
                                let page = try await EmbyClient.featured(source: source, token: token, parentID: view.id,
                                    itemTypes: EmbyClient.featuredItemTypes(for: view))
                                return (view.id, page.items.map { MediaCard(server: $0) }, nil)
                            } catch {
                                return (view.id, nil, error.localizedDescription)
                            }
                        }
                    }
                    for await (id, cards, error) in group {
                        results[id] = cards
                        errors[id] = error
                    }
                }
            }
            try Task.checkCancellation()
            let previousShelves = shelves
            let loadedRows = results
            let (fetchedViews, fetchedShelves, displayed) = await Task.detached(priority: .utility) {
                let views = viewPage.items.map { MediaCard(server: $0) }
                let retained = Dictionary(previousShelves.map { ($0.id, $0.items) }, uniquingKeysWith: { _, last in last })
                let rows = views.map { HomeShelf(view: $0, items: loadedRows[$0.id] ?? retained[$0.id] ?? []) }
                let cards = fetchedLatest + resumePage.items.map { MediaCard(server: $0) } + loadedRows.values.flatMap { $0 }
                return (views, rows, cards)
            }.value
            try Task.checkCancellation()
            guard homeLoadID == requestID else { return }
            // List metadata is authoritative; batch only genuinely missing year or rating.
            let missingIDs = Array(Set(displayed.filter { card in
                let cached = library.cardMetadata[LibraryStore.cardKey(sourceID: source.id, itemID: card.id)]
                return (card.year == nil && cached?.year == nil) || (card.rating == nil && cached?.rating == nil)
            }.map(\.id))).sorted()
            var enriched: [String: MediaCard] = [:]
            if !missingIDs.isEmpty {
                do {
                    let batch = try await ServerCatalogSync.cachedItems(base: source.baseAddress,
                        userID: source.userID, token: token, ids: missingIDs,
                        fields: "Overview,Genres,ProviderIds,PreferredMetadataLanguage,CommunityRating,ProductionYear")
                    try Task.checkCancellation()
                    enriched = Dictionary(batch.map { ($0.id, MediaCard(server: $0)) }, uniquingKeysWith: { _, last in last })
                } catch is CancellationError { wasCancelled = true; return }
                catch {
                    if isCancellation(error) { wasCancelled = true; return }
                    guard homeLoadID == requestID else { return }
                    errorMessage = "首页已加载，部分影片资料补取失败，请稍后刷新。" }
            }
            let originals = Dictionary(displayed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            enriched = enriched.mapValues { value in
                originals[value.id].map { value.preservingMetadata(from: $0) } ?? value
            }
            func resolved(_ card: MediaCard) -> MediaCard { enriched[card.id]?.preservingMetadata(from: card) ?? card }
            try await waitForHomeScrollToSettle()
            guard homeLoadID == requestID, homeContext == context else { return }
            views = fetchedViews
            shelves = fetchedShelves.map { HomeShelf(view: $0.view, items: $0.items.map(resolved)) }
            shelfErrors = errors
            let resolvedItems = Dictionary(displayed.map(resolved).map { ($0.id, $0.legacyPresentation) },
                                           uniquingKeysWith: { _, last in last }).values.map { $0 }
            library.mergeServerCards(resolvedItems, sourceID: source.id, requestedAt: requestedAt)
            hasLoadedHome = true
            outgoingHeroIndex = nil
            let selectedHeroID = latest.indices.contains(heroIndex) ? latest[heroIndex].id : nil
            latest = fetchedLatest.map(resolved)
            heroIndex = selectedHeroID.flatMap { id in latest.firstIndex { $0.id == id } } ?? 0
            indicatorIndex = heroIndex
            HomeSnapshotCache.selectedHeroIDs[source.id] = latest.indices.contains(heroIndex) ? latest[heroIndex].id : nil
            heroDetails = enriched
            HomeSnapshotCache.artworks[source.id] = heroArtworks
            HomeSnapshotCache.details[source.id] = enriched
            HomeSnapshotCache.themes[source.id] = heroThemes
            cachedContinuing = resumePage.items.map { resolved(MediaCard(server: $0)) }.filter(isResumeCandidate)
            cachedContinuingTotal = resumePage.totalCount
            do { try await library.synchronizeServerHome(sourceID: source.id, emby: true,
                displayedItems: resolvedItems) }
            catch is CancellationError { wasCancelled = true; return }
            catch {
                if isCancellation(error) { wasCancelled = true; return }
                guard homeLoadID == requestID else { return }
                errorMessage = "首页已刷新，部分已打开条目未能同步，请稍后重试。" }
            guard homeLoadID == requestID else { return }
            try Task.checkCancellation()
            // A successfully fetched empty library is authoritative too; replace stale snapshots.
            HomeSnapshotCache.entries[source.id] = .init(
                refreshID: refreshID, context: context, loadedAt: Date(), views: views, latest: latest,
                continuing: resumePage.items.map { resolved(MediaCard(server: $0)) }, continuingTotal: continuingTotal, shelves: shelves)
            let startup = HomeStartupSnapshot(version: 1, context: startupContext, savedAt: Date(),
                views: views, latest: latest,
                continuing: resumePage.items.map { resolved(MediaCard(server: $0)) }, continuingTotal: continuingTotal,
                shelves: shelves.map { .init(view: $0.view, items: $0.items) },
                artworks: heroArtworks, selectedHeroID: latest.indices.contains(heroIndex) ? latest[heroIndex].id : nil)
            await HomeStartupCache.shared.write(id: source.id, value: startup)
            guard !Task.isCancelled, homeLoadID == requestID else { return }
            if let snapshot = HomeSnapshotCache.entries[source.id] {
                restoredSnapshotKey = "\(source.id)|\(snapshot.refreshID)|\(snapshot.loadedAt.timeIntervalSinceReferenceDate)|\(minimumResumePercent)|\(completedPercent)"
            }
        } catch {
            if isCancellation(error) { wasCancelled = true; return }
            guard homeLoadID == requestID else { return }
            errorMessage = "无法读取推荐内容：\(error.localizedDescription)"
        }
    }
}

@MainActor private func homeResumeCandidate(_ remote: JellyfinItem, sourceID: UUID?, localItems: [MediaItem]) -> Bool {
    if let sourceID, let local = localItems.first(where: { item in
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

private struct HomeContinuingCaption: View {
    let item: MediaCard
    var cachedYear: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            LucentPosterCaption(title: item.seriesName ?? item.name, lines: 1)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(HomePalette.muted).lineLimit(1)
            }
        }
    }

    private var subtitle: String? {
        guard let season = item.season, let episode = item.episode, episode > 0 else {
            return item.yearText ?? cachedYear
        }
        let label = season == 0 ? MediaIdentity.specialEpisodeTitle(episode) : "S\(season):E\(episode)"
        return item.kind == "Episode" && item.name != item.seriesName ? "\(label) - \(item.name)" : label
    }
}

private struct HomeContinuingList: View {
    @EnvironmentObject private var library: LibraryStore
    let source: EmbySource
    let onBack: () -> Void
    @State private var items: [JellyfinItem] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selectedID: UUID?
    var body: some View {
        Group {
            ScrollView {
                LazyVGrid(columns:[GridItem(.adaptive(minimum:160), alignment: .top)],alignment:.leading,spacing:18) {
                    ForEach(items,id:\.id) { item in
                        Button { selectedID = library.openEmbyItem(sourceID:source.id,remote:item).id } label: {
                            VStack(alignment:.leading,spacing:8) {
                                EmbyArtwork(source: source, itemID: item.seriesId ?? item.id, backdrop: true, width: 600, allowsPortraitFallback: false)
                                    .frame(height:110)
                                    .overlay(alignment: .bottom) {
                                        LucentPlaybackProgressOverlay(position: Double(item.userData?.playbackPositionTicks ?? 0) / 10_000_000,
                                            duration: item.runTimeTicks.map { Double($0) / 10_000_000 })
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius:14))
                                HomeContinuingCaption(item: MediaCard(server: item))
                            }
                        }.buttonStyle(.plain)
                    }
                }.padding(20)
                if let error { Text(error).foregroundStyle(.secondary).padding() }
                if !loading && error == nil && items.isEmpty { ContentUnavailableView("暂无继续观看内容",systemImage:"play.circle") }
            }
            .overlay {
                if loading { continuingSkeleton }
            }
            .lucentCollectionChrome(title: "继续观看") { EmptyView() }
            .navigationDestination(item:$selectedID) { id in
                Group {
                    MediaDetailView(itemID: id, onBack: { withAnimation { selectedID = nil } }).environmentObject(library)
                }.lucentSecondaryPage()
            }
            .task {
                defer { loading = false }
                do {
                    guard let token = try KeychainPasswordStore.embyToken(for:source.id) else { throw URLError(.userAuthenticationRequired) }
                    items = try await EmbyClient.resume(source:source,token:token,limit:10000).items
                        .filter { homeResumeCandidate($0, sourceID: source.id, localItems: library.items) }
                } catch { self.error = error.localizedDescription }
            }
        }
    }
    private var continuingSkeleton: some View {
        GeometryReader { proxy in
            let columns = max(2, Int((proxy.size.width - 40 + 18) / 178))
            let rows = max(3, Int((proxy.size.height / 176).rounded(.up)))
            LazyVGrid(columns:[GridItem(.adaptive(minimum:160), alignment: .top)],alignment:.leading,spacing:18) {
                ForEach(0..<(columns * rows), id:\.self) { _ in
                    VStack(alignment:.leading,spacing:8) {
                        DetailSkeletonBlock(cornerRadius:14)
                            .frame(height:110)
                        DetailSkeletonBlock()
                            .frame(width:140,height:12)
                        DetailSkeletonBlock()
                            .frame(width:80,height:10)
                    }
                }
            }
            .padding(20)
        }
        .accessibilityHidden(true)
    }
}

private enum SearchEntry: Identifiable, Sendable {
    case emby(EmbySource, JellyfinItem)
    case jellyfin(JellyfinSource, JellyfinItem)
    case plex(PlexSource, PlexItem)

    var metadataKey: String {
        switch self {
        case .emby(let source, let item): LibraryStore.cardKey(sourceID: source.id, itemID: item.id)
        case .jellyfin(let source, let item): LibraryStore.cardKey(sourceID: source.id, itemID: item.id)
        case .plex(let source, let item): LibraryStore.cardKey(sourceID: source.id, itemID: item.ratingKey)
        }
    }

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
    var serverAsset: String {
        switch self {
        case .emby(let source, _): source.kind.assetName
        case .jellyfin: "JellyfinBrand"
        case .plex: "PlexBrand"
        }
    }
    var rating: Double? {
        switch self {
        case .emby(_, let item), .jellyfin(_, let item): item.communityRating
        case .plex(_, let item): item.rating
        }
    }
    var year: String? {
        switch self {
        case .emby(_, let item), .jellyfin(_, let item): item.displayYearText
        case .plex(_, let item): item.year.map(String.init)
        }
    }
}

private struct SearchGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let entries: [SearchEntry]
}

private struct SearchResultsPage: Identifiable, Hashable {
    let id = UUID()
    let term: String
    let localItems: [MediaItem]
    let serverItems: [SearchEntry]

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

private struct SearchRemotePoster: View {
    let request: URLRequest?
    let cacheKey: String
    var body: some View { LucentRemoteArtwork(request: request, cacheKey: cacheKey) }
}

struct MobileSearchView: View {
    @State private var searchPresented = false
    @FocusState private var searchFocused: Bool
    @EnvironmentObject private var library: LibraryStore
    let isSelected: Bool
    @Binding var detailPresented: Bool
    @Binding var query: String
    @Binding var submittedQuery: String

    @State private var groups: [SearchGroup] = []
    @State private var localResults: [MediaItem] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var selectedItemID: UUID?
    @State private var selectedResultsPage: SearchResultsPage?
    @State private var completedSearchTerm: String?
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
        !localResults.isEmpty || groups.contains { !$0.entries.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {
                searchHistoryContent
                    .listRowInsets(EdgeInsets(top: 8, leading: 20, bottom: 16, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                if !term.isEmpty {
                    Group {
                        searchResultsContent
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 26, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color(uiColor: .systemGroupedBackground))
            .overlay {
                if term.isEmpty || (!loading && errorMessage == nil && !hasResults) {
                    VStack(spacing: 16) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 84, weight: .light))
                            .accessibilityHidden(true)
                        Text("搜索聚合媒体库和影音服务器内容")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.secondary)
                    .allowsHitTesting(false)
                }
            }
            .navigationTitle("搜索")
            .navigationBarTitleDisplayMode(.large)
            .searchable(text: $query, isPresented: $searchPresented,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索影片和剧集")
            .searchFocused($searchFocused)
            .task(id: isSelected) {
                guard isSelected else {
                    searchFocused = false
                    return
                }
                if !term.isEmpty, hasResults {
                    query = submittedQuery
                    return
                }
                if !searchPresented {
                    searchPresented = true
                }
                await Task.yield()
                guard !Task.isCancelled, isSelected else { return }
                searchFocused = true
            }
            .onChange(of: searchPresented) { wasPresented, isPresented in
                guard isSelected, wasPresented, !isPresented else { return }
                clearSubmittedSearch()
            }
            .onSubmit(of: .search) {
                submittedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .toolbar(.visible, for: .navigationBar)
            .lucentTabRoot()
            .task(id: term) { await search() }
            .navigationDestination(item: $selectedItemID) { id in
                Group {
                    MediaDetailView(itemID: id, onBack: { withAnimation { selectedItemID = nil } }).environmentObject(library)
                }.lucentSecondaryPage()
            }
            .navigationDestination(item: $selectedResultsPage) { page in
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 20) {
                        ForEach(page.localItems) { localResultButton($0) }
                        ForEach(page.serverItems) { entryButton($0) }
                    }
                    .padding(20)
                }
                .scrollIndicators(.hidden)
                .navigationTitle(page.term)
                .navigationBarTitleDisplayMode(.inline)
                .lucentSecondaryPage()
            }
            .onChange(of: selectedItemID) { _, value in
                detailPresented = value != nil
            }
        }
    }

    private func clearSubmittedSearch() {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            submittedQuery = ""
        }
    }

    @ViewBuilder private var searchHistoryContent: some View {
        if !history.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("最近搜索").font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("清除") { historyJSON = "[]" }
                        .buttonStyle(.borderless)
                        .font(.subheadline)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(history, id: \.self) { value in
                            Button {
                                query = value
                                submittedQuery = value
                            } label: {
                                Text(value)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                                in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var searchResultsContent: some View {
        if loading {
            ProgressView("正在搜索…")
                .frame(maxWidth: .infinity).padding(.top, 36)
        }
        if let errorMessage {
            Text(errorMessage).font(.subheadline).foregroundStyle(.secondary)
        }
        if !localResults.isEmpty {
            let items = localResults
            resultSection(title: "聚合媒体库", items: items,
                          page: SearchResultsPage(term: term, localItems: items, serverItems: []),
                          card: localResultButton)
        }
        ForEach(groups) { group in
            resultSection(title: group.title, asset: group.entries.first?.serverAsset, items: group.entries,
                          page: SearchResultsPage(term: term, localItems: [], serverItems: group.entries),
                          card: entryButton)
        }
    }

    private func resultSection<Item: Identifiable, Card: View>(
        title: String, asset: String? = nil, items: [Item], page: SearchResultsPage, @ViewBuilder card: @escaping (Item) -> Card
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                selectedResultsPage = page
            } label: {
                HStack {
                    LucentSourceLabel(title: title, asset: asset).font(.headline)
                    Spacer()
                    Text("\(items.count)")
                        .font(.subheadline)
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("查看该来源的搜索结果")

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { item in
                        card(item).frame(width: 106)
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func localResultButton(_ item: MediaItem) -> some View {
        Button { selectedItemID = item.id } label: {
            posterCard(title: item.catalogDisplayTitle, subtitle: item.catalogDisplayYearText, rating: item.metadata?.rating) {
                if let url = library.posterURL(for: item) {
                    LocalPosterView(url: url)
                } else {
                    posterPlaceholder
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func entryButton(_ entry: SearchEntry) -> some View {
        let metadata = library.cardMetadata[entry.metadataKey]
        return Button { open(entry) } label: {
            posterCard(title: metadata?.title ?? entry.title, subtitle: metadata?.year ?? entry.year, rating: metadata?.rating ?? entry.rating) {
                entryPoster(entry)
            }
        }
        .buttonStyle(.plain)
    }

    private func posterCard<Poster: View>(
        title: String, subtitle: String?, rating: Double?, @ViewBuilder poster: @escaping () -> Poster
    ) -> some View {
        LucentCatalogPosterLayout {
            Color.clear
                .aspectRatio(LucentUI.posterAspectRatio, contentMode: .fit)
                .overlay {
                    GeometryReader { geometry in
                        poster()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let rating { LucentRatingBadge(rating: rating).padding(3) }
                }
                .clipShape(RoundedRectangle(cornerRadius: LucentUI.cardRadius))
        } caption: {
            LucentCatalogCaption(title: title, yearText: subtitle)
        }
    }

    private var posterPlaceholder: some View {
        Rectangle().fill(Color(uiColor: .secondarySystemGroupedBackground))
            .overlay { Image(systemName: "film").font(.title).foregroundStyle(.tertiary) }
    }

    @ViewBuilder private func entryPoster(_ entry: SearchEntry) -> some View {
        switch entry {
        case .emby(let source, let item):
            EmbyArtwork(source: source, itemID: item.id, backdrop: false, width: LucentUI.catalogPosterRequestWidth)
        case .jellyfin(let source, let item):
            SearchRemotePoster(
                request: (try? KeychainPasswordStore.jellyfinToken(for: source.id))
                    .flatMap { JellyfinClient.posterRequest(source: source, token: $0, itemID: item.id) },
                cacheKey: "jellyfin|\(source.id)|\(item.id)")
        case .plex(let source, let item):
            SearchRemotePoster(
                request: (try? KeychainPasswordStore.plexToken(for: source.id)).flatMap { token in
                    item.thumb.flatMap { PlexClient.posterRequest(source: source, token: token, thumb: $0) }
                },
                cacheKey: "plex|\(source.id)|\(item.ratingKey)")
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
        let searchTerm = term
        guard completedSearchTerm != searchTerm else { return }
        completedSearchTerm = nil
        guard !searchTerm.isEmpty else {
            groups = []
            localResults = []
            errorMessage = nil
            loading = false
            return
        }
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
        let requestedAt = Date()
        let found = await withTaskGroup(of: (SearchGroup?, String?).self) { taskGroup in
            for source in emby {
                taskGroup.addTask {
                    do {
                        guard let token = try KeychainPasswordStore.embyToken(for: source.id),
                              !token.isEmpty else { return (nil, source.name) }
                        let page = try await EmbyClient.search(source: source, token: token, term: searchTerm)
                        guard !page.items.isEmpty else { return (nil, nil) }
                        return (SearchGroup(id: "emby|\(source.id)", title: source.name,
                                            entries: page.items.map { .emby(source, $0) }), nil)
                    } catch { return (nil, source.name) }
                }
            }
            for source in jellyfin {
                taskGroup.addTask {
                    do {
                        guard let token = try KeychainPasswordStore.jellyfinToken(for: source.id),
                              !token.isEmpty else { return (nil, source.name) }
                        let items = try await JellyfinClient.search(source: source, token: token, term: searchTerm)
                        guard !items.isEmpty else { return (nil, nil) }
                        return (SearchGroup(id: "jellyfin|\(source.id)", title: source.name,
                                            entries: items.map { .jellyfin(source, $0) }), nil)
                    } catch { return (nil, source.name) }
                }
            }
            for source in plex {
                taskGroup.addTask {
                    do {
                        guard let token = try KeychainPasswordStore.plexToken(for: source.id),
                              !token.isEmpty else { return (nil, source.name) }
                        let items = try await PlexClient.search(source: source, token: token, term: searchTerm)
                        guard !items.isEmpty else { return (nil, nil) }
                        return (SearchGroup(id: "plex|\(source.id)", title: source.name,
                                            entries: items.map { .plex(source, $0) }), nil)
                    } catch { return (nil, source.name) }
                }
            }
            var results: [SearchGroup] = []
            var failures: [String] = []
            for await (group, failure) in taskGroup {
                if let group { results.append(group) }
                if let failure { failures.append(failure) }
            }
            return (results, failures)
        }
        guard !Task.isCancelled, term == searchTerm else { return }
        let records = found.0.flatMap(\.entries).map { entry in
            (entry.metadataKey, LibraryStore.CardMetadata(title: entry.title, year: entry.year,
                                                         rating: entry.rating, updatedAt: requestedAt))
        }
        library.mergeCardMetadata(Dictionary(records, uniquingKeysWith: { _, latest in latest }))
        completedSearchTerm = searchTerm
        groups = found.0.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        if !found.1.isEmpty {
            errorMessage = "部分来源搜索失败：\(found.1.sorted().joined(separator: "、"))"
        }
        loading = false
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
