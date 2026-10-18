#if os(iOS)
import SwiftUI
import UIKit

private struct SeriesArtwork: View {
    let baseAddress: String?
    let token: String?
    let itemID: String?
    let backdrop: Bool
    let fallback: URL?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let fallback {
                AsyncImage(url: fallback) { image in image.resizable().scaledToFill() }
                    placeholder: { Rectangle().fill(.white.opacity(0.08)) }
            } else {
                Rectangle().fill(.white.opacity(0.08))
                    .overlay(Image(systemName: "film.stack").font(.largeTitle).foregroundStyle(.white.opacity(0.3)))
            }
        }
        .clipped()
        .task(id: "\(baseAddress ?? "")|\(itemID ?? "")|\(backdrop)") {
            image = nil
            guard let baseAddress, let token, let itemID, let base = URL(string: baseAddress) else { return }
            let path = backdrop ? "Backdrop/0" : "Primary"
            var components = URLComponents(url: base.appendingPathComponent("Items")
                .appendingPathComponent(itemID).appendingPathComponent("Images")
                .appendingPathComponent(path), resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "maxWidth", value: backdrop ? "1400" : "600")]
            guard let url = components?.url else { return }
            var request = URLRequest(url: url)
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            if let (data, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200,
               let decoded = UIImage(data: data) {
                image = decoded
            } else if backdrop {
                request.url = base.appendingPathComponent("Items")
                    .appendingPathComponent(itemID).appendingPathComponent("Images/Primary")
                if let (data, response) = try? await URLSession.shared.data(for: request),
                   (response as? HTTPURLResponse)?.statusCode == 200 {
                    image = UIImage(data: data)
                }
            }
        }
    }
}

struct SeriesDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem
    let onPlay: (MediaItem) -> Void

    @State private var page: ServerEpisodeClient.SeriesPage?
    @State private var season = 1
    @State private var episodePage = 0
    @State private var showAllEpisodes = false
    @State private var loading = false
    @State private var loadError: String?

    private var server: (base: String, user: String, token: String, sourceID: UUID, emby: Bool)? {
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
        episodes.first { $0.id == remoteID } ??
        episodes.first { ($0.userData?.playbackPositionTicks ?? 0) > 0 && $0.userData?.played != true } ??
        episodes.first { $0.userData?.played != true } ?? episodes.first
    }
    private var seriesName: String { page?.series.name ?? item.identity?.seriesName ?? item.title }
    private var isSeriesEntry: Bool {
        if case .episode(_, _, let number, _) = item.identity { return number == 0 }
        return false
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    hero(height: max(550, geometry.size.height * 0.68), width: geometry.size.width)
                    VStack(alignment: .leading, spacing: 24) {
                        if let summary = page?.series.overview ?? item.metadata?.summary ?? item.serverSummary,
                           !summary.isEmpty {
                            Text(summary).font(.subheadline).foregroundStyle(.white.opacity(0.85))
                                .lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        }
                        episodeSection
                        castSection
                    }
                    .padding(.horizontal, 22).padding(.top, 14).padding(.bottom, 48)
                    .frame(maxWidth: 780)
                    .frame(maxWidth: .infinity)
                }
            }
            .background(Color(red: 0.25, green: 0.19, blue: 0.22))
            .ignoresSafeArea(edges: .top)
        }
        .task(id: item.id) { await load() }
        .sheet(isPresented: $showAllEpisodes) { allEpisodesSheet }
        .preferredColorScheme(.dark)
    }

    private func hero(height: CGFloat, width: CGFloat) -> some View {
        ZStack(alignment: .bottom) {
            SeriesArtwork(baseAddress: server?.base, token: server?.token,
                          itemID: page?.series.id ?? remoteID, backdrop: true,
                          fallback: item.metadata?.posterURL)
                .frame(width: width, height: height).clipped()
                .overlay(LinearGradient(colors: [.black.opacity(0.25), .clear,
                                                 Color(red: 0.25, green: 0.19, blue: 0.22).opacity(0.35),
                                                 Color(red: 0.25, green: 0.19, blue: 0.22)],
                                        startPoint: .top, endPoint: .bottom))
            VStack(spacing: 13) {
                Text(seriesName)
                    .font(.system(size: 43, weight: .black, design: .rounded))
                    .tracking(-1.5).multilineTextAlignment(.center)
                    .shadow(color: .black.opacity(0.7), radius: 8)
                    .lineLimit(3).minimumScaleFactor(0.65)
                HStack(spacing: 7) {
                    if let rating = page?.series.communityRating ?? item.metadata?.rating {
                        Image(systemName: "star.fill").foregroundStyle(.yellow)
                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                    }
                    if let year = page?.series.productionYear { Text("·  \(year)") }
                    if let genres = page?.series.genres, !genres.isEmpty {
                        Text("·  " + genres.prefix(3).joined(separator: "、")).lineLimit(1)
                    }
                }
                .font(.subheadline.weight(.semibold))
                Text(details)
                    .font(.caption).foregroundStyle(.white.opacity(0.82))
                Button { play(activeEpisode) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "play.fill")
                        VStack(spacing: 1) {
                            Text(item.isInProgress || activeEpisode?.userData?.playbackPositionTicks ?? 0 > 0 ? "继续播放" : "开始播放")
                                .font(.headline)
                            if let position = activeEpisode?.userData?.playbackPositionTicks, position > 0 {
                                Text("上次播放到：\(clock(Double(position) / 10_000_000))")
                                    .font(.caption)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .foregroundStyle(.black).background(.white, in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(loading || (isSeriesEntry && activeEpisode == nil))
                HStack(spacing: 42) {
                    Button { library.toggleFavorite(id: item.id) } label: {
                        Image(systemName: item.isFavorite ? "heart.fill" : "heart")
                    }
                    Button { library.markWatched(id: item.id) } label: { Image(systemName: "flag") }
                }
                .font(.title3).foregroundStyle(.white.opacity(0.86)).padding(.top, 8)
            }
            .padding(.horizontal, 28).padding(.bottom, 12).frame(maxWidth: 660)
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left") }
                    Spacer()
                    Menu {
                        Button(item.watched ? "标记为未观看" : "标记为已看完") {
                            if item.watched { library.markUnwatched(id: item.id) }
                            else { library.markWatched(id: item.id) }
                        }
                        Button(item.isFavorite ? "取消收藏" : "收藏") { library.toggleFavorite(id: item.id) }
                    } label: { Image(systemName: "ellipsis") }
                }
                .font(.title3.weight(.semibold))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
                .padding(.horizontal, 26).padding(.top, 66)
                .background { Color.clear }
                Spacer()
            }
        }
        .frame(width: width, height: height)
    }

    private var details: String {
        let minutes = Int((activeEpisode?.runTimeTicks.map { Double($0) / 10_000_000 } ?? item.duration ?? 0) / 60)
        return ["共 \(max(seasons.count, 1)) 季", minutes > 0 ? "\(minutes) 分钟" : nil,
                !episodes.isEmpty ? "\(episodes.count) 集" : nil,
                activeEpisode?.mediaSources?.first?.mediaStreams?.contains(where: { ($0.width ?? 0) >= 3840 }) == true ? "4K" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }

    private var episodeSection: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Menu {
                    ForEach(seasons, id: \.self) { number in
                        Button("第 \(number) 季") { season = number; episodePage = 0 }
                    }
                } label: {
                    HStack(spacing: 5) { Text("第 \(season) 季"); Image(systemName: "chevron.down").font(.caption) }
                }
                .disabled(seasons.isEmpty)
                Spacer()
                Button("查看全部", systemImage: "chevron.right") { showAllEpisodes = true }
                    .labelStyle(.titleAndIcon).font(.subheadline.weight(.semibold))
                    .disabled(episodes.isEmpty)
            }
            .font(.title3.bold()).foregroundStyle(.white)
            if loading { ProgressView().tint(.white) }
            else if let loadError { Text(loadError).font(.footnote).foregroundStyle(.white.opacity(0.72)) }
            else if episodes.isEmpty { Text("暂无剧集信息").foregroundStyle(.white.opacity(0.7)) }
            else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(shownEpisodes, id: \.id) { episode in
                            Button { play(episode) } label: { episodeCard(episode) }.buttonStyle(.plain)
                        }
                    }
                }
                .contentMargins(.trailing, 22)
                if seasonEpisodes.count > 10 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(0..<Int(ceil(Double(seasonEpisodes.count) / 10)), id: \.self) { index in
                                Button("\(index * 10 + 1)–\(min((index + 1) * 10, seasonEpisodes.count))") {
                                    episodePage = index
                                }
                                .padding(.horizontal, 13).padding(.vertical, 7)
                                .background(episodePage == index ? .white.opacity(0.22) : .white.opacity(0.09),
                                            in: Capsule())
                            }
                        }
                    }
                    .font(.subheadline).foregroundStyle(.white)
                }
            }
        }
    }

    private func episodeCard(_ episode: JellyfinItem) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SeriesArtwork(baseAddress: server?.base, token: server?.token,
                          itemID: episode.id, backdrop: false, fallback: nil)
                .frame(width: 210, height: 122).clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(alignment: .topTrailing) {
                    if episode.userData?.played == true {
                        Image(systemName: "checkmark").font(.caption.bold())
                            .foregroundStyle(.black).padding(6).background(.white, in: Circle())
                            .padding(8)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let ticks = episode.userData?.playbackPositionTicks,
                       let duration = episode.runTimeTicks, duration > 0, ticks > 0 {
                        GeometryReader { proxy in
                            Capsule().fill(.white.opacity(0.6))
                                .overlay(alignment: .leading) {
                                    Capsule().fill(.white).frame(width: proxy.size.width * min(1, Double(ticks) / Double(duration)))
                                }
                        }
                        .frame(height: 3).padding(.horizontal, 10).padding(.bottom, 8)
                    }
                }
                .overlay(RoundedRectangle(cornerRadius: 14)
                    .stroke(episode.id == activeEpisode?.id ? .white : .clear, lineWidth: 2))
            Text("\(episode.indexNumber ?? 0). \(episode.name)")
                .font(.subheadline.weight(.medium)).lineLimit(1)
            Text("第 \(episode.parentIndexNumber ?? season) 季 · 第 \(episode.indexNumber ?? 0) 集")
                .font(.caption).foregroundStyle(.white.opacity(0.65))
        }
        .frame(width: 210, alignment: .leading).foregroundStyle(.white)
    }

    private var castSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let people = page?.series.people?.filter({ $0.role != nil || !$0.name.isEmpty }), !people.isEmpty {
                Text("演职人员").font(.title3.bold()).foregroundStyle(.white)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 13) {
                        ForEach(Array(people.prefix(16)), id: \.stableID) { person in
                            VStack(alignment: .leading, spacing: 5) {
                                SeriesArtwork(baseAddress: server?.base, token: server?.token,
                                              itemID: person.id, backdrop: false, fallback: nil)
                                    .frame(width: 88, height: 112).clipShape(RoundedRectangle(cornerRadius: 13))
                                Text(person.name).font(.caption.weight(.semibold)).lineLimit(1)
                                if let role = person.role {
                                    Text(role).font(.caption2).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
                                }
                            }
                            .frame(width: 88, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    private var allEpisodesSheet: some View {
        NavigationStack {
            List {
                ForEach(seasons, id: \.self) { number in
                    Section("第 \(number) 季") {
                        ForEach(episodes.filter { $0.parentIndexNumber == number }, id: \.id) { episode in
                            Button { showAllEpisodes = false; play(episode) } label: {
                                HStack {
                                    Text("\(episode.indexNumber ?? 0). \(episode.name)")
                                    Spacer()
                                    if episode.userData?.played == true { Image(systemName: "checkmark.circle.fill") }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("全部剧集")
            .toolbar { Button("完成") { showAllEpisodes = false } }
        }
    }

    private func play(_ episode: JellyfinItem?) {
        guard let episode, let server else {
            if !isSeriesEntry { onPlay(item) }
            return
        }
        let selected = server.emby
            ? library.openEmbyItem(sourceID: server.sourceID, remote: episode)
            : library.openJellyfinItem(sourceID: server.sourceID, remote: episode)
        onPlay(selected)
    }

    private func clock(_ seconds: Double) -> String {
        let time = Int(max(0, seconds))
        return String(format: "%02d:%02d", time / 60, time % 60)
    }

    private func load() async {
        guard let server, let remoteID else { return }
        loading = true
        loadError = nil
        defer { loading = false }
        do {
            page = try await ServerEpisodeClient.seriesPage(baseAddress: server.base,
                userID: server.user, itemID: remoteID, token: server.token)
            if let currentSeason = activeEpisode?.parentIndexNumber { season = currentSeason }
            let currentIndex = seasonEpisodes.firstIndex { $0.id == activeEpisode?.id } ?? 0
            episodePage = currentIndex / 10
        } catch {
            loadError = error.localizedDescription
        }
    }
}
#endif
