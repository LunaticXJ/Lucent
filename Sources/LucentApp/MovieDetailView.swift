import SwiftUI

struct MovieDetailView: View {
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
    let onMore: () -> Void
    var onBack: (() -> Void)? = nil

    @State private var detail: JellyfinItem?
    @State private var overviewExpanded = false
    @State private var loadError: String?
    @State private var artwork: TMDBService.DetailArtwork?
    @State private var artworkResolved = false
    @State private var artworkRetriedID: Int?
    @State private var serverConnection: (base: String, user: String, token: String, itemID: String)?

    @Environment(\.colorScheme) private var colorScheme
    @State private var posterLightColor = Color(red: 0.94, green: 0.95, blue: 0.96)
    private var background: Color { colorScheme == .dark ? Color(red: 0.27, green: 0.22, blue: 0.20) : posterLightColor }
    private var detailInk: Color { colorScheme == .dark ? .white : .black }

    private var server: (base: String, user: String, token: String, itemID: String)? {
        serverConnection
    }

    private func resolveServer() -> (base: String, user: String, token: String, itemID: String)? {
        switch item.location {
        case .embyItem(let sourceID, let itemID):
            guard let source = library.embySources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.embyToken(for: sourceID) else { return nil }
            return (source.baseAddress, source.userID, token, itemID)
        case .jellyfinItem(let sourceID, let itemID):
            guard let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID) else { return nil }
            return (source.baseAddress, source.userID, token, itemID)
        default: return nil
        }
    }

    private var source: JellyfinItem.MediaSource? { detail?.mediaSources?.first }
    private var streams: [JellyfinItem.MediaSource.Stream] { source?.mediaStreams ?? [] }
    private var video: JellyfinItem.MediaSource.Stream? { streams.first { $0.type == "Video" } }
    private var progressSeconds: Double {
        let local = library.items.first { $0.id == item.id } ?? item
        if let updated = local.stateUpdatedAt, updated >= (detail?.remoteStateDate ?? .distantPast) { return local.resumePosition }
        return PlaybackProgressPolicy.current.resumePosition(
            position: Double(detail?.userData?.playbackPositionTicks ?? 0) / 10_000_000,
            duration: detail?.runTimeTicks.map { Double($0) / 10_000_000 } ?? local.duration,
            watched: detail?.userData?.played ?? local.watched)
    }
    private var isInProgress: Bool { progressSeconds > 0 }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    StretchyHeroHeader(height: (max(620, geometry.size.height * 0.76) * posterDisplayScale).rounded(.up) / posterDisplayScale) { height, pull in
                        hero(width: geometry.size.width, height: height, pull: pull)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        if let summary = detail?.overview ?? item.metadata?.summary ?? item.serverSummary,
                           !summary.isEmpty {
                            Button { overviewExpanded = true } label: {
                                Text(summary)
                                    .font(.footnote)
                                    .foregroundStyle(detailInk.opacity(0.88))
                                    .lineSpacing(4)
                                    .lineLimit(3)
                                    .multilineTextAlignment(.leading)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .lucentContentButtonStyle()
                            .accessibilityHint("点按查看完整简介")
                        } else if detail == nil && loadError == nil {
                            VStack(alignment: .leading, spacing: 8) {
                                DetailSkeletonBlock().frame(height: 14)
                                DetailSkeletonBlock().frame(width: 250, height: 14)
                            }
                        }
                        if detail == nil && loadError == nil {
                            DetailSkeletonBlock().frame(width: 110, height: 18)
                            HStack(spacing: 13) {
                                ForEach(0..<3, id: \.self) { _ in
                                    DetailSkeletonBlock().frame(width: LucentUI.detailSize(88), height: LucentUI.detailSize(112))
                                }
                            }
                            DetailMediaSkeleton()
                        } else {
                            castSection
                            mediaSection
                        }
                        if let loadError {
                            Text(loadError).font(.caption).foregroundStyle(detailInk.opacity(0.65))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 54)
                    .frame(maxWidth: LucentUI.detailContentWidth)
                    .frame(maxWidth: .infinity)
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .background(background)
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
        .onReceive(library.$items) { values in
            if server == nil, let current = values.first(where: { $0.id == item.id }) { detail = current.localDetailItem() }
        }
        .task(id: item.id) {
            serverConnection = resolveServer()
            await load()
        }
        .task(id: "\(item.id)|\(item.metadata?.providerID ?? 0)|\(contentLocalizationID)") {
            artwork = nil
            artworkResolved = false
            artworkRetriedID = nil
            await loadArtwork(remote: nil)
            if artwork?.posterURL == nil, let detail {
                await loadArtwork(remote: detail)
            }
        }
        .onChange(of: detail?.id) { _, _ in
            guard artworkResolved, artwork?.posterURL == nil, let detail else { return }
            Task { await loadArtwork(remote: detail) }
        }
        .sheet(isPresented: $overviewExpanded) {
            LucentSynopsisSheet(title: "简介", text: detail?.overview ?? item.metadata?.summary ?? item.serverSummary ?? "") { overviewExpanded = false }
        }
    }

    private var navigationActions: some View {
        Menu {
                        Button(item.watched ? "标记为未观看" : "标记为已看完", systemImage: item.watched ? "eye.slash" : "checkmark.circle") {
                            if item.watched { library.markUnwatched(id: item.id) }
                            else { library.markWatched(id: item.id) }
                        }
                        Button(item.isFavorite ? "取消收藏" : "收藏", systemImage: item.isFavorite ? "heart.slash" : "heart") {
                            library.toggleFavorite(id: item.id)
                        }
                        Button("更多播放选项与资料", systemImage: "slider.horizontal.3") {
                            onMore()
                        }

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

    private func hero(width: CGFloat, height: CGFloat, pull: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            ZStack {
                Group {
                    if artworkResolved {
                        SeriesArtwork(baseAddress: server?.base, token: server?.token,
                                      itemID: server?.itemID, backdrop: artwork?.posterURL == nil,
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
                LinearGradient(colors: [.black.opacity(0.28), .clear],
                               startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.30))
            }
            .frame(width: width, height: height)
            .mask { HeroArtworkFade() }
            VStack(spacing: 12) {
                Group {
                if artworkResolved {
                    DetailTitleArtwork(url: artwork?.logoURL,
                                       title: artwork?.localizedTitle ?? detail?.name ?? item.title,
                                       fallbackRequest: server.flatMap { ServerDetailClient.logoRequest(baseAddress: $0.base, token: $0.token, itemID: $0.itemID) },
                                       maximumWidth: LucentUI.detailTitleWidth, maximumHeight: LucentUI.detailTitleHeight, foreground: detailInk)
                } else {
                    Color.clear.frame(height: 100)
                }
                }
                if detail == nil && loadError == nil {
                    DetailSkeletonBlock().frame(width: 150, height: 14).accessibilityHidden(true)
                    DetailSkeletonBlock().frame(width: 112, height: 14).accessibilityHidden(true)
                } else {
                    let rating = detail?.communityRating ?? item.metadata?.rating
                    HStack(spacing: 7) {
                        if let rating, rating > 0 {
                            Image(systemName: "star.fill").foregroundStyle(.orange)
                            Text(rating.formatted(.number.precision(.fractionLength(1))))
                        }
                        if let date = displayDate { Text((rating.map { $0 > 0 } == true ? "·  " : "") + date) }
                        if let genres = detail?.genres, !genres.isEmpty {
                            Text((rating.map { $0 > 0 } == true || displayDate != nil ? "·  " : "") + genres.prefix(2).joined(separator: "、")).lineLimit(1)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(detailInk)
                    if (detail != nil || loadError != nil), !technicalSummary.isEmpty {
                        Text(technicalSummary)
                            .font(.caption)
                            .foregroundStyle(detailInk.opacity(0.8))
                    }
                }
                LucentPlayButton(resumeTime: isInProgress ? clock(progressSeconds) : nil,
                                 isLoading: detail == nil && loadError == nil) { play() }
                #if os(tvOS)
                .prefersDefaultFocus(true, in: detailFocusScope)
                #endif
                if detail == nil && loadError == nil {
                    DetailActionSkeleton()
                } else {
                    HStack(spacing: 42) {
                        Button { library.toggleFavorite(id: item.id) } label: {
                            Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                        }
                        Button {
                            if item.watched { library.markUnwatched(id: item.id) }
                            else { library.markWatched(id: item.id) }
                        } label: { Image(systemName: "flag") }
                    }
                    .font(.title3)
                    .lucentContentButtonStyle()
                    .padding(.top, 7)
                }
            }
            .frame(maxWidth: LucentUI.detailHeroContentWidth)
            .padding(.horizontal, 28)
            .padding(.bottom, 0)
        }
        .frame(width: width, height: height)
        .clipped()
    }

    private var displayDate: String? {
        if let raw = detail?.premiereDate, raw.count >= 10 {
            return LocalizationPreferences.current.releaseDate(raw) ?? String(raw.prefix(10))
        }
        if let year = detail?.productionYear { return String(year) }
        return nil
    }

    private var technicalSummary: String {
        let minutes = Int((detail?.runTimeTicks.map { Double($0) / 10_000_000 } ?? item.duration ?? 0) / 60)
        let duration = minutes > 0 ? "\(minutes / 60)小时\(minutes % 60)分钟" : nil
        let size = source?.size.flatMap { $0 > 0 ? String(format: "%.2f GB", Double($0) / 1_000_000_000) : nil }
        let resolution: String? = {
            guard let width = video?.width else { return nil }
            if width >= 3840 { return "4K" }
            if width >= 1920 { return "1080p" }
            if width >= 1280 { return "720p" }
            return "\(width)p"
        }()
        let codec = video?.codec?.uppercased()
        return [duration, size, resolution, codec].compactMap { $0 }.joined(separator: " · ")
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let people = detail?.people, !people.isEmpty {
                Text("演职人员").font(.title3.bold()).foregroundStyle(detailInk)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(Array(people.prefix(20)), id: \.stableID) { person in
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
                                    Text(role).font(.caption2).foregroundStyle(detailInk.opacity(0.65)).lineLimit(1)
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
        DetailMediaMetadataPanel(streams: streams, source: source, path: detail?.path,
                                 providerIDs: detail?.providerIds, tmdbID: item.metadata?.providerID,
                                 isSeries: false, foreground: detailInk)
    }

    private func clock(_ seconds: Double) -> String {
        let time = Int(max(0, seconds))
        if time >= 3600 { return String(format: "%d:%02d:%02d", time / 3600, time / 60 % 60, time % 60) }
        return String(format: "%02d:%02d", time / 60, time % 60)
    }

    private func play() {
        var selected = item
        if let ticks = detail?.userData?.playbackPositionTicks {
            // The detail endpoint can still report 0 while local progress is ahead.
            selected.position = max(selected.position, Double(ticks) / 10_000_000)
        }
        if let duration = detail?.runTimeTicks {
            selected.duration = Double(duration) / 10_000_000
        }
        onPlay(selected)
    }

    private func load() async {
        guard let server else {
            detail = (library.items.first { $0.id == item.id } ?? item).localDetailItem()
            return
        }
        do {
            let requestedAt = Date()
            let loaded = try await ServerDetailClient.item(baseAddress: server.base,
                userID: server.user, itemID: server.itemID, token: server.token)
            try Task.checkCancellation()
            detail = loaded
            switch item.location {
            case .embyItem(let source, _), .jellyfinItem(let source, _):
                library.mergeServerCards([loaded], sourceID: source, requestedAt: requestedAt)
            default: break
            }
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
            metadata: item.metadata, title: remote?.name ?? item.title, television: false,
            language: TMDBService.deviceLanguage, token: token,
            displayWidthPixels: LucentDisplay.maximumArtworkPixels)
        guard !Task.isCancelled else { return }
        if let result, result.posterURL != nil || artwork == nil { artwork = result }
        artworkResolved = true
    }
}
