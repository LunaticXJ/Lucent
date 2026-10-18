import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct ServerPlaybackVersion: Identifiable {
    let id: String
    let title: String
    let mediaSourceID: String?
    let plexPartKey: String?
    let plexPartID: Int?
    let plexMediaIndex: Int?
    let streams: [JellyfinItem.MediaSource.Stream]
    let plexStreams: [PlexItem.MediaEntry.Part.Stream]
    let container: String?
    let features: PlaybackMediaFeatures
    var dolbyVisionStream: JellyfinItem.MediaSource.Stream? {
        streams.first(where: DolbyVisionSupport.isDolbyVision)
    }
    var isDolbyVision: Bool {
        if dolbyVisionStream != nil { return true }
        let markers = [features.dynamicRange, features.videoCodec]
            .compactMap { $0?.lowercased() }
        return markers.contains { $0.contains("dolby vision") || $0.contains("dovi") ||
            $0.contains("dvhe") || $0.contains("dvh1") }
    }
}

private extension MediaItem {
    var isMediaServerItem: Bool {
        switch location {
        case .jellyfinItem, .embyItem, .plexItem: true
        default: false
        }
    }
}

struct MediaDetailView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @State private var playingItem: MediaItem?
    @State private var editingItem: MediaItem?
    @State private var showMetadata = false
    @State private var activeDownloadTask: Task<Void, Never>?
    @State private var showSubtitleImporter = false
    @State private var extras: TMDBService.Extras?
    @State private var showExtraPicker = false
    @State private var showOnlineSubtitles = false
    @State private var subtitleAPIKey = ""
    @State private var subtitleLanguage = "zh-CN"
    @State private var subtitleMatches: [OpenSubtitlesClient.Result] = []
    @State private var subtitleStatus: String?
    @State private var subtitleBusy = false
    @State private var extraSearch = ""
    @State private var serverVersions: [ServerPlaybackVersion] = []
    @State private var selectedServerMediaSourceID: String?
    @State private var forceRemoteVersion = false
    @State private var selectedTranscodeBitrate: Int?
    @State private var selectedAudioStreamIndex: Int?
    @State private var selectedSubtitleStreamIndex: Int?
    @State private var selectedPlexPartID: Int?
    @State private var selectedPlexMediaIndex = 0
    let itemID: UUID

    private var item: MediaItem? { library.visibleItems.first { $0.id == itemID } }

    var body: some View {
        NavigationStack {
            Group {
                if let item {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if let localURL = library.posterURL(for: item) {
                                LocalPosterView(url: localURL)
                                    .frame(maxWidth: .infinity, minHeight: 180)
                            } else if let posterURL = item.metadata?.posterURL {
                                AsyncImage(url: posterURL) { image in
                                    image.resizable().scaledToFit()
                                } placeholder: {
                                    ProgressView()
                                }
                                .frame(maxWidth: .infinity, minHeight: 180)
                            } else {
                                Image(systemName: "film.stack")
                                    .font(.system(size: 72, weight: .ultraLight))
                                    .foregroundStyle(.tint)
                                    .frame(maxWidth: .infinity, minHeight: 180)
                                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 20))
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(item.title).font(.largeTitle.bold())
                                if let label = item.identity?.episodeLabel {
                                    Text(label).foregroundStyle(.secondary)
                                }
                                Text(item.watched ? "已看完" : item.isInProgress ? "观看中" : "未观看")
                                    .foregroundStyle(.secondary)
                                if item.progress > 0 { ProgressView(value: item.progress) }
                                if let version = activeVersion(for: item), version.isDolbyVision {
                                    Label("Dolby Vision" + (version.dolbyVisionStream.flatMap(DolbyVisionSupport.profile)
                                            .map { " P\($0)" } ?? ""),
                                          systemImage: "sparkles.tv")
                                        .font(.subheadline.weight(.semibold))
                                    if !DolbyVisionSupport.isApplePlaybackContainer(version.container) {
                                        Text("此版本为 \(version.container?.uppercased() ?? "未知") 容器；可选择 MP4/MOV 版本以保留杜比视界播放路径。")
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                }
                            }

                            HStack {
                                Button(item.isInProgress ? "继续播放" : "播放", systemImage: "play.fill") {
                                    selectedServerMediaSourceID = nil
                                    selectedPlexPartID = nil
                                    selectedPlexMediaIndex = 0
                                    selectedAudioStreamIndex = nil
                                    selectedSubtitleStreamIndex = nil
                                    forceRemoteVersion = false
                                    selectedTranscodeBitrate = nil
                                    playingItem = item
                                }
                                .buttonStyle(.borderedProminent)
                                Button(item.isFavorite ? "取消收藏" : "收藏",
                                       systemImage: item.isFavorite ? "star.fill" : "star") {
                                    library.toggleFavorite(id: item.id)
                                }
                                .buttonStyle(.bordered)
                            }
                            if !serverVersions.isEmpty {
                                VStack(alignment: .leading, spacing: 10) {
                                    Text("可用版本").font(.title3.bold())
                                    ForEach(serverVersions) { version in
                                        Button {
                                            selectVersion(version, item: item)
                                        } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: !version.isDolbyVision ?
                                                      "film" : "sparkles.tv")
                                                    .frame(width: 28)
                                                VStack(alignment: .leading, spacing: 4) {
                                                    Text(version.title).font(.subheadline.weight(.semibold))
                                                    Text([version.features.resolution,
                                                          version.features.videoCodec,
                                                          version.features.dynamicRange,
                                                          version.container?.uppercased()]
                                                        .compactMap { $0 }.joined(separator: " · "))
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                                Spacer()
                                                Image(systemName: version.id == activeVersion(for: item)?.id ?
                                                      "checkmark.circle.fill" : "play.fill")
                                                    .font(.caption)
                                            }
                                            .padding(12)
                                            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                            if item.isMediaServerItem {
                                if serverVersions.count > 1 {
                                    Menu("版本与画质") {
                                        ForEach(serverVersions) { version in
                                            Menu(version.title) {
                                                ForEach([20, 10, 5, 2], id: \.self) { megabits in
                                                    Button("\(megabits) Mbps") {
                                                        playTranscoded(version: version, bitrate: megabits * 1_000_000, item: item)
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                                if let version = serverVersions.first(where: {
                                    $0.mediaSourceID == selectedServerMediaSourceID
                                }) ?? serverVersions.first, !version.streams.isEmpty {
                                    Menu("转码音轨") {
                                        ForEach(version.streams.filter { $0.type == "Audio" && $0.index != nil }, id: \.index) { stream in
                                            Button(stream.displayTitle ?? stream.language ?? "音轨 \(stream.index ?? 0)") {
                                                selectedAudioStreamIndex = stream.index
                                            }
                                        }
                                    }
                                    Menu("转码字幕") {
                                        Button("关闭字幕") { selectedSubtitleStreamIndex = -1 }
                                        ForEach(version.streams.filter { $0.type == "Subtitle" && $0.index != nil }, id: \.index) { stream in
                                            Button(stream.displayTitle ?? stream.language ?? "字幕 \(stream.index ?? 0)") {
                                                selectedSubtitleStreamIndex = stream.index
                                            }
                                        }
                                    }
                                }
                                if case .plexItem = item.location,
                                   let version = serverVersions.first(where: { $0.plexMediaIndex == selectedPlexMediaIndex }) {
                                    Menu("转码音轨") {
                                        ForEach(version.plexStreams.filter { $0.streamType == 2 && $0.id != nil }, id: \.id) { stream in
                                            Button(stream.displayTitle ?? stream.language ?? "音轨 \(stream.id ?? 0)") {
                                                selectedPlexPartID = version.plexPartID
                                                selectedAudioStreamIndex = stream.id
                                            }
                                        }
                                    }
                                    Menu("转码字幕") {
                                        Button("关闭字幕") {
                                            selectedPlexPartID = version.plexPartID
                                            selectedSubtitleStreamIndex = 0
                                        }
                                        ForEach(version.plexStreams.filter { $0.streamType == 3 && $0.id != nil }, id: \.id) { stream in
                                            Button(stream.displayTitle ?? stream.language ?? "字幕 \(stream.id ?? 0)") {
                                                selectedPlexPartID = version.plexPartID
                                                selectedSubtitleStreamIndex = stream.id
                                            }
                                        }
                                    }
                                }
                                Menu("转码播放") {
                                    ForEach([20, 10, 5, 2], id: \.self) { megabits in
                                        Button("\(megabits) Mbps") {
                                            forceRemoteVersion = true
                                            selectedTranscodeBitrate = megabits * 1_000_000
                                            playingItem = item
                                        }
                                    }
                                }
                                .buttonStyle(.bordered)
                            }
                            #if !os(tvOS)
                            if library.downloadedURL(for: item) != nil {
                                Button("移除离线文件", role: .destructive) { library.removeDownload(id: item.id) }
                                    .buttonStyle(.bordered)
                            } else if canDownload(item) {
                                Button(library.hasPausedDownload(id: item.id) ? "继续下载" : "下载到本机",
                                       systemImage: "arrow.down.circle") {
                                    activeDownloadTask = Task { await library.download(id: item.id) }
                                }
                                .buttonStyle(.bordered)
                                .disabled(library.downloading.contains(item.id))
                                if library.hasPausedDownload(id: item.id),
                                   !library.downloading.contains(item.id) {
                                    Button("删除未完成下载", role: .destructive) {
                                        library.cancelDownload(id: item.id)
                                    }
                                }
                                if library.downloading.contains(item.id) {
                                    ProgressView(value: library.downloadProgress[item.id] ?? 0)
                                    Button("暂停下载") {
                                        Task { await library.pauseDownload(id: item.id) }
                                    }
                                    Button("取消下载") {
                                        activeDownloadTask?.cancel()
                                        library.cancelDownload(id: item.id)
                                    }
                                }
                            }
                            #endif
                            let attachedExtras = library.visibleItems.filter {
                                (item.extraItemIDs ?? []).contains($0.id)
                            }
                            if !attachedExtras.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("附加片段").font(.title3.bold())
                                    ForEach(attachedExtras) { extra in
                                        Button(extra.title, systemImage: "play.rectangle") {
                                            selectedServerMediaSourceID = nil
                                            forceRemoteVersion = false
                                            selectedTranscodeBitrate = nil
                                            playingItem = extra
                                        }
                                    }
                                }
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                detailRow("来源", sourceDescription(item))
                                detailRow("添加时间", item.addedAt.formatted(date: .abbreviated, time: .shortened))
                            if let date = item.lastPlayedAt {
                                    detailRow("上次播放", date.formatted(date: .abbreviated, time: .shortened))
                                }
                                if let duration = item.duration {
                                    detailRow("时长", duration.formatted(.number.precision(.fractionLength(0))) + " 秒")
                                }
                            }
                            if let summary = item.metadata?.summary ?? item.serverSummary, !summary.isEmpty {
                                Text(summary).font(.body)
                            }
                            if let rating = item.metadata?.rating {
                                Text("TMDB 评分：\(rating.formatted(.number.precision(.fractionLength(1))))")
                                    .font(.subheadline)
                            }
                            Picker("我的评分", selection: Binding(
                                get: { item.personalRating ?? 0 },
                                set: { library.setPersonalRating(id: item.id, rating: $0 == 0 ? nil : $0) }
                            )) {
                                Text("未评分").tag(0)
                                ForEach(1...10, id: \.self) { value in
                                    Text("\(value) / 10").tag(value)
                                }
                            }
                            if let cast = extras?.credits?.cast, !cast.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("演职员").font(.title3.bold())
                                    ForEach(Array(cast.prefix(12))) { person in
                                        Text(person.character.map { "\(person.name) · \($0)" } ?? person.name)
                                            .font(.subheadline)
                                    }
                                }
                            }
                            #if !os(tvOS)
                            if let trailers = extras?.videos?.results.filter({ $0.type == "Trailer" && $0.externalURL != nil }),
                               !trailers.isEmpty {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text("预告片").font(.title3.bold())
                                    ForEach(trailers.prefix(5)) { trailer in
                                        if let url = trailer.externalURL { Link(trailer.name, destination: url) }
                                    }
                                }
                            }
                            #endif

                            VStack(alignment: .leading, spacing: 12) {
                                if library.activeProfile?.isChild != true {
                                Button("编辑资料") { editingItem = item }
                                Button("匹配在线资料") { showMetadata = true }
                                Button("管理附加片段") { extraSearch = ""; showExtraPicker = true }
                                Button("查找在线字幕") {
                                    subtitleAPIKey = (try? KeychainPasswordStore.openSubtitlesAPIKey()) ?? ""
                                    subtitleMatches = []
                                    subtitleStatus = nil
                                    showOnlineSubtitles = true
                                }
                                #if !os(tvOS)
                                Button("导入字幕文件") { showSubtitleImporter = true }
                                #endif
                                if library.subtitleURL(for: item) != nil {
                                    Button("移除导入的字幕", role: .destructive) {
                                        library.removeSubtitle(id: item.id)
                                    }
                                }
                                if !library.collections.isEmpty {
                                    Menu("加入合集") {
                                        ForEach(library.collections) { collection in
                                            let included = collection.itemIDs.contains(item.id)
                                            Button(included ? "✓ \(collection.name)" : collection.name) {
                                                library.setCollectionItem(collectionID: collection.id,
                                                                          itemID: item.id, included: !included)
                                            }
                                        }
                                    }
                                }
                                let childProfiles = library.viewerProfiles.filter(\.isChild)
                                if !childProfiles.isEmpty {
                                    Menu("儿童资料可见性") {
                                        ForEach(childProfiles) { profile in
                                            let visible = !profile.blockedItemIDs.contains(item.id)
                                            Button("\(profile.name)：\(visible ? "可见" : "隐藏")") {
                                                library.setChildVisibility(profileID: profile.id,
                                                                           itemID: item.id, visible: !visible)
                                            }
                                        }
                                    }
                                }
                                }
                                Button(item.watched ? "标记为未观看" : "标记为已看完") {
                                    if item.watched { library.markUnwatched(id: item.id) }
                                    else { library.markWatched(id: item.id) }
                                }
                            }
                            .buttonStyle(.bordered)
                            if item.metadata != nil {
                                Text("影片资料由 TMDB 提供。")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: 700, alignment: .leading)
                        .padding(24)
                        .frame(maxWidth: .infinity)
                    }
                } else {
                    ContentUnavailableView("影片已移除", systemImage: "film")
                }
            }
            .navigationTitle("影片详情")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } }
            }
            .sheet(item: $playingItem) { item in
                let next = nextEpisode(after: item)
                PlaybackView(item: item, nextItem: next,
                             serverMediaSourceID: selectedServerMediaSourceID,
                             serverContainer: activeVersion(for: item)?.container,
                             serverDolbyVision: activeVersion(for: item)?.isDolbyVision == true,
                             mediaFeatures: activeVersion(for: item)?.features ?? .unknown,
                             forceRemoteVersion: forceRemoteVersion,
                             transcodeBitrate: selectedTranscodeBitrate,
                             audioStreamIndex: selectedAudioStreamIndex,
                             subtitleStreamIndex: selectedSubtitleStreamIndex,
                             plexPartID: selectedPlexPartID,
                             plexMediaIndex: selectedPlexMediaIndex,
                             serverTracks: playbackTracks(for: item)) {
                    if let next {
                        selectedServerMediaSourceID = nil
                        forceRemoteVersion = false
                        selectedTranscodeBitrate = nil
                        playingItem = next
                    }
                }
                .id(item.id)
                .environmentObject(library)
            }
            .task(id: itemID) { await loadServerVersions() }
            .sheet(item: $editingItem) { item in
                MediaEditView(item: item).environmentObject(library)
            }
            .sheet(isPresented: $showMetadata) {
                if let item {
                    MetadataMatchView(item: item).environmentObject(library)
                }
            }
            .sheet(isPresented: $showExtraPicker) {
                NavigationStack {
                    List {
                        ForEach(library.visibleItems.filter {
                            $0.id != itemID &&
                            (extraSearch.isEmpty || $0.title.localizedCaseInsensitiveContains(extraSearch))
                        }) { candidate in
                            let included = item?.extraItemIDs?.contains(candidate.id) == true
                            Button("\(included ? "✓ " : "")\(candidate.title)") {
                                library.setExtra(parentID: itemID, extraID: candidate.id,
                                                 included: !included)
                            }
                        }
                    }
                    .searchable(text: $extraSearch, prompt: "搜索附加片段")
                    .navigationTitle("管理附加片段")
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { showExtraPicker = false }
                        }
                    }
                }
            }
            .sheet(isPresented: $showOnlineSubtitles) { onlineSubtitleSheet }
            .alert("无法完成操作", isPresented: Binding(
                get: { library.errorMessage != nil },
                set: { if !$0 { library.errorMessage = nil } }
            )) {
                Button("好") { library.errorMessage = nil }
            } message: {
                Text(library.errorMessage ?? "未知错误")
            }
            .task(id: "\(itemID.uuidString)|\(item?.metadata?.posterPath ?? "")|\(item?.serverPosterKey ?? "")") {
                await library.ensurePoster(id: itemID)
            }
            .task(id: item?.metadata?.providerID) {
                extras = nil
                guard let item, let id = item.metadata?.providerID,
                      let token = try? KeychainPasswordStore.metadataToken(), !token.isEmpty else { return }
                extras = try? await TMDBService.extras(id: id,
                                                       television: item.identity?.seriesName != nil,
                                                       token: token)
            }
            #if !os(tvOS)
            .fileImporter(isPresented: $showSubtitleImporter, allowedContentTypes: [.item]) { result in
                switch result {
                case .success(let url): library.importSubtitle(id: itemID, from: url)
                case .failure(let error): library.errorMessage = error.localizedDescription
                }
            }
            #endif
        }
    }

    private var onlineSubtitleSheet: some View {
        NavigationStack {
            Form {
                SecureField("OpenSubtitles API 密钥", text: $subtitleAPIKey)
                TextField("语言代码（如 zh-CN、en）", text: $subtitleLanguage)
                Button("搜索字幕") { searchOnlineSubtitles() }
                    .disabled(subtitleBusy || subtitleAPIKey.isEmpty || subtitleLanguage.isEmpty)
                if subtitleBusy { ProgressView() }
                if let subtitleStatus { Text(subtitleStatus).foregroundStyle(.secondary) }
                if !subtitleMatches.isEmpty {
                    Section("搜索结果") {
                        ForEach(subtitleMatches) { result in
                            Button {
                                downloadOnlineSubtitle(result)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(result.release).lineLimit(2)
                                    Text("\(result.language) · 下载 \(result.downloads) 次\(result.hearingImpaired ? " · 听障字幕" : "")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(subtitleBusy)
                        }
                    }
                }
            }
            .navigationTitle("在线字幕")
            .toolbar { Button("完成") { showOnlineSubtitles = false } }
        }
    }

    private func loadServerVersions() async {
        guard let item else { return }
        do {
            switch item.location {
            case .jellyfinItem(let sourceID, let itemID):
                guard let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.jellyfinToken(for: sourceID) else { return }
                let sources = try await JellyfinClient.versions(source: source, token: token, itemID: itemID)
                serverVersions = sources.enumerated().compactMap { index, source in
                    guard let id = source.id else { return nil }
                    return ServerPlaybackVersion(id: id,
                        title: source.name ?? "版本 \(index + 1) · \(source.container ?? "视频")",
                        mediaSourceID: id, plexPartKey: nil, plexPartID: nil,
                        plexMediaIndex: nil, streams: source.mediaStreams ?? [], plexStreams: [],
                        container: source.container, features: features(for: source))
                }
            case .embyItem(let sourceID, let itemID):
                guard let source = library.embySources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.embyToken(for: sourceID) else { return }
                let sources = try await EmbyClient.versions(source: source, token: token, itemID: itemID)
                serverVersions = sources.enumerated().compactMap { index, source in
                    guard let id = source.id else { return nil }
                    return ServerPlaybackVersion(id: id,
                        title: source.name ?? "版本 \(index + 1) · \(source.container ?? "视频")",
                        mediaSourceID: id, plexPartKey: nil, plexPartID: nil,
                        plexMediaIndex: nil, streams: source.mediaStreams ?? [], plexStreams: [],
                        container: source.container, features: features(for: source))
                }
            case .plexItem(let sourceID, let ratingKey, _):
                guard let source = library.plexSources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.plexToken(for: sourceID) else { return }
                let versions = try await PlexClient.versions(source: source, token: token,
                                                             ratingKey: ratingKey)
                serverVersions = versions.enumerated().compactMap { index, version in
                    guard let part = version.Part?.first else { return nil }
                    let resolution = version.videoResolution ?? "视频"
                    return ServerPlaybackVersion(id: part.key,
                        title: "版本 \(index + 1) · \(resolution)",
                        mediaSourceID: nil, plexPartKey: part.key, plexPartID: part.id,
                        plexMediaIndex: index, streams: [], plexStreams: part.streams ?? [],
                        container: (part.key as NSString).pathExtension,
                        features: PlaybackMediaFeatures(
                            container: (part.key as NSString).pathExtension,
                            videoCodec: version.videoCodec,
                            audioCodec: version.audioCodec,
                            dynamicRange: part.streams?.first(where: { $0.streamType == 1 })?.videoProfile,
                            resolution: version.videoResolution))
                }
            default:
                serverVersions = []
            }
        } catch {
            serverVersions = []
        }
    }

    private func features(for source: JellyfinItem.MediaSource) -> PlaybackMediaFeatures {
        let video = source.mediaStreams?.first { $0.type?.caseInsensitiveCompare("Video") == .orderedSame }
        let audio = source.mediaStreams?.first { $0.type?.caseInsensitiveCompare("Audio") == .orderedSame }
        let size: String?
        if let width = video?.width, let height = video?.height { size = "\(width)×\(height)" }
        else { size = nil }
        return PlaybackMediaFeatures(container: source.container, videoCodec: video?.codec,
                                     audioCodec: audio?.codec, dynamicRange: video?.videoRangeType,
                                     resolution: size)
    }

    private func selectVersion(_ version: ServerPlaybackVersion, item: MediaItem) {
        var selected = item
        if let partKey = version.plexPartKey,
           case .plexItem(let sourceID, let ratingKey, _) = item.location {
            selected.location = .plexItem(sourceID: sourceID, ratingKey: ratingKey, partKey: partKey)
        }
        selectedServerMediaSourceID = version.mediaSourceID
        selectedPlexPartID = version.plexPartID
        selectedPlexMediaIndex = version.plexMediaIndex ?? 0
        selectedAudioStreamIndex = nil
        selectedSubtitleStreamIndex = nil
        forceRemoteVersion = true
        selectedTranscodeBitrate = nil
        playingItem = selected
    }

    private func activeVersion(for item: MediaItem) -> ServerPlaybackVersion? {
        switch item.location {
        case .plexItem:
            return serverVersions.first(where: { $0.plexMediaIndex == selectedPlexMediaIndex })
                ?? serverVersions.first
        default:
            return serverVersions.first(where: { $0.mediaSourceID == selectedServerMediaSourceID })
                ?? serverVersions.first
        }
    }

    private func playbackTracks(for item: MediaItem) -> ServerPlaybackTracks {
        let version: ServerPlaybackVersion?
        if case .plexItem = item.location {
            version = serverVersions.first(where: { $0.plexMediaIndex == selectedPlexMediaIndex })
        } else {
            version = serverVersions.first(where: { $0.mediaSourceID == selectedServerMediaSourceID })
                ?? serverVersions.first
        }
        guard let version else { return .empty }
        if case .plexItem = item.location {
            return ServerPlaybackTracks(
                audio: version.plexStreams.filter { $0.streamType == 2 }.compactMap { stream in
                    stream.id.map { ServerPlaybackTrack(id: $0, title: stream.displayTitle ?? stream.language ?? "音轨 \($0)") }
                },
                subtitles: version.plexStreams.filter { $0.streamType == 3 }.compactMap { stream in
                    stream.id.map { ServerPlaybackTrack(id: $0, title: stream.displayTitle ?? stream.language ?? "字幕 \($0)") }
                })
        }
        return ServerPlaybackTracks(
            audio: version.streams.filter { $0.type == "Audio" }.compactMap { stream in
                stream.index.map { ServerPlaybackTrack(id: $0, title: stream.displayTitle ?? stream.language ?? "音轨 \($0)") }
            },
            subtitles: version.streams.filter { $0.type == "Subtitle" }.compactMap { stream in
                stream.index.map { ServerPlaybackTrack(id: $0, title: stream.displayTitle ?? stream.language ?? "字幕 \($0)") }
            })
    }

    private func playTranscoded(version: ServerPlaybackVersion, bitrate: Int, item: MediaItem) {
        selectedServerMediaSourceID = version.mediaSourceID
        selectedPlexPartID = version.plexPartID
        selectedPlexMediaIndex = version.plexMediaIndex ?? 0
        selectedAudioStreamIndex = nil
        selectedSubtitleStreamIndex = nil
        selectedTranscodeBitrate = bitrate
        forceRemoteVersion = true
        playingItem = item
    }

    private func searchOnlineSubtitles() {
        guard let item else { return }
        subtitleBusy = true
        subtitleStatus = nil
        Task {
            do {
                try KeychainPasswordStore.setOpenSubtitlesAPIKey(subtitleAPIKey)
                subtitleMatches = try await OpenSubtitlesClient.search(item: item,
                    language: subtitleLanguage.trimmingCharacters(in: .whitespacesAndNewlines),
                    apiKey: subtitleAPIKey)
                if subtitleMatches.isEmpty { subtitleStatus = "没有找到匹配字幕。" }
            } catch { subtitleStatus = error.localizedDescription }
            subtitleBusy = false
        }
    }

    private func downloadOnlineSubtitle(_ result: OpenSubtitlesClient.Result) {
        subtitleBusy = true
        subtitleStatus = nil
        Task {
            do {
                let (data, filename) = try await OpenSubtitlesClient.download(fileID: result.id,
                                                                                apiKey: subtitleAPIKey)
                library.installSubtitle(id: itemID, data: data, filename: filename)
                subtitleStatus = "已安装 \(result.language) 字幕。重新打开播放页后生效。"
            } catch { subtitleStatus = error.localizedDescription }
            subtitleBusy = false
        }
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).foregroundStyle(.secondary).frame(width: 80, alignment: .leading)
            Text(value)
        }
        .font(.subheadline)
    }

    private func sourceDescription(_ item: MediaItem) -> String {
        switch item.location {
        case .remote(let url): return url.host ?? url.absoluteString
        case .bookmark: return "本地文件"
        case .folderFile(let id, let path):
            let name = library.folders.first { $0.id == id }?.name ?? "文件夹"
            return "\(name) / \(path)"
        case .smbFile(let id, let path):
            let name = library.smbSources.first { $0.id == id }?.name ?? "SMB"
            return "\(name) / \(path)"
        case .webDAVFile(let id, let path):
            let name = library.webDAVSources.first { $0.id == id }?.name ?? "WebDAV"
            return "\(name) / \(path)"
        case .jellyfinItem(let id, _):
            let name = library.jellyfinSources.first { $0.id == id }?.name ?? "Jellyfin"
            return name
        case .embyItem(let id, _):
            let name = library.embySources.first { $0.id == id }?.name ?? "Emby"
            return name
        case .plexItem(let id, _, _):
            let name = library.plexSources.first { $0.id == id }?.name ?? "Plex"
            return name
        case .cloudFile(let id, _, let filename):
            let name = library.cloudSources.first { $0.id == id }?.name ?? "云盘"
            return "\(name) / \(filename)"
        }
    }

    private func canDownload(_ item: MediaItem) -> Bool {
        switch item.location {
        case .remote(let url): ["http", "https"].contains(url.scheme?.lowercased() ?? "")
        case .smbFile, .webDAVFile, .jellyfinItem, .embyItem, .plexItem, .cloudFile: true
        case .bookmark, .folderFile: false
        }
    }

    private func nextEpisode(after item: MediaItem) -> MediaItem? {
        guard case .some(.episode(let series, let season, let number, _)) = item.identity else { return nil }
        return library.visibleItems.filter { candidate in
            if case .some(.episode(let candidateSeries, let candidateSeason, let candidateNumber, _)) = candidate.identity {
                return candidateSeries == series &&
                    (candidateSeason > season || (candidateSeason == season && candidateNumber > number))
            }
            return false
        }.min { lhs, rhs in
            guard case .some(.episode(_, let leftSeason, let leftNumber, _)) = lhs.identity,
                  case .some(.episode(_, let rightSeason, let rightNumber, _)) = rhs.identity else { return false }
            return leftSeason == rightSeason ? leftNumber < rightNumber : leftSeason < rightSeason
        }
    }
}

struct LocalPosterView: View {
    let url: URL
    var body: some View {
        #if os(macOS)
        if let image = NSImage(contentsOf: url) {
            Image(nsImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "film")
        }
        #else
        if let image = UIImage(contentsOfFile: url.path) {
            Image(uiImage: image).resizable().scaledToFit()
        } else {
            Image(systemName: "film")
        }
        #endif
    }
}
