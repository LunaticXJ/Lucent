import SwiftUI

struct MovieDetailView: View {
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

    private let background = Color(red: 0.27, green: 0.22, blue: 0.20)

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
                    StretchyHeroHeader(height: max(620, geometry.size.height * 0.76)) { height, pull in
                        hero(width: geometry.size.width, height: height, pull: pull)
                    }
                    VStack(alignment: .leading, spacing: 26) {
                        if let summary = detail?.overview ?? item.metadata?.summary ?? item.serverSummary,
                           !summary.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineSpacing(4)
                                    .lineLimit(4)
                                if summary.count > 110 {
                                    Button("展开简介") {
                                        overviewExpanded = true
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                }
                            }
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
                                    DetailSkeletonBlock().frame(width: 88, height: 112)
                                }
                            }
                        } else {
                            castSection
                            mediaSection
                        }
                        if let loadError {
                            Text(loadError).font(.caption).foregroundStyle(.white.opacity(0.65))
                        }
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 54)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
                .frame(width: geometry.size.width, alignment: .leading)
            }
            .background(background)
            .ignoresSafeArea(edges: .top)
            .coordinateSpace(name: "lucentHeroScroll")
        }
        .overlay(alignment: .top) {
            topControls
                .padding(.top, 8)
        }
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
        .preferredColorScheme(.dark)
    }

    private var topControls: some View {
                HStack {
                    LucentToolbarButton(symbol: "chevron.left", label: "返回", role: .videoOverlay) { if let onBack { onBack() } else { dismiss() } }
                    Spacer()
                    Menu {
                        Button(item.watched ? "标记为未观看" : "标记为已看完") {
                            if item.watched { library.markUnwatched(id: item.id) }
                            else { library.markWatched(id: item.id) }
                        }
                        Button(item.isFavorite ? "取消收藏" : "收藏") {
                            library.toggleFavorite(id: item.id)
                        }
                        Button("更多播放选项与资料", systemImage: "slider.horizontal.3") {
                            onMore()
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 46, height: 46)
                            .modifier(LucentGlass(shape: Circle(), role: .videoOverlay))
                    }
                }
        .font(.title3.weight(.semibold))
        .foregroundStyle(.white)
        .lucentContentButtonStyle()
        .padding(.horizontal, 26)
    }

    private func hero(width: CGFloat, height: CGFloat, pull: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            if artworkResolved {
                SeriesArtwork(baseAddress: server?.base, token: server?.token,
                              itemID: server?.itemID, backdrop: false,
                              fallback: library.posterURL(for: item) ?? item.metadata?.posterURL,
                              preferredURL: artwork?.posterURL, maximumWidth: 1400)
                    .frame(width: width, height: height)
                    .scaleEffect(1 + min(pull / max(height - pull, 1), 0.4), anchor: .top)
                    .clipped()
            } else { DetailSkeletonBlock(cornerRadius: 0).frame(width: width, height: height) }
            LinearGradient(colors: [.black.opacity(0.28), .clear,
                                    background.opacity(0.15), background.opacity(0.72), background],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 12) {
                if artworkResolved {
                    DetailTitleArtwork(url: artwork?.logoURL,
                                       title: artwork?.localizedTitle ?? detail?.name ?? item.title,
                                       fallbackRequest: server.flatMap { ServerDetailClient.logoRequest(baseAddress: $0.base, token: $0.token, itemID: $0.itemID) })
                } else {
                    Color.clear.frame(height: 125)
                }
                HStack(spacing: 7) {
                    if let rating = detail?.communityRating ?? item.metadata?.rating {
                        Image(systemName: "star.fill").foregroundStyle(LucentUI.ratingTint)
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                    }
                    if let date = displayDate { Text("·  " + date) }
                    if let genres = detail?.genres, !genres.isEmpty {
                        Text("·  " + genres.prefix(2).joined(separator: "、")).lineLimit(1)
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                Text(technicalSummary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                LucentPlayButton(resumeTime: isInProgress ? clock(progressSeconds) : nil) { play() }
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
                .foregroundStyle(.white.opacity(0.9))
                .padding(.top, 7)
            }
            .frame(maxWidth: 660)
            .padding(.horizontal, 28)
            .padding(.bottom, 20)
        }
        .frame(width: width, height: height)
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
        let size = source?.size.map { String(format: "%.2f GB", Double($0) / 1_000_000_000) }
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
                Text("演职人员").font(.title3.bold()).foregroundStyle(.white)
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
                                                .foregroundStyle(.white.opacity(0.8)))
                                    }
                                }
                                .frame(width: 88, height: 112)
                                .clipShape(RoundedRectangle(cornerRadius: 13))
                                Text(person.name).font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                                if let role = person.role {
                                    Text(role).font(.caption2).foregroundStyle(.white.opacity(0.65)).lineLimit(1)
                                }
                            }
                            .frame(width: 88, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var mediaSection: some View {
        DetailMediaMetadataPanel(streams: streams, source: source, path: detail?.path,
                                 providerIDs: detail?.providerIds, tmdbID: item.metadata?.providerID,
                                 isSeries: false)
    }

    private func clock(_ seconds: Double) -> String {
        let time = Int(max(0, seconds))
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
            detail = try await ServerDetailClient.item(baseAddress: server.base,
                userID: server.user, itemID: server.itemID, token: server.token)
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
