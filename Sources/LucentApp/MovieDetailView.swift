#if os(iOS)
import SwiftUI

struct MovieDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let onPlay: (MediaItem) -> Void
    let onMore: () -> Void

    @State private var detail: JellyfinItem?
    @State private var overviewExpanded = false
    @State private var loadError: String?

    private let background = Color(red: 0.27, green: 0.22, blue: 0.20)

    private var server: (base: String, user: String, token: String, itemID: String)? {
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
    private var audio: [JellyfinItem.MediaSource.Stream] { streams.filter { $0.type == "Audio" } }
    private var subtitles: [JellyfinItem.MediaSource.Stream] { streams.filter { $0.type == "Subtitle" } }
    private var progressSeconds: Double {
        max(item.position, Double(detail?.userData?.playbackPositionTicks ?? 0) / 10_000_000)
    }
    private var isInProgress: Bool { progressSeconds > 30 && !item.watched }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(width: geometry.size.width,
                         height: max(620, geometry.size.height * 0.76))
                    VStack(alignment: .leading, spacing: 26) {
                        if let summary = detail?.overview ?? item.metadata?.summary ?? item.serverSummary,
                           !summary.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .lineSpacing(4)
                                    .lineLimit(overviewExpanded ? nil : 4)
                                if summary.count > 110 {
                                    Button(overviewExpanded ? "收起简介" : "展开简介") {
                                        withAnimation(.easeInOut(duration: 0.2)) { overviewExpanded.toggle() }
                                    }
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white)
                                }
                            }
                        }
                        castSection
                        mediaSection
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
            }
            .background(background)
            .ignoresSafeArea(edges: .top)
        }
        .task(id: item.id) { await load() }
        .preferredColorScheme(.dark)
    }

    private func hero(width: CGFloat, height: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            SeriesArtwork(baseAddress: server?.base, token: server?.token,
                          itemID: server?.itemID, backdrop: false,
                          fallback: library.posterURL(for: item) ?? item.metadata?.posterURL)
                .frame(width: width, height: height)
                .clipped()
                .overlay {
                    LinearGradient(colors: [.black.opacity(0.28), .clear,
                                            background.opacity(0.15), background.opacity(0.72),
                                            background],
                                   startPoint: .top, endPoint: .bottom)
                }
            VStack(spacing: 12) {
                Text(detail?.name ?? item.title)
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.68)
                    .shadow(color: .black.opacity(0.65), radius: 7)
                HStack(spacing: 7) {
                    if let rating = detail?.communityRating ?? item.metadata?.rating {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                    }
                    if let date = displayDate { Text("·  " + date) }
                    if let genres = detail?.genres, !genres.isEmpty {
                        Text("·  " + genres.prefix(2).joined(separator: "、")).lineLimit(1)
                    }
                }
                .font(.subheadline.weight(.semibold))
                Text(technicalSummary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                Button { play() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        VStack(spacing: 2) {
                            Text(isInProgress ? "继续播放" : "开始播放").font(.headline)
                            if isInProgress {
                                Text("上次播放到：\(clock(progressSeconds))").font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 62)
                    .foregroundStyle(.black)
                    .background(.white.opacity(0.94), in: Capsule())
                }
                .buttonStyle(.plain)
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
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .frame(width: 46, height: 46)
                            .background(.black.opacity(0.5), in: Circle())
                    }
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
                            .background(.black.opacity(0.5), in: Circle())
                    }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, 26)
                .padding(.top, 66)
                Spacer()
            }
        }
        .frame(width: width, height: height)
    }

    private var displayDate: String? {
        if let raw = detail?.premiereDate, raw.count >= 10 {
            return String(raw.prefix(10)).replacingOccurrences(of: "-", with: "/")
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
                                                      itemID: person.id, backdrop: false, fallback: nil)
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
                                Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
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
        VStack(alignment: .leading, spacing: 14) {
            Text("音视频字幕信息")
                .font(.title3.bold())
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 9) {
                if let video {
                    infoRow("视频", [video.width.map(String.init), video.height.map { "× \($0)" },
                                    video.codec?.uppercased(), video.videoRangeType]
                        .compactMap { $0 }.joined(separator: " "))
                }
                if !audio.isEmpty {
                    infoRow("音轨", audio.compactMap { $0.displayTitle ?? $0.language ?? $0.codec }.joined(separator: " · "))
                }
                if !subtitles.isEmpty {
                    infoRow("字幕", subtitles.compactMap { $0.displayTitle ?? $0.language }.joined(separator: " · "))
                }
                if let container = source?.container {
                    infoRow("封装", container.uppercased())
                }
                if source == nil { Text("暂无媒体流信息").foregroundStyle(.white.opacity(0.65)) }
            }
            .font(.subheadline)
            .padding(17)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(label).foregroundStyle(.white.opacity(0.6)).frame(width: 40, alignment: .leading)
            Text(value).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let time = Int(max(0, seconds))
        return String(format: "%02d:%02d", time / 60, time % 60)
    }

    private func play() {
        var selected = item
        if let ticks = detail?.userData?.playbackPositionTicks {
            selected.position = Double(ticks) / 10_000_000
        }
        if let duration = detail?.runTimeTicks {
            selected.duration = Double(duration) / 10_000_000
        }
        onPlay(selected)
    }

    private func load() async {
        guard let server else { return }
        do {
            detail = try await ServerDetailClient.item(baseAddress: server.base,
                userID: server.user, itemID: server.itemID, token: server.token)
        } catch {
            loadError = error.localizedDescription
        }
    }
}
#endif
