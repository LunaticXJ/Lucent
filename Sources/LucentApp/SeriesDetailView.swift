import SwiftUI

struct DetailSkeletonBlock: View {
    var cornerRadius: CGFloat = 12
    var body: some View { LucentSkeleton(radius: cornerRadius) }
}

struct DetailActionSkeleton: View {
    var body: some View {
        HStack(spacing: 42) {
            DetailSkeletonBlock().frame(width: 24, height: 24)
            DetailSkeletonBlock().frame(width: 24, height: 24)
        }
        .padding(.top, 8)
        .accessibilityHidden(true)
    }
}

struct DetailMediaSkeleton: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            DetailSkeletonBlock().frame(width: 92, height: 22)
            HStack(spacing: 12) {
                DetailSkeletonBlock(cornerRadius: 18).frame(width: LucentUI.detailSize(144), height: 84)
                DetailSkeletonBlock(cornerRadius: 18).frame(width: LucentUI.detailSize(144), height: 84)
            }
        }
        .accessibilityHidden(true)
    }
}


struct SeriesArtwork: View {
    let baseAddress: String?
    let token: String?
    let itemID: String?
    let backdrop: Bool
    let fallback: URL?
    var preferredURL: URL? = nil
    var maximumWidth: Int = 600
    var fallbackToBackdrop = false
    var targetPixelSize: CGSize? = nil
    @State private var serverLoading = true
    private var decodeLimit: Int { targetPixelSize == nil ? 1600 : 4096 }
    var onImage: ((LucentPlatformImage) -> Void)? = nil
    @State private var preferredImage: LucentPlatformImage?
    @State private var preferredFailed = false
    @State private var image: LucentPlatformImage?
    @State private var localImage: LucentPlatformImage?

    var body: some View {
        Group {
            if let preferredImage {
                Image(lucentImage: preferredImage).resizable().scaledToFill()
            } else if preferredURL != nil && !preferredFailed {
                DetailSkeletonBlock(cornerRadius: 0)
            } else if let image {
                Image(lucentImage: image).resizable().scaledToFill()
            } else if let localImage {
                Image(lucentImage: localImage).resizable().scaledToFill()
            } else {
                DetailSkeletonBlock(cornerRadius: 0)
            }
        }
        .clipped()
        .onChange(of: preferredImage ?? image ?? localImage) { _, loaded in
            if let loaded { onImage?(loaded) }
        }
        .task(id: "\(fallback?.absoluteString ?? "")|\(preferredFailed)|\(serverLoading)|\(maximumWidth)|\(targetPixelSize?.width ?? 0)x\(targetPixelSize?.height ?? 0)") {
            guard let fallback else { localImage = nil; return }
            if !fallback.isFileURL {
                guard !serverLoading, image == nil, preferredURL == nil || preferredFailed else { return }
            }
            let key = "detail-file|\(fallback.absoluteString)"
            let limit = targetPixelSize == nil ? maximumWidth : 4096
            if let cached = ArtworkImageDecoder.cachedImage(key: key, maximumPixelSize: limit, targetPixelSize: targetPixelSize) { localImage = cached; return }
            localImage = nil
            let data: Data?
            if fallback.isFileURL {
                data = await Task.detached(priority: .utility) { try? Data(contentsOf: fallback) }.value
            } else {
                data = try? await LocalMediaCache.shared.imageData(key: "tmdb|\(fallback.absoluteString)", fetch: {
                    let (data, response) = try await URLSession.shared.data(from: fallback)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    return data
                })
            }
            guard let data, !Task.isCancelled else { return }
            let decoded = await ArtworkImageDecoder.image(data: data, key: key, maximumPixelSize: limit, targetPixelSize: targetPixelSize)
            guard !Task.isCancelled else { return }
            localImage = decoded
        }
        .task(id: "\(preferredURL?.absoluteString ?? "")|\(targetPixelSize?.width ?? 0)x\(targetPixelSize?.height ?? 0)") {
            preferredFailed = false
            guard let preferredURL else { preferredImage = nil; return }
            if let cached = ArtworkImageDecoder.cachedImage(key: "tmdb|\(preferredURL.absoluteString)", maximumPixelSize: decodeLimit, targetPixelSize: targetPixelSize) {
                if preferredImage !== cached { preferredImage = cached }
                return
            }
            preferredImage = nil
            guard let data = try? await LocalMediaCache.shared.imageData(
                    key: "tmdb|\(preferredURL.absoluteString)", fetch: {
                        let (data, response) = try await URLSession.shared.data(from: preferredURL)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        return data
                    }),
                  !Task.isCancelled, let decoded = await ArtworkImageDecoder.image(data: data, key: "tmdb|\(preferredURL.absoluteString)", maximumPixelSize: decodeLimit, targetPixelSize: targetPixelSize) else {
                if !Task.isCancelled { preferredFailed = true }
                return
            }
            guard !Task.isCancelled else { return }
            preferredImage = decoded
        }
        .task(id: "\(baseAddress ?? "")|\(itemID ?? "")|\(backdrop)|\(preferredURL?.absoluteString ?? "")|\(preferredFailed)|\(maximumWidth)|\(targetPixelSize?.width ?? 0)x\(targetPixelSize?.height ?? 0)") {
            serverLoading = true
            defer { serverLoading = false }
            image = nil
            guard preferredURL == nil || preferredFailed else { return }
            guard let baseAddress, let token, let itemID, let base = URL(string: baseAddress) else { return }
            let path = backdrop || fallbackToBackdrop ? "Backdrop/0" : "Primary"
            var components = URLComponents(url: base.appendingPathComponent("Items")
                .appendingPathComponent(itemID).appendingPathComponent("Images")
                .appendingPathComponent(path), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "maxWidth", value: targetPixelSize != nil ? String(maximumWidth) : (backdrop ? "1400" : String(maximumWidth)))]
            guard let url = components?.url else { return }
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            if let data = try? await LocalMediaCache.shared.imageData(
                key: "server|\(baseAddress)|\(itemID)|\(path)|\(maximumWidth)", fetch: {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                        throw URLError(.badServerResponse)
                    }
                    return data
                }),
               let decoded = await ArtworkImageDecoder.image(data: data, key: "server|\(baseAddress)|\(itemID)|\(path)|\(maximumWidth)", maximumPixelSize: targetPixelSize == nil ? (backdrop ? 1400 : maximumWidth) : 4096, targetPixelSize: targetPixelSize) {
                guard !Task.isCancelled else { return }
                image = decoded
            } else if backdrop {
                request.url = base.appendingPathComponent("Items")
                    .appendingPathComponent(itemID).appendingPathComponent("Images/Primary")
                if let data = try? await LocalMediaCache.shared.imageData(
                    key: "server|\(baseAddress)|\(itemID)|Primary|\(maximumWidth)", fetch: {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                            throw URLError(.badServerResponse)
                        }
                        return data
                    }) {
                    let decoded = await ArtworkImageDecoder.image(data: data, key: "server|\(baseAddress)|\(itemID)|Primary|\(maximumWidth)", maximumPixelSize: targetPixelSize == nil ? maximumWidth : 4096, targetPixelSize: targetPixelSize)
                    guard !Task.isCancelled else { return }; image = decoded
                }
            }
        }
    }
}

struct DetailTitleArtwork: View {
    let url: URL?
    let title: String
    var fallbackRequest: URLRequest? = nil
    var maximumWidth: CGFloat = 310
    var maximumHeight: CGFloat = 125
    var foreground: Color = .white
    @Environment(\.colorScheme) private var colorScheme
    @State private var image: LucentPlatformImage?
    @State private var serverImage: LucentPlatformImage?
    var body: some View {
        Group {
            if let image = image ?? serverImage {
                Image(lucentImage: image).resizable().scaledToFit()
                    .frame(maxWidth: maximumWidth, maxHeight: maximumHeight)
                    .accessibilityLabel(title)
            } else {
                Text(title)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(3).minimumScaleFactor(0.65)
                    .foregroundStyle(colorScheme == .light ? Color.white : foreground)
                    .shadow(color: colorScheme == .light ? .black.opacity(0.45) : .clear, radius: 2, y: 1)
            }
        }
        .shadow(color: .black.opacity(0.6), radius: 8)
        .task(id: url) {
            image = url.flatMap { ArtworkImageDecoder.cachedImage(key: "tmdb|\($0.absoluteString)", maximumPixelSize: 1000) }
            guard let url else { return }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            let loaded = await Self.load(request, key: "tmdb|\(url.absoluteString)")
            guard !Task.isCancelled else { return }
            image = loaded
        }
        .task(id: fallbackRequest?.url) {
            serverImage = nil
            guard let request = fallbackRequest, let url = request.url else { return }
            let key = "logo|\(url.absoluteString)"
            if let cached = ArtworkImageDecoder.cachedImage(key: key, maximumPixelSize: 1000) { serverImage = cached; return }
            let loaded = await Self.load(request, key: key)
            guard !Task.isCancelled else { return }
            serverImage = loaded
        }
    }
    private static func load(_ request: URLRequest, key: String) async -> LucentPlatformImage? {
        guard let data = try? await LocalMediaCache.shared.imageData(key: key, fetch: {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 5_000_000 else { throw URLError(.badServerResponse) }
            return data
        }), !Task.isCancelled else { return nil }
        return await ArtworkImageDecoder.image(data: data, key: key, maximumPixelSize: 1000)
    }
}

struct SeriesDetailView: View {
    #if os(tvOS)
    @Namespace private var detailFocusScope
    #endif
    @Environment(\.discPlaybackControlsHidden) private var discControlsHidden

    @Environment(\.displayScale) private var posterDisplayScale
    @Environment(\.contentLocalizationID) private var contentLocalizationID
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let onPlay: (MediaItem) -> Void
    let onMore: (MediaItem) -> Void
    var onBack: (() -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var posterLightColor = Color(red: 0.94, green: 0.95, blue: 0.96)
    private var detailBackground: Color { colorScheme == .dark ? Color(red: 0.25, green: 0.19, blue: 0.22) : posterLightColor }
    private var detailInk: Color { colorScheme == .dark ? .white : .black }
    @State private var page: ServerEpisodeClient.SeriesPage?
    @State private var season = 1
    @State private var episodePage = 0
    @State private var showAllEpisodes = false
    @State private var editingEpisodes = false
    @State private var selectedEpisodeIDs: Set<String> = []
    @State private var loading = false
    @State private var loadError: String?
    @State private var artwork: TMDBService.DetailArtwork?
    @State private var artworkResolved = false
    @State private var artworkRetriedID: Int?
    @State private var selectedEpisodeID: String?
    @State private var loadedDetailItemID: UUID?
    @State private var synopsisSheet: SynopsisSheet?
    @State private var serverConnection: (base: String, user: String, token: String,
                                          sourceID: UUID, emby: Bool)?
    @State private var localEpisodesByID: [String: MediaItem] = [:]

    private struct SynopsisSheet: Identifiable {
        let title: String
        let text: String
        var id: String { title }
    }

    private var server: (base: String, user: String, token: String, sourceID: UUID, emby: Bool)? {
        serverConnection
    }

    private func resolveServer() -> (base: String, user: String, token: String,
                                     sourceID: UUID, emby: Bool)? {
        switch item.location {
        case .embyItem(let sourceID, _):
            guard let source = library.embySources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.embyToken(for: sourceID) else { return nil }
            return (source.baseAddress, source.userID, token, sourceID, true)
        case .jellyfinItem(let sourceID, _):
            guard let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID) else { return nil }
            return (source.baseAddress, source.userID, token, sourceID, false)
        default: return nil
        }
    }

    private var remoteID: String? {
        switch item.location {
        case .embyItem(_, let id), .jellyfinItem(_, let id): id
        default: nil
        }
    }
    private var episodes: [JellyfinItem] { page?.episodes ?? [] }
    private var seasons: [Int] { Array(Set(episodes.compactMap(\.parentIndexNumber))).sorted() }
    private var seasonEpisodes: [JellyfinItem] { episodes.filter { $0.parentIndexNumber == season } }
    private var shownEpisodes: [JellyfinItem] {
        let start = episodePage * 10
        return Array(seasonEpisodes.dropFirst(start).prefix(10))
    }
    private var activeEpisode: JellyfinItem? {
        if let selectedEpisodeID, let selected = episodes.first(where: { $0.id == selectedEpisodeID }) {
            return selected
        }
        let entryID = remoteID ?? item.id.uuidString
        if !isSeriesEntry, let entered = episodes.first(where: { $0.id == entryID }) { return entered }
        let unfinished = episodes.filter { !episodeWatched($0) && episodeProgressSeconds($0) > 0 }
        if let local = unfinished.max(by: {
            (localItem(for: $0)?.lastPlayedAt ?? .distantPast) <
            (localItem(for: $1)?.lastPlayedAt ?? .distantPast)
        }), localItem(for: local)?.lastPlayedAt != nil { return local }
        if let remote = unfinished.max(by: { episodeProgressSeconds($0) < episodeProgressSeconds($1) }) {
            return remote
        }
        return episodes.first { $0.id == remoteID } ??
            episodes.first { !episodeWatched($0) } ?? episodes.first
    }
    private var activeLocalItem: MediaItem? {
        guard let activeEpisode else { return nil }
        return localItem(for: activeEpisode)
    }
    private func localItem(for episode: JellyfinItem) -> MediaItem? {
        localEpisodesByID[episode.id]
    }
    private var activeProgressSeconds: Double {
        activeEpisode.map(episodeProgressSeconds) ?? item.resumePosition
    }
    private var activeIsInProgress: Bool {
        if let episode = activeEpisode { return activeProgressSeconds > 0 && !episodeWatched(episode) }
        return item.isInProgress
    }
    private var activeEpisodeLabel: String? {
        guard let episode = activeEpisode, let number = episode.indexNumber else { return nil }
        let episodeSeason = episode.parentIndexNumber ?? season
        if episodeSeason == 0 { return MediaIdentity.specialEpisodeTitle(number) }
        return String(format: "第%lld季·第%lld集".lucentLocalized, episodeSeason, number)
    }
    private func revealActiveEpisode() {
        guard let episode = activeEpisode else { return }
        if let number = episode.parentIndexNumber { season = number }
        if let index = seasonEpisodes.firstIndex(where: { $0.id == episode.id }) { episodePage = index / 10 }
    }
    private var activeSource: JellyfinItem.MediaSource? { activeEpisode?.mediaSources?.first }
    private var activeStreams: [JellyfinItem.MediaSource.Stream] { activeSource?.mediaStreams ?? [] }
    private var activeVideo: JellyfinItem.MediaSource.Stream? {
        activeStreams.first { $0.type == "Video" }
    }
    private var seriesName: String { page?.series.name ?? item.identity?.seriesName ?? item.title }
    private var isSeriesEntry: Bool {
        if case .episode(_, _, let number, _) = item.identity { return number == 0 }
        return false
    }

    private var isSeriesWatched: Bool {
        !episodes.isEmpty && episodes.allSatisfy(episodeWatched)
    }

    private func toggleSeriesWatched() {
        let watched = !isSeriesWatched
        let entries = episodes.compactMap { episode -> MediaItem? in
            guard episodeWatched(episode) != watched || (!watched && episodeProgressSeconds(episode) > 0) else { return nil }
            if let local = localItem(for: episode) { return local }
            guard let server else { return nil }
            return library.serverEpisodeForWatchedUpdate(episode, sourceID: server.sourceID, emby: server.emby)
        }
        library.setSeriesEpisodesWatched(entries, watched: watched)
    }

    private var seriesFavoriteItem: MediaItem? {
        guard let server, let seriesID = page?.series.id else {
            return remoteID != nil && isSeriesEntry ? item : nil
        }
        return library.items.first { candidate in
            switch candidate.location {
            case .embyItem(let id, let key): return server.emby && id == server.sourceID && key == seriesID
            case .jellyfinItem(let id, let key): return !server.emby && id == server.sourceID && key == seriesID
            default: return false
            }
        }
    }

    private var canFavoriteSeries: Bool {
        if remoteID != nil { return isSeriesEntry || (server != nil && page?.series != nil) }
        return library.localLibraryItems.contains { $0.id == item.id }
    }

    private var isSeriesFavorite: Bool {
        if remoteID != nil { return seriesFavoriteItem?.isFavorite == true }
        return library.localLibraryItems.contains {
            $0.catalogGroupID == item.catalogGroupID && $0.seriesFavorite == true
        }
    }

    private func toggleSeriesFavorite() {
        guard canFavoriteSeries else { return }
        if remoteID == nil {
            library.setLocalSeriesFavorite(groupID: item.catalogGroupID, anchorID: item.id, favorite: !isSeriesFavorite)
        } else if let existing = seriesFavoriteItem {
            library.toggleFavorite(id: existing.id)
        } else if let server, let series = page?.series {
            let entry = server.emby
                ? library.openEmbyItem(sourceID: server.sourceID, remote: series)
                : library.openJellyfinItem(sourceID: server.sourceID, remote: series)
            if !entry.isFavorite { library.toggleFavorite(id: entry.id) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StretchyHeroHeader(height: (max(550, geometry.size.height * 0.68) * posterDisplayScale).rounded(.up) / posterDisplayScale) { height, pull in
                        hero(height: height, width: geometry.size.width, pull: pull)
                    }
                    VStack(alignment: .leading, spacing: 24) {
                        if let summary = page?.series.overview ?? (isSeriesEntry ? item.metadata?.summary ?? item.serverSummary : nil),
                           !summary.isEmpty { synopsisPreview(summary, title: "剧集简介", lines: 3) }
                        else if loading {
                            VStack(alignment: .leading, spacing: 8) {
                                DetailSkeletonBlock().frame(height: 14)
                                DetailSkeletonBlock().frame(width: 250, height: 14)
                            }
                        }
                        episodeSection
                        castSection
                        if loading { DetailMediaSkeleton() }
                        else { mediaSection }
                    }
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 48)
                    .frame(maxWidth: LucentUI.detailContentWidth)
                    .frame(maxWidth: .infinity)
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .background(detailBackground)
            .detailDiscPageSurface()
            .ignoresSafeArea(edges: .top)
            .lucentHideTopScrollEdge()
            .coordinateSpace(name: "lucentHeroScroll")
        }
        #if os(iOS)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { ToolbarItem(placement: .topBarTrailing) { if !discControlsHidden { navigationActions } } }
        #elseif os(tvOS)
        .focusScope(detailFocusScope)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if !discControlsHidden { navigationActions }
            }
        }
        #else
        .overlay(alignment: .top) {
            topControls
                .padding(.top, 8)
        }
        #endif
        .task(id: item.id) {
            guard loadedDetailItemID != item.id || page == nil else { return }
            selectedEpisodeID = nil
            serverConnection = resolveServer()
            await load()
            guard !Task.isCancelled else { return }
            loadedDetailItemID = item.id
            revealActiveEpisode()
        }
        .onChange(of: activeEpisode?.id) { _, _ in revealActiveEpisode() }
        .onReceive(library.$items) { items in
            let sourceID: UUID
            switch item.location {
            case .embyItem(let id, _), .jellyfinItem(let id, _): sourceID = id
            default: updateLocalPage(received: items); return
            }
            var indexed: [String: MediaItem] = [:]
            for local in items {
                switch local.location {
                case .embyItem(let id, let episodeID) where id == sourceID:
                    indexed[episodeID] = local
                case .jellyfinItem(let id, let episodeID) where id == sourceID:
                    indexed[episodeID] = local
                default: break
                }
            }
            localEpisodesByID = indexed
        }
        .task(id: "\(item.id)|\(item.metadata?.providerID ?? 0)|\(contentLocalizationID)") {
            artwork = nil
            artworkResolved = false
            artworkRetriedID = nil
            await loadArtwork(remote: page?.series)
            if artwork?.posterURL == nil, let series = page?.series, !Task.isCancelled {
                await loadArtwork(remote: series)
            }
        }
        .onChange(of: page?.series.id) { _, _ in
            guard artworkResolved, artwork?.posterURL == nil, let series = page?.series else { return }
            Task { await loadArtwork(remote: series) }
        }
        #if !os(macOS)
        .navigationDestination(isPresented: $showAllEpisodes) { allEpisodesSheet.lucentSecondaryPage() }
        #else
        .lucentFullScreen(isPresented: $showAllEpisodes) { allEpisodesSheet }
        #endif
        .sheet(item: $synopsisSheet) { synopsis in
            synopsisSheetView(synopsis)
        }
    }

    private var navigationActions: some View {
        Menu {
                        Button(isSeriesWatched ? "标记为未观看" : "标记为已看完",
                               systemImage: isSeriesWatched ? "eye.slash" : "checkmark.circle") { toggleSeriesWatched() }
                            .disabled(episodes.isEmpty || loading)
                        Button(isSeriesFavorite ? "取消收藏" : "收藏", systemImage: isSeriesFavorite ? "heart.slash" : "heart") { toggleSeriesFavorite() }
                            .disabled(!canFavoriteSeries)
                        Button("更多播放选项与资料", systemImage: "slider.horizontal.3") {
                            if let episode = activeEpisode, let selected = mediaItem(for: episode) {
                                onMore(selected)
                            } else if !isSeriesEntry {
                                onMore(item)
                            }
                        }
                        .disabled(isSeriesEntry && activeEpisode == nil)

        } label: { Image(systemName: "ellipsis") }
        .accessibilityLabel("更多")
    }

    private var topControls: some View {
                HStack {
                    LucentToolbarButton(symbol: "chevron.left", label: "返回", role: colorScheme == .light ? .standard : .videoOverlay) { if let onBack { onBack() } else { dismiss() } }
                    Spacer()
                    navigationActions
                }
        .font(.title3.weight(.semibold))
        .lucentContentButtonStyle()
        .padding(.horizontal, 26)
    }

    private var titleLogoRequest: URLRequest? {
        guard let server, let id = page?.series.id ?? remoteID else { return nil }
        return ServerDetailClient.logoRequest(baseAddress: server.base, token: server.token, itemID: id)
    }

    private func hero(height: CGFloat, width: CGFloat, pull: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ZStack {
                Group {
                    if artworkResolved {
                        SeriesArtwork(baseAddress: server?.base, token: server?.token,
                                      itemID: page?.series.id ?? remoteID, backdrop: artwork?.posterURL == nil,
                                      fallback: item.metadata?.backdropPath.flatMap { URL(string: "https://image.tmdb.org/t/p/original\($0)") },
                                      preferredURL: artwork?.posterURL,
                                      maximumWidth: min(4096, Int((max(width, (height - pull) * 16 / 9) * posterDisplayScale).rounded(.up))), fallbackToBackdrop: true,
                                      targetPixelSize: CGSize(width: (width * posterDisplayScale).rounded(), height: ((height - pull) * posterDisplayScale).rounded()),
                                      onImage: { posterLightColor = DetailPosterPalette.lightColor(from: $0) })
                    } else { DetailSkeletonBlock(cornerRadius: 0) }
                }
                .frame(width: width, height: height)
                .scaleEffect(1 + min(pull / max(height - pull, 1), 0.4), anchor: .top)
                .clipped()
                #if os(iOS)
                .visualEffect { effect, geometry in
                    effect.offset(y: max(0, -geometry.frame(in: .scrollView(axis: .vertical)).minY))
                }
                #endif
                LinearGradient(colors: [.black.opacity(0.25), .clear],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.30))
            }
            .frame(width: width, height: height)
            .mask { HeroArtworkFade() }
            VStack(spacing: 13) {
                Group {
                if artworkResolved {
                    DetailTitleArtwork(url: artwork?.logoURL,
                                       title: artwork?.localizedTitle ?? seriesName,
                                       fallbackRequest: titleLogoRequest, maximumWidth: LucentUI.detailTitleWidth, maximumHeight: LucentUI.detailTitleHeight, foreground: detailInk)
                } else {
                    Color.clear.frame(height: 100)
                }
                }
                if page == nil && loadError == nil {
                    DetailSkeletonBlock().frame(width: 150, height: 14).accessibilityHidden(true)
                    DetailSkeletonBlock().frame(width: 112, height: 14).accessibilityHidden(true)
                } else {
                    let rating = page?.series.communityRating ?? item.metadata?.rating
                    HStack(spacing: 7) {
                        if let rating, rating > 0 {
                            Image(systemName: "star.fill").foregroundStyle(.orange)
                            Text(rating.formatted(.number.precision(.fractionLength(1))))
                        }
                        if let genres = page?.series.genres, !genres.isEmpty {
                            Text((rating.map { $0 > 0 } == true ? "·  " : "") + genres.prefix(3).joined(separator: "、")).lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(detailInk)
                    if !details.isEmpty {
                        Text(details)
                            .font(.caption).foregroundStyle(detailInk.opacity(0.82))
                    }
                }
                LucentPlayButton(resumeTime: activeIsInProgress ? clock(activeProgressSeconds) : nil,
                    episodeLabel: activeEpisodeLabel, enabled: !isSeriesEntry || activeEpisode != nil,
                    isLoading: loading) { play(activeEpisode) }
                #if os(tvOS)
                .prefersDefaultFocus(true, in: detailFocusScope)
                #endif
                if loading {
                    DetailActionSkeleton()
                } else {
                    HStack(spacing: 42) {
                        Button { toggleSeriesFavorite() } label: {
                            Image(systemName: isSeriesFavorite ? "heart.fill" : "heart")
                        }
                        .disabled(!canFavoriteSeries)
                        Button { toggleSeriesWatched() } label: {
                            Image(systemName: isSeriesWatched ? "flag.fill" : "flag")
                        }
                        .accessibilityLabel(isSeriesWatched ? "标记为未观看" : "标记为已看完")
                        .disabled(episodes.isEmpty || loading)
                    }
                    .font(.title3).lucentContentButtonStyle().padding(.top, 8)
                }
            }
            .padding(.horizontal, 28).padding(.bottom, 0).frame(maxWidth: LucentUI.detailHeroContentWidth)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var details: String {
        let minutes = activeEpisode?.runTimeTicks.map { Int(Double($0) / 600_000_000) }
        let size = activeSource?.size.flatMap { $0 > 0 ? String(format: "%.2f GB", Double($0) / 1_000_000_000) : nil }
        let resolution: String? = {
            guard let width = activeVideo?.width else { return nil }
            if width >= 3840 { return "4K" }
            if width >= 1920 { return "1080p" }
            if width >= 1280 { return "720p" }
            return nil
        }()
        return [activeDisplayDate, minutes.flatMap { $0 > 0 ? "\($0) 分钟" : nil },
                size, resolution, activeVideo?.codec?.uppercased()]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var activeDisplayDate: String? {
        if let raw = activeEpisode?.premiereDate, raw.count >= 10 {
            return LocalizationPreferences.current.releaseDate(raw) ?? String(raw.prefix(10))
        }
        return nil
    }

    private func synopsisPreview(_ text: String, title: String, lines: Int,
                                 font: Font = .footnote, opacity: Double = 0.84) -> some View {
        Button {
            synopsisSheet = .init(title: title, text: text)
        } label: {
            Text(text)
                .font(font)
                .foregroundStyle(detailInk.opacity(opacity))
                .lineSpacing(4)
                .lineLimit(lines)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .lucentContentButtonStyle()
        .accessibilityHint("点按查看完整简介")
    }

    private func synopsisSheetView(_ synopsis: SynopsisSheet) -> some View {
        LucentSynopsisSheet(title: synopsis.title, text: synopsis.text) { synopsisSheet = nil }
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            if loading {
                HStack {
                    DetailSkeletonBlock().frame(width: 78, height: 22)
                    Spacer()
                    DetailSkeletonBlock().frame(width: 80, height: 17)
                }
                .accessibilityHidden(true)
            } else {
                HStack {
                    Menu {
                        Picker("季", selection: Binding(
                            get: { season },
                            set: { season = $0; episodePage = 0 }
                        )) {
                            ForEach(seasons, id: \.self) { number in
                                Text(MediaIdentity.seasonTitle(number)).tag(number)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 5) { Text(MediaIdentity.seasonTitle(season)); Image(systemName: "chevron.down").font(.caption) }
                    }
                    .disabled(seasons.isEmpty)
                    Spacer()
                    Button { showAllEpisodes = true } label: {
                        HStack(spacing: 3) { Text("查看全部"); Image(systemName: "chevron.right") }
                    }
                        .font(.subheadline.weight(.semibold))
                        .disabled(episodes.isEmpty)
                }
                .font(.title3.bold()).foregroundStyle(detailInk)
            }
            if loading {
                HStack(spacing: 13) {
                    ForEach(0..<2, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: 8) {
                            DetailSkeletonBlock().frame(width: LucentUI.detailSize(210), height: LucentUI.detailSize(122))
                            DetailSkeletonBlock().frame(width: 160, height: 14)
                            DetailSkeletonBlock().frame(width: 190, height: 12)
                        }
                    }
                }
                .accessibilityLabel("正在加载剧集")
            }
            else if let loadError { Text(loadError).font(.footnote).foregroundStyle(detailInk.opacity(0.72)) }
            else if episodes.isEmpty { Text("暂无剧集信息").foregroundStyle(detailInk.opacity(0.7)) }
            else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(shownEpisodes, id: \.id) { episode in
                            episodeCard(episode).id(episode.id)
                        }
                    }
                }
                if seasonEpisodes.count > 10 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0..<Int(ceil(Double(seasonEpisodes.count) / 10)), id: \.self) { index in
                                Button("\(index * 10 + 1)–\(min((index + 1) * 10, seasonEpisodes.count))") {
                                    episodePage = index
                                }
                                .font(.caption.weight(episodePage == index ? .semibold : .regular))
                                .lucentNativeGlassButton()
                                .frame(minHeight: 30)
                                .clipShape(Capsule())
                                .accessibilityAddTraits(episodePage == index ? .isSelected : [])
                            }
                        }
                    }
                    .lucentGlassScrollSurface()
                    .font(.caption)
                }
            }
        }
    }

    private func episodeCard(_ episode: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Button { selectOrPlay(episode) } label: {
                VStack(alignment: .leading, spacing: 7) {
                    SeriesArtwork(baseAddress: server?.base, token: server?.token,
                                  itemID: episode.id, backdrop: false, fallback: nil, preferredURL: episodeArtworkURL(episode))
                        .frame(width: LucentUI.detailSize(210), height: LucentUI.detailSize(122)).clipShape(RoundedRectangle(cornerRadius: 14))
                        .overlay {
                            if episode.id == activeEpisode?.id {
                                Image(systemName: "play.fill")
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: LucentUI.detailSize(44), height: LucentUI.detailSize(44))
                                    .background(.black.opacity(0.55), in: Circle())
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                        .overlay(alignment: .topTrailing) {
                            if episodeWatched(episode) {
                                Image(systemName: "checkmark").font(.caption.bold())
                                    .foregroundStyle(.black).padding(6).background(.white, in: Circle())
                                    .padding(8)
                            }
                        }
                        .overlay(alignment: .bottom) {
                            if let duration = episode.runTimeTicks, duration > 0,
                               episodeProgressSeconds(episode) > 0 {
                                GeometryReader { proxy in
                                    Capsule().fill(.white.opacity(0.6))
                                        .overlay(alignment: .leading) {
                                            Capsule().fill(.white)
                                                .frame(width: proxy.size.width * min(1,
                                                    episodeProgressSeconds(episode) * 10_000_000 / Double(duration)))
                                        }
                                }
                                .frame(height: 3).padding(.horizontal, 10).padding(.bottom, 8)
                            }
                        }
                        .overlay(RoundedRectangle(cornerRadius: 14)
                            .stroke(episode.id == activeEpisode?.id ? .white : .clear, lineWidth: 2))
                    Text("E\(String(format: "%02d", episode.indexNumber ?? 0)) · \(episode.name)")
                        .font(.footnote.weight(.semibold)).lineLimit(2)
                }
            }
            .lucentContentButtonStyle()
            .accessibilityAddTraits(episode.id == activeEpisode?.id ? .isSelected : [])
            if let summary = episode.overview, !summary.isEmpty {
                synopsisPreview(summary, title: "第 \(episode.indexNumber ?? 0) 集简介", lines: 3,
                                font: .caption, opacity: 0.65)
            }
        }
        .frame(width: LucentUI.detailSize(210), alignment: .leading)
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let people = page?.series.people?.filter({ $0.role != nil || !$0.name.isEmpty }), !people.isEmpty {
                Text("演职人员").font(.title3.bold()).foregroundStyle(detailInk)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(Array(people.prefix(16)), id: \.stableID) { person in
                            VStack(alignment: .leading, spacing: 5) {
                                Group {
                                    if person.primaryImageTag != nil {
                                        SeriesArtwork(baseAddress: server?.base, token: server?.token,
                                                      itemID: person.id, backdrop: false, fallback: nil,
                                                      preferredURL: server == nil ? person.primaryImageTag.flatMap { URL(string: "https://image.tmdb.org/t/p/w185\($0)") } : nil)
                                    } else {
                                        RoundedRectangle(cornerRadius: 13)
                                            .fill(.white.opacity(0.12))
                                            .overlay(Text(String(person.name.prefix(1)))
                                                .font(.title2.weight(.medium))
                                                .foregroundStyle(detailInk.opacity(0.8)))
                                    }
                                }
                                .frame(width: LucentUI.detailSize(88), height: LucentUI.detailSize(112))
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                Text(person.name).font(.caption.weight(.semibold)).foregroundStyle(detailInk).lineLimit(1)
                                if let role = person.role {
                                    Text(role).font(.caption2).foregroundStyle(detailInk.opacity(0.6)).lineLimit(1)
                                }
                            }
                            .frame(width: LucentUI.detailSize(88), alignment: .leading)
                            .lucentReadableFocus()
                        }
                    }
                }
            }
        }
    }

    private var mediaSection: some View {
        DetailMediaMetadataPanel(streams: activeStreams, source: activeSource,
                                 path: activeSource?.path.flatMap { $0.isEmpty ? nil : $0 } ?? activeEpisode?.path,
                                 providerIDs: page?.series.providerIds,
                                 tmdbID: item.metadata?.providerID, isSeries: true, foreground: detailInk)
    }

    private var allEpisodesSheet: some View {
        VStack(spacing: 0) {
            #if os(macOS)
            ZStack {
                Text("\(seriesName) \(MediaIdentity.seasonTitle(season))")
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 90)
                HStack {
                    Button { withAnimation { showAllEpisodes = false } } label: {
                        Image(systemName: "chevron.left")
                            .font(.title3.weight(.medium))
                            .frame(width: 48, height: 48)
                            .modifier(LucentGlass(shape: Circle()))
                    }
                    .accessibilityLabel("返回剧集详情")
                    Spacer(minLength: 0)
                    if editingEpisodes {
                        Button("完成") { editingEpisodes = false; selectedEpisodeIDs.removeAll() }
                            .font(.subheadline.weight(.semibold))
                            .frame(width: 76, height: 48)
                            .modifier(LucentGlass(shape: Capsule()))
                    } else {
                        Button { editingEpisodes = true } label: {
                            Image(systemName: "ellipsis")
                                .font(.title3.weight(.semibold))
                                .frame(width: 48, height: 48)
                                .modifier(LucentGlass(shape: Circle()))
                        }
                        .accessibilityLabel("编辑剧集")
                    }
                }
            }
            .foregroundStyle(.primary)
            .lucentContentButtonStyle()
            .padding(.horizontal, 26)
            .padding(.top, 8)
            .padding(.bottom, 8)
            #endif
            ScrollView {
                HStack {
                    Menu {
                        Picker("季", selection: Binding(
                            get: { season },
                            set: {
                                season = $0
                                selectedEpisodeIDs.removeAll()
                            }
                        )) {
                            ForEach(seasons, id: \.self) { number in
                                Text(MediaIdentity.seasonTitle(number)).tag(number)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        HStack(spacing: 9) {
                            Text(MediaIdentity.seasonTitle(season)).font(.subheadline.weight(.semibold))
                            Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 16).frame(height: 42)
                    }
                    .lucentContentButtonStyle()
                    .modifier(LucentGlass(shape: Capsule()))
                    Spacer()
                    Text("\(seasonEpisodes.count) 集")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 20).padding(.top, 16)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 20), count: LucentUI.libraryColumnCount == 6 ? 4 : 2),
                          alignment: .center, spacing: 26) {
                    ForEach(seasonEpisodes, id: \.id) { episode in
                        Button {
                            if editingEpisodes {
                                if selectedEpisodeIDs.contains(episode.id) { selectedEpisodeIDs.remove(episode.id) }
                                else { selectedEpisodeIDs.insert(episode.id) }
                            } else {
                                showAllEpisodes = false
                                selectOrPlay(episode)
                            }
                        } label: {
                            fullEpisodeCard(episode)
                        }
                        .lucentContentButtonStyle()
                        .id(episode.id)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 18)
                .padding(.bottom, 100)
            }
        }
        .background(LucentUI.page.ignoresSafeArea())
        #if !os(macOS)
        .navigationTitle("\(seriesName) \(MediaIdentity.seasonTitle(season))")
        .lucentNavigationTitleStyle()
        #if os(iOS)
        .navigationBarBackButtonHidden(false)
        .toolbar(.visible, for: .navigationBar)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if editingEpisodes {
                    Button("完成") { editingEpisodes = false; selectedEpisodeIDs.removeAll() }
                } else {
                    Button("编辑剧集", systemImage: "ellipsis") { editingEpisodes = true }
                }
            }
        }
        #endif
        .overlay(alignment: .bottom) {
            if editingEpisodes { episodeBatchBar }
        }
        .onDisappear { editingEpisodes = false; selectedEpisodeIDs.removeAll() }
    }

    private var episodeBatchBar: some View {
        HStack(spacing: 10) {
            Button(selectedEpisodeIDs.count == seasonEpisodes.count ? "取消全选" : "全选") {
                if selectedEpisodeIDs.count == seasonEpisodes.count { selectedEpisodeIDs.removeAll() }
                else { selectedEpisodeIDs = Set(seasonEpisodes.map(\.id)) }
            }
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 18).frame(height: 48)
            .modifier(LucentGlass(shape: Capsule()))
            Spacer(minLength: 0)
            Text("已选择 \(selectedEpisodeIDs.count) 项")
                .font(.subheadline)
                .monospacedDigit()
                .padding(.horizontal, 16).frame(height: 48)
                .modifier(LucentGlass(shape: Capsule()))
            Spacer(minLength: 0)
            Menu {
                Button("添加到收藏夹", systemImage: "star.fill") { batchEpisodes(.favorite) }
                Button("从收藏夹中移除", systemImage: "star") { batchEpisodes(.unfavorite) }
                Button("标记为已观看", systemImage: "flag.fill") { batchEpisodes(.watched) }
                Button("标记为未观看", systemImage: "flag") { batchEpisodes(.unwatched) }
                Button("下载", systemImage: "arrow.down") { batchEpisodes(.download) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.title3.weight(.semibold))
                    .frame(width: 48, height: 48)
                    .modifier(LucentGlass(shape: Circle()))
            }
            .disabled(selectedEpisodeIDs.isEmpty)
        }
        .foregroundStyle(.primary)
        .lucentContentButtonStyle()
        .padding(.horizontal, 26)
        .padding(.bottom, 12)
    }

    private func fullEpisodeCard(_ episode: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SeriesArtwork(baseAddress: server?.base, token: server?.token,
                          itemID: episode.id, backdrop: false, fallback: nil, preferredURL: episodeArtworkURL(episode))
                .frame(maxWidth: .infinity)
                .aspectRatio(1.75, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 13))
                .overlay(alignment: .topLeading) {
                    if editingEpisodes {
                        Image(systemName: selectedEpisodeIDs.contains(episode.id) ? "checkmark.square.fill" : "square")
                            .font(.title3.weight(.medium))
                            .foregroundStyle(selectedEpisodeIDs.contains(episode.id) ? LucentUI.selectionTint : .white)
                            .padding(10)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if episodeWatched(episode) {
                        Image(systemName: "checkmark").font(.caption.bold())
                            .foregroundStyle(.black).padding(5).background(.white.opacity(0.85), in: Circle())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if let rating = episode.communityRating {
                        LucentRatingBadge(rating: rating).padding(3)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(selectedEpisodeIDs.contains(episode.id) ? LucentUI.selectionTint :
                                  episode.id == activeEpisode?.id ? Color.primary : Color.primary.opacity(0.12),
                                  lineWidth: selectedEpisodeIDs.contains(episode.id) ||
                                  episode.id == activeEpisode?.id ? 2 : 0.5))
            Text("\(episode.indexNumber ?? 0). \(episode.name)")
                .font(.footnote.weight(.semibold)).lineLimit(2)
                .foregroundStyle(.primary)
        }
    }

    private func episodeWatched(_ episode: JellyfinItem) -> Bool {
        if let local = localItem(for: episode),
           (local.stateUpdatedAt ?? .distantPast) >= (episode.remoteStateDate ?? .distantPast) {
            return local.watched || PlaybackProgressPolicy.current.isCompleted(position: local.position, duration: local.duration)
        }
        return episode.userData?.played == true || PlaybackProgressPolicy.current.isCompleted(
            position: Double(episode.userData?.playbackPositionTicks ?? 0) / 10_000_000,
            duration: episode.runTimeTicks.map { Double($0) / 10_000_000 })
    }

    private func episodeProgressSeconds(_ episode: JellyfinItem) -> Double {
        let serverPosition = Double(episode.userData?.playbackPositionTicks ?? 0) / 10_000_000
        if let local = localItem(for: episode),
           (local.stateUpdatedAt ?? .distantPast) >= (episode.remoteStateDate ?? .distantPast) {
            return local.resumePosition
        }
        return PlaybackProgressPolicy.current.resumePosition(position: serverPosition,
            duration: episode.runTimeTicks.map { Double($0) / 10_000_000 }, watched: episode.userData?.played == true)
    }

    private enum EpisodeBatchAction { case favorite, unfavorite, watched, unwatched, download }

    private func batchEpisodes(_ action: EpisodeBatchAction) {
        let selected = seasonEpisodes.filter { selectedEpisodeIDs.contains($0.id) }
        let items = selected.compactMap { mediaItem(for: $0) }
        for entry in items {
            switch action {
            case .favorite:
                if !entry.isFavorite { library.toggleFavorite(id: entry.id) }
            case .unfavorite:
                if entry.isFavorite { library.toggleFavorite(id: entry.id) }
            case .watched: library.markWatched(id: entry.id)
            case .unwatched: library.markUnwatched(id: entry.id)
            case .download: break
            }
        }
        if action == .download {
            Task {
                for entry in items where library.downloadedURL(for: entry) == nil {
                    await library.download(id: entry.id)
                }
            }
        }
        selectedEpisodeIDs.removeAll()
        editingEpisodes = false
    }

    private func play(_ episode: JellyfinItem?) {
        guard let episode else {
            if !isSeriesEntry { onPlay(item) }
            return
        }
        if let selected = mediaItem(for: episode) { onPlay(selected) }
    }

    private func selectOrPlay(_ episode: JellyfinItem) {
        if activeEpisode?.id == episode.id {
            play(episode)
        } else {
            selectedEpisodeID = episode.id
        }
    }

    private func mediaItem(for episode: JellyfinItem) -> MediaItem? {
        if server == nil { return localItem(for: episode) }
        guard let server else { return nil }
        var selected = server.emby
            ? library.openEmbyItem(sourceID: server.sourceID, remote: episode)
            : library.openJellyfinItem(sourceID: server.sourceID, remote: episode)
        if let ticks = episode.userData?.playbackPositionTicks {
            selected.position = max(selected.position, Double(ticks) / 10_000_000)
        }
        if let duration = episode.runTimeTicks {
            selected.duration = Double(duration) / 10_000_000
        }
        return selected
    }

    private func clock(_ seconds: Double) -> String {
        let time = Int(max(0, seconds))
        if time >= 3600 { return String(format: "%d:%02d:%02d", time / 3600, time / 60 % 60, time % 60) }
        return String(format: "%02d:%02d", time / 60, time % 60)
    }

    private func updateLocalPage(received: [MediaItem]? = nil) {
        // @Published emits before the stored array is replaced. Use the received
        // values to avoid showing the previous probe result or playback position.
        let allowed = Set(library.localLibraryItems.map(\.id))
        let values = received ?? library.localLibraryItems
        let current = values.first { $0.id == item.id } ?? item
        let group = values.filter {
            allowed.contains($0.id) && $0.missingSince == nil && ($0.catalogGroupID == current.catalogGroupID ||
                ($0.metadata == nil && $0.identity?.seriesName == current.identity?.seriesName))
        }.sorted { ($0.identity?.episodeSortOrder ?? 0) < ($1.identity?.episodeSortOrder ?? 0) }
        localEpisodesByID = Dictionary(uniqueKeysWithValues: group.map { ($0.id.uuidString, $0) })
        if let series = (group.first(where: { $0.metadata != nil }) ?? item).localDetailItem(asSeries: true) {
            page = .init(series: series, episodes: group.compactMap { $0.localDetailItem() })
        }
    }

    private func episodeArtworkURL(_ episode: JellyfinItem) -> URL? {
        guard server == nil else { return nil }
        let path = localItem(for: episode)?.catalogEpisode?.stillPath ?? item.metadata?.backdropPath ?? item.metadata?.posterPath
        guard let path else { return nil }
        return URL(string: "https://image.tmdb.org/t/p/w780\(path)")
    }

    private func load() async {
        guard let server, let remoteID else {
            updateLocalPage()
            if let currentSeason = activeEpisode?.parentIndexNumber { season = currentSeason }
            return
        }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            let requestedAt = Date()
            let loaded = try await ServerEpisodeClient.seriesPage(baseAddress: server.base,
                userID: server.user, itemID: remoteID, token: server.token)
            try Task.checkCancellation()
            page = loaded
            if let loaded { library.mergeServerCards([loaded.series], sourceID: server.sourceID, requestedAt: requestedAt) }
            if let currentSeason = activeEpisode?.parentIndexNumber { season = currentSeason }
            let currentIndex = seasonEpisodes.firstIndex { $0.id == activeEpisode?.id } ?? 0
            episodePage = currentIndex / 10
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func loadArtwork(remote: JellyfinItem?) async {
        guard let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else {
            artworkResolved = true
            return
        }
        let remoteArtworkID = TMDBService.artworkID(remote: remote, metadata: nil)
        if let remoteArtworkID {
            guard remoteArtworkID != artworkRetriedID else { return }
            artworkRetriedID = remoteArtworkID
        }
        let result = try? await TMDBService.detailArtwork(remote: remote,
            metadata: item.metadata, title: seriesName, television: true,
            language: TMDBService.deviceLanguage, token: token,
            displayWidthPixels: LucentDisplay.maximumArtworkPixels)
        guard !Task.isCancelled else { return }
        if let result, result.posterURL != nil || artwork == nil { artwork = result }
        artworkResolved = true
    }
}

private struct MediaInfoCardRow: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        return CGSize(width: sizes.reduce(0) { $0 + $1.width } + spacing * CGFloat(max(0, sizes.count - 1)),
                      height: sizes.map(\.height).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for card in subviews {
            let width = card.sizeThatFits(.unspecified).width
            card.place(at: CGPoint(x: x, y: bounds.minY), anchor: .topLeading,
                       proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }
}

struct DetailMediaMetadataPanel: View {
    let streams: [JellyfinItem.MediaSource.Stream]
    let source: JellyfinItem.MediaSource?
    let path: String?
    let providerIDs: [String: String]?
    let tmdbID: Int?
    let isSeries: Bool

    private struct ExternalLink: Identifiable {
        let title: String
        let url: URL
        var id: String { title }
    }

    private func provider(_ key: String) -> String? {
        providerIDs?.first { $0.key.caseInsensitiveCompare(key) == .orderedSame }?.value
    }

    private var links: [ExternalLink] {
        var result: [ExternalLink] = []
        if let id = provider("Douban"), id.allSatisfy(\.isNumber),
           let url = URL(string: "https://movie.douban.com/subject/\(id)/") {
            result.append(.init(title: "豆瓣", url: url))
        }
        if let id = provider("Imdb"), id.range(of: "^tt[0-9]+$", options: .regularExpression) != nil,
           let url = URL(string: "https://www.imdb.com/title/\(id)/") {
            result.append(.init(title: "IMDb", url: url))
        }
        let resolvedTMDB = provider("Tmdb") ?? tmdbID.map(String.init)
        if let id = resolvedTMDB, !id.isEmpty, id.allSatisfy(\.isNumber) {
            let type = isSeries ? "tv" : "movie"
            if let url = URL(string: "https://www.themoviedb.org/\(type)/\(id)") {
                result.append(.init(title: "TheMovieDb", url: url))
            }
            if let url = URL(string: "https://trakt.tv/search/tmdb/\(id)?id_type=\(type)") {
                result.append(.init(title: "Trakt", url: url))
            }
        }
        return result
    }

    @Environment(\.colorScheme) private var colorScheme
    var foreground: Color = .white

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            if !links.isEmpty {
                VStack(alignment: .leading, spacing: 14) {
                    Text("链接").font(.title3.bold()).foregroundStyle(foreground)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(links) { link in
                                Link(destination: link.url) {
                                    Label(link.title, systemImage: "link")
                                        .font(.caption)
                                }
                                .lucentNativeGlassButton()
                                .frame(minHeight: 30)
                                .clipShape(Capsule())
                            }
                        }
                    }
                    .lucentGlassScrollSurface()
                }
            }
            VStack(alignment: .leading, spacing: 14) {
                Text("媒体信息").font(.title3.bold()).foregroundStyle(foreground)
                if streams.isEmpty {
                    Text("暂无媒体流信息").font(.subheadline).foregroundStyle(foreground.opacity(0.65))
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        MediaInfoCardRow(spacing: 12) {
                            ForEach(Array(streams.enumerated()), id: \.offset) { _, stream in
                                streamCard(stream)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .contentMargins(.trailing, 22)
                    .lucentGlassScrollSurface()
                }
                if let path, !path.isEmpty {
                    VStack(spacing: 4) {
                        Text((path as NSString).lastPathComponent).lineLimit(2)
                        HStack(spacing: 8) {
                            if let container = MediaInfoLabels.container(source?.container, filename: path) { Text(container) }
                            if let size = source?.size, size > 0 {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(foreground.opacity(0.6))
                    .frame(maxWidth: .infinity)
                    .padding(14)
                    .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 18)))
                }
            }
        }
    }

    private func streamCard(_ stream: JellyfinItem.MediaSource.Stream) -> some View {
        let kind = stream.type ?? "媒体流"
        return VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Image(systemName: kind == "Video" ? "video" : kind == "Audio" ? "speaker.wave.2" : "captions.bubble")
                Text(LocalizedStringKey(kind == "Video" ? "视频" : kind == "Audio" ? "音频" : "字幕"))
                Spacer()
                if stream.isDefault == true { Image(systemName: "checkmark") }
            }
            .font(.headline).foregroundStyle(foreground)
            metadataRow("标题", stream.displayTitle)
            metadataRow("语言", stream.language)
            metadataRow("编码", stream.codec)
            if let width = stream.width, let height = stream.height {
                metadataRow("分辨率", "\(width)×\(height)")
            }
            if let rate = stream.averageFrameRate { metadataRow("帧率", rate.formatted(.number.locale(LocalizationPreferences.current.displayLocale))) }
            if let rate = stream.bitRate { metadataRow("比特率", "\(rate / 1000) kbps") }
            metadataRow("动态范围", stream.videoRangeType)
            metadataRow("配置", stream.profile)
            if let level = stream.level { metadataRow("等级", level.formatted(.number.locale(LocalizationPreferences.current.displayLocale))) }
            metadataRow("长宽比", stream.aspectRatio)
            if let channels = stream.channels { metadataRow("声道", "\(channels)") }
            metadataRow("布局", stream.channelLayout)
            if let sampleRate = stream.sampleRate { metadataRow("采样率", "\(sampleRate) Hz") }
            if let external = stream.isExternal { metadataRow("外部", external ? "是" : "否") }
            if let selected = stream.isDefault { metadataRow("默认", selected ? "是" : "否") }
            metadataRow("色域", stream.colorSpace)
            metadataRow("色偏", stream.colorTransfer)
            metadataRow("基色", stream.colorPrimaries)
            metadataRow("像素格式", stream.pixelFormat)
        }
        .padding(17)
        .frame(width: LucentUI.detailSize(238), alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: LucentUI.mediaInfoCardHeight, maxHeight: .infinity, alignment: .topLeading)
        .lucentReadableFocus()
        .modifier(LucentGlass(shape: RoundedRectangle(cornerRadius: 24)))
    }

    @ViewBuilder private func metadataRow(_ label: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            HStack(alignment: .top, spacing: 9) {
                Text(LocalizedStringKey(label)).foregroundStyle(foreground.opacity(0.9)).frame(width: 72, alignment: .leading)
                Text(label == "语言" ? LocalizationPreferences.current.displayLocale.localizedString(forLanguageCode: value) ?? value : (value == "是" || value == "否" ? value.lucentLocalized : value)).foregroundStyle(foreground.opacity(0.62)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .font(.caption)
        }
    }
}
