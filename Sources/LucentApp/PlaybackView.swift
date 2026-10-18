import AVKit
import Combine
import SwiftUI
import VLCKit

struct PlaybackChapter: Identifiable {
    let index: Int
    let title: String
    let start: Double
    var id: Int { index }
}

struct ServerPlaybackTrack: Identifiable {
    let id: Int
    let title: String
}

struct ServerPlaybackTracks {
    let audio: [ServerPlaybackTrack]
    let subtitles: [ServerPlaybackTrack]
    static let empty = ServerPlaybackTracks(audio: [], subtitles: [])
}

@MainActor
final class PlaybackSession: ObservableObject {
    @Published var message: String?
    @Published var playbackRate: Float = 1
    @Published var preferredPeakBitRate: Double = 0
    @Published var subtitleText = ""
    @Published var hasSidecarSubtitle = false
    @Published var subtitlesEnabled = true
    @Published var subtitleDelay: Double = 0
    @Published var audioOptions: [String] = []
    @Published var subtitleOptions: [String] = []
    @Published private(set) var dolbyVisionDetected = false
    @Published private(set) var playlistEntries: [PlaylistResolver.Entry] = []
    @Published private(set) var currentPlaylistIndex = 0
    @Published private(set) var segments: [PlaybackSegment] = []
    @Published var autoSkipSegments = UserDefaults.standard.object(forKey: "lucent.autoSkipSegments") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSkipSegments, forKey: "lucent.autoSkipSegments") }
    }
    @Published private(set) var chapters: [PlaybackChapter] = []
    @Published var didFinish = false
    @Published var isBuffering = false
    @Published var stallCount = 0
    @Published var useVLC = false
    @Published private(set) var discTitles: [String] = []
    @Published private(set) var isOpticalMedia = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    let player = AVPlayer()
    #if canImport(VLCKit)
    let vlcPlayer = VLCMediaPlayer(options: ["--keystore=memory", "--quiet"])
    private var vlcTimer: Timer?
    private var vlcResumePosition: Double = 0
    private var nativeSubtitleURL: URL?
    private var externalAudioURL: URL?
    private var externalAudioAttached = false
    private var nativeSubtitleAttached = false
    private var nativeSubtitleTrackIndex: Int?
    private var temporarySubtitleURL: URL?
    private var lastVLCPosition: Double = 0
    private var lastVLCProgressAt = Date()
    private var reportedVLCStall = false
    #endif
    private var timeObserver: Any?
    private var scopedURL: URL?
    private var smbServer: RangeHTTPServer?
    private var loadingTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var subtitleCues: [SubtitleCue] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var tracksTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var lastSkippedSegmentID: String?
    private var endObserver: NSObjectProtocol?
    private var playbackErrorObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var lastProgressSave = Date.distantPast
    private var resumeOverride: Double?
    private let item: MediaItem
    private let serverMediaSourceID: String?
    private let serverContainer: String?
    private let serverDolbyVision: Bool
    private let forceRemoteVersion: Bool
    private let transcodeBitrate: Int?
    private var audioStreamIndex: Int?
    private var subtitleStreamIndex: Int?
    private let plexPartID: Int?
    private let plexMediaIndex: Int
    let serverTracks: ServerPlaybackTracks
    private var plexTranscode: (address: String, token: String, sessionID: UUID)?
    private weak var library: LibraryStore?

    init(item: MediaItem, serverMediaSourceID: String? = nil,
         serverContainer: String? = nil, serverDolbyVision: Bool = false,
         forceRemoteVersion: Bool = false, transcodeBitrate: Int? = nil,
         audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
         plexPartID: Int? = nil, plexMediaIndex: Int = 0,
         serverTracks: ServerPlaybackTracks = .empty) {
        self.item = item
        self.serverMediaSourceID = serverMediaSourceID
        self.serverContainer = serverContainer
        self.serverDolbyVision = serverDolbyVision
        self.forceRemoteVersion = forceRemoteVersion
        self.transcodeBitrate = transcodeBitrate
        self.audioStreamIndex = audioStreamIndex
        self.subtitleStreamIndex = subtitleStreamIndex
        self.plexPartID = plexPartID
        self.plexMediaIndex = plexMediaIndex
        self.serverTracks = serverTracks
    }

    func start(library: LibraryStore) {
        guard timeObserver == nil, loadingTask == nil else { return }
        self.library = library
        loadSegments(library: library)
        if let customURL = library.subtitleURL(for: item),
           let data = try? Data(contentsOf: customURL) {
            if Self.usesNativeSubtitle(customURL.pathExtension) {
                nativeSubtitleURL = customURL
                hasSidecarSubtitle = true
            } else {
                subtitleCues = SubtitleParser.parse(data, fileExtension: customURL.pathExtension)
                hasSidecarSubtitle = !subtitleCues.isEmpty
            }
        }
        if !forceRemoteVersion, transcodeBitrate == nil,
           let downloaded = library.downloadedURL(for: item) {
            play(url: downloaded)
            return
        }
        if let transcodeBitrate {
            let url: URL?
            switch item.location {
            case .jellyfinItem(let sourceID, let itemID):
                guard let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                      let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID) else {
                    message = "Jellyfin 授权不可用。"; return
                }
                url = ServerTranscodeClient.jellyfin(baseAddress: source.baseAddress,
                    itemID: itemID, token: token, mediaSourceID: serverMediaSourceID,
                    bitrate: transcodeBitrate, audioIndex: audioStreamIndex,
                    subtitleIndex: subtitleStreamIndex)
            case .embyItem(let sourceID, let itemID):
                guard let source = library.embySources.first(where: { $0.id == sourceID }),
                      let token = try? KeychainPasswordStore.embyToken(for: sourceID) else {
                    message = "Emby 授权不可用。"; return
                }
                url = ServerTranscodeClient.emby(baseAddress: source.baseAddress,
                    itemID: itemID, token: token, mediaSourceID: serverMediaSourceID,
                    bitrate: transcodeBitrate, audioIndex: audioStreamIndex,
                    subtitleIndex: subtitleStreamIndex)
            case .plexItem(let sourceID, let ratingKey, _):
                guard let source = library.plexSources.first(where: { $0.id == sourceID }),
                      let token = try? KeychainPasswordStore.plexToken(for: sourceID) else {
                    message = "Plex 授权不可用。"; return
                }
                let sessionID = UUID()
                if let plexPartID, audioStreamIndex != nil || subtitleStreamIndex != nil {
                    loadingTask = Task { [weak self] in
                        do {
                            try await PlexClient.selectStreams(source: source, token: token,
                                partID: plexPartID, audioID: self?.audioStreamIndex,
                                subtitleID: self?.subtitleStreamIndex)
                            guard !Task.isCancelled else { return }
                            let stream = ServerTranscodeClient.plex(baseAddress: source.baseAddress,
                                ratingKey: ratingKey, token: token, bitrate: transcodeBitrate,
                                sessionID: sessionID, mediaIndex: self?.plexMediaIndex ?? 0)
                            guard let stream else { throw CocoaError(.fileReadUnknown) }
                            self?.plexTranscode = (source.baseAddress, token, sessionID)
                            self?.play(url: stream)
                        } catch { self?.message = "Plex 转码选轨失败：\(error.localizedDescription)" }
                        self?.loadingTask = nil
                    }
                    return
                }
                url = ServerTranscodeClient.plex(baseAddress: source.baseAddress,
                    ratingKey: ratingKey, token: token, bitrate: transcodeBitrate,
                    sessionID: sessionID, mediaIndex: plexMediaIndex)
                plexTranscode = (source.baseAddress, token, sessionID)
            default:
                url = nil
            }
            guard let url else { message = "无法创建转码播放地址。"; return }
            play(url: url)
            return
        }
        if case .smbFile(let sourceID, let path) = item.location {
            guard let source = library.smbSources.first(where: { $0.id == sourceID }) else {
                message = "SMB 片源已移除。"
                return
            }
            let password: String?
            do { password = try KeychainPasswordStore.get(for: sourceID) }
            catch { message = "无法读取 SMB 凭据：\(error.localizedDescription)"; return }
            let server = RangeHTTPServer(source: source, password: password, path: path)
            smbServer = server
            loadingTask = Task { [weak self] in
                do {
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self?.play(url: url)
                    self?.loadSMBSubtitle(source: source, password: password, path: path)
                } catch {
                    self?.message = "无法播放 SMB 视频：\(error.localizedDescription)"
                    server.stop()
                }
                self?.loadingTask = nil
            }
            return
        }
        if case .webDAVFile(let sourceID, let path) = item.location {
            guard let source = library.webDAVSources.first(where: { $0.id == sourceID }) else {
                message = "WebDAV 片源已移除。"
                return
            }
            let password: String?
            do { password = try KeychainPasswordStore.webDAVPassword(for: sourceID) }
            catch { message = "无法读取 WebDAV 凭据：\(error.localizedDescription)"; return }
            let server = RangeHTTPServer(fileExtension: (path as NSString).pathExtension) { offset, length in
                try WebDAVClient.readRange(source: source, password: password, path: path,
                                           offset: offset, length: length)
            }
            smbServer = server
            loadingTask = Task { [weak self] in
                do {
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self?.play(url: url)
                    self?.loadWebDAVSubtitle(source: source, password: password, path: path)
                } catch {
                    self?.message = "无法播放 WebDAV 视频：\(error.localizedDescription)"
                    server.stop()
                }
                self?.loadingTask = nil
            }
            return
        }
        if case .jellyfinItem(let sourceID, let itemID) = item.location {
            guard let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.jellyfinToken(for: sourceID), !token.isEmpty else {
                message = "Jellyfin 片源或令牌不可用。"
                return
            }
            let server = RangeHTTPServer(fileExtension: serverContainer ?? item.serverFileExtension ?? "mp4") { offset, length in
                try JellyfinClient.readRange(source: source, token: token, itemID: itemID,
                                             offset: offset, length: length,
                                             mediaSourceID: self.serverMediaSourceID)
            }
            smbServer = server
            loadingTask = Task { [weak self] in
                do {
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self?.play(url: url)
                } catch {
                    self?.message = "无法播放 Jellyfin 视频：\(error.localizedDescription)"
                    server.stop()
                }
                self?.loadingTask = nil
            }
            return
        }
        if case .embyItem(let sourceID, let itemID) = item.location {
            guard let source = library.embySources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.embyToken(for: sourceID), !token.isEmpty else {
                message = "Emby 片源或令牌不可用。"
                return
            }
            let server = RangeHTTPServer(fileExtension: serverContainer ?? item.serverFileExtension ?? "mp4") { offset, length in
                try EmbyClient.readRange(source: source, token: token, itemID: itemID,
                                         offset: offset, length: length,
                                         mediaSourceID: self.serverMediaSourceID)
            }
            smbServer = server
            loadingTask = Task { [weak self] in
                do {
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self?.play(url: url)
                } catch {
                    self?.message = "无法播放 Emby 视频：\(error.localizedDescription)"
                    server.stop()
                }
                self?.loadingTask = nil
            }
            return
        }
        if case .plexItem(let sourceID, _, let partKey) = item.location {
            guard let source = library.plexSources.first(where: { $0.id == sourceID }),
                  let token = try? KeychainPasswordStore.plexToken(for: sourceID), !token.isEmpty else {
                message = "Plex 片源或令牌不可用。"
                return
            }
            let server = RangeHTTPServer(fileExtension: (partKey as NSString).pathExtension) { offset, length in
                try PlexClient.readRange(source: source, token: token, partKey: partKey,
                                         offset: offset, length: length)
            }
            smbServer = server
            loadingTask = Task { [weak self] in
                do {
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self?.play(url: url)
                } catch {
                    self?.message = "无法播放 Plex 视频：\(error.localizedDescription)"
                    server.stop()
                }
                self?.loadingTask = nil
            }
            return
        }
        if case .cloudFile(let sourceID, let identifier, let filename) = item.location {
            guard let source = library.cloudSources.first(where: { $0.id == sourceID }) else {
                message = "云盘片源已移除。"; return
            }
            loadingTask = Task { [weak self] in
                defer { self?.loadingTask = nil }
                do {
                    _ = try await library.validCloudToken(source: source)
                    let server = RangeHTTPServer(fileExtension: (filename as NSString).pathExtension,
                                                 asyncReadRange: { offset, length in
                        let token = try await library.validCloudToken(source: source)
                        return try await CloudDriveClient.readRangeAsync(
                            source: source, token: token, identifier: identifier,
                            offset: offset, length: length)
                    })
                    self?.smbServer = server
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self?.play(url: url)
                } catch {
                    self?.message = "无法播放云盘视频：\(error.localizedDescription)"
                    self?.smbServer?.stop()
                }
            }
            return
        }
        do {
            let url = try resolve(item.location)
            if case .remote = item.location { } else { loadLocalSubtitle(videoURL: url) }
            let extensionName = url.pathExtension.lowercased()
            if ["strm", "m3u"].contains(extensionName) ||
                (extensionName == "m3u8" && url.isFileURL) {
                let playlistURL = url
                loadingTask = Task { [weak self] in
                    do {
                        let entries: [PlaylistResolver.Entry]
                        if playlistURL.isFileURL {
                            entries = try PlaylistResolver.entries(in: playlistURL)
                        } else {
                            entries = try await PlaylistResolver.entries(at: playlistURL)
                        }
                        guard !Task.isCancelled else { return }
                        self?.playlistEntries = entries
                        self?.currentPlaylistIndex = 0
                        if let target = entries.first?.url { self?.play(url: target) }
                    } catch { self?.message = "播放列表无法打开：\(error.localizedDescription)" }
                    self?.loadingTask = nil
                }
            } else {
                play(url: url)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func play(url: URL) {
        prepareForReplacement()
        dolbyVisionDetected = false
        let preferNativeDolbyVision = serverDolbyVision &&
            DolbyVisionSupport.isApplePlaybackContainer(url.pathExtension)
        if preferNativeDolbyVision, let subtitleURL = nativeSubtitleURL,
           ["ass", "ssa"].contains(subtitleURL.pathExtension.lowercased()),
           let data = try? Data(contentsOf: subtitleURL) {
            subtitleCues = SubtitleParser.parse(data, fileExtension: subtitleURL.pathExtension)
            nativeSubtitleURL = nil
        }
        isOpticalMedia = ["VIDEO_TS", "BDMV"].contains(url.lastPathComponent.uppercased())
            || url.pathExtension.lowercased() == "iso"
        if Self.needsVLC(url) || nativeSubtitleURL != nil || externalAudioURL != nil {
            #if canImport(VLCKit)
            playWithVLC(url: url)
            #else
            message = "当前版本缺少 MKV 等格式所需的播放内核。"
            #endif
            return
        }
        player.allowsExternalPlayback = true
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredPeakBitRate = preferredPeakBitRate
        player.replaceCurrentItem(with: playerItem)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finishCurrentPlayback() }
        }
        playbackErrorObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: playerItem, queue: .main
        ) { [weak self] notification in
            let detail = (notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?
                .localizedDescription ?? "服务器未能提供所选画质。"
            Task { @MainActor [weak self] in self?.message = "播放失败：\(detail)" }
        }
        stallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: playerItem, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stallCount += 1
                self?.isBuffering = true
            }
        }
        let resume = resumeOverride ?? (item.watched ? 0 : item.position)
        resumeOverride = nil
        if resume > 0 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in self?.tick(time.seconds) }
        }
        player.play()
        tracksTask = Task { [weak self] in
            do {
                self?.dolbyVisionDetected = await DolbyVisionSupport.assetHasDolbyVision(playerItem.asset)
                let audio = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled else { return }
                self?.audioGroup = audio
                self?.subtitleGroup = subtitles
                self?.audioOptions = audio?.options.map(\.displayName) ?? []
                self?.subtitleOptions = subtitles?.options.map(\.displayName) ?? []
                let groups = try await playerItem.asset.loadChapterMetadataGroups(
                    bestMatchingPreferredLanguages: Locale.preferredLanguages)
                var loadedChapters: [PlaybackChapter] = []
                for (index, group) in groups.enumerated() {
                    let title = try await group.items.first?.load(.stringValue) ?? "章节 \(index + 1)"
                    loadedChapters.append(PlaybackChapter(index: index, title: title,
                                                          start: group.timeRange.start.seconds))
                }
                self?.chapters = loadedChapters
                if self?.segments.isEmpty == true {
                    let assetDuration = try await playerItem.asset.load(.duration).seconds
                    self?.segments = PlaybackSegmentClient.fromChapters(
                        loadedChapters, duration: assetDuration.isFinite ? assetDuration : 0)
                }
            } catch {
                // A media file may have no selectable tracks.
            }
        }
    }

    func selectPlaylistEntry(_ entry: PlaylistResolver.Entry) {
        currentPlaylistIndex = entry.index
        segments = []
        lastSkippedSegmentID = nil
        resumeOverride = 0
        play(url: entry.url)
    }

    private func finishCurrentPlayback() {
        let next = currentPlaylistIndex + 1
        if playlistEntries.indices.contains(next) {
            selectPlaylistEntry(playlistEntries[next])
        } else {
            didFinish = true
        }
    }

    private func loadSegments(library: LibraryStore) {
        segmentTask?.cancel()
        segmentTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded: [PlaybackSegment]
                switch item.location {
                case .jellyfinItem(let sourceID, let itemID):
                    guard let source = library.jellyfinSources.first(where: { $0.id == sourceID }),
                          let token = try KeychainPasswordStore.jellyfinToken(for: sourceID) else { return }
                    loaded = try await PlaybackSegmentClient.jellyfin(
                        baseAddress: source.baseAddress, itemID: itemID, token: token)
                case .plexItem(let sourceID, let ratingKey, _):
                    guard let source = library.plexSources.first(where: { $0.id == sourceID }),
                          let token = try KeychainPasswordStore.plexToken(for: sourceID) else { return }
                    loaded = try await PlaybackSegmentClient.plex(
                        baseAddress: source.baseAddress, ratingKey: ratingKey, token: token)
                case .embyItem(let sourceID, let itemID):
                    guard let source = library.embySources.first(where: { $0.id == sourceID }),
                          let token = try KeychainPasswordStore.embyToken(for: sourceID) else { return }
                    loaded = try await PlaybackSegmentClient.emby(baseAddress: source.baseAddress,
                        itemID: itemID, token: token, duration: item.duration)
                default: return
                }
                guard !Task.isCancelled else { return }
                if !loaded.isEmpty { segments = loaded }
            } catch {
                // Older servers may not expose segment markers; chapter detection remains available.
            }
        }
    }

    private func applyAutomaticSkip(at seconds: Double) {
        guard autoSkipSegments,
              let segment = segments.first(where: { $0.start <= seconds && seconds < $0.end }),
              segment.id != lastSkippedSegmentID else { return }
        lastSkippedSegmentID = segment.id
        seek(to: segment.end)
    }

    func switchServerAudio(_ index: Int) {
        guard transcodeBitrate != nil else { return }
        audioStreamIndex = index
        restartTranscode()
    }

    func switchServerSubtitle(_ index: Int) {
        guard transcodeBitrate != nil else { return }
        subtitleStreamIndex = index
        restartTranscode()
    }

    private func restartTranscode() {
        guard let library else { return }
        let position = currentTime
        close()
        resumeOverride = position
        didFinish = false
        start(library: library)
    }

    private func prepareForReplacement() {
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        if let playbackErrorObserver {
            NotificationCenter.default.removeObserver(playbackErrorObserver)
            self.playbackErrorObserver = nil
        }
        if let stallObserver { NotificationCenter.default.removeObserver(stallObserver); self.stallObserver = nil }
        tracksTask?.cancel()
        tracksTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        #if canImport(VLCKit)
        vlcTimer?.invalidate()
        vlcTimer = nil
        if useVLC { vlcPlayer.stop(); vlcPlayer.media = nil }
        useVLC = false
        #endif
        chapters = []
        discTitles = []
        audioOptions = []
        subtitleOptions = []
        didFinish = false
    }

    private static func needsVLC(_ url: URL) -> Bool {
        if ["VIDEO_TS", "BDMV"].contains(url.lastPathComponent.uppercased()) { return true }
        if url.isFileURL, url.pathExtension.lowercased() == "m3u8" { return true }
        if ["ftp", "ftps", "sftp", "nfs"].contains(url.scheme?.lowercased() ?? "") { return true }
        return ["mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "vob", "mpg", "mpeg", "ogv", "iso"]
            .contains(url.pathExtension.lowercased())
    }

    private static func usesNativeSubtitle(_ fileExtension: String) -> Bool {
        ["ass", "ssa", "sup"].contains(fileExtension.lowercased())
    }

    #if canImport(VLCKit)
    private func playWithVLC(url: URL) {
        let media: VLCMedia?
        if let smbServer, smbServer.supportsSynchronousInputStream {
            media = VLCMedia(stream: smbServer.makeInputStream())
        } else {
            var playbackURL = url
            let directory = url.lastPathComponent.uppercased()
            if url.isFileURL, directory == "VIDEO_TS" || directory == "BDMV" {
                let root = url.deletingLastPathComponent().path
                let encoded = root.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? root
                playbackURL = URL(string: "\(directory == "VIDEO_TS" ? "dvd" : "bluray")://\(encoded)") ?? url
            }
            if let source = library?.vlcNetworkSources.first(where: { $0.mediaIDs.contains(item.id) }) {
                let password = try? KeychainPasswordStore.vlcNetworkPassword(for: source.id)
                playbackURL = VLCNetworkBrowser.authenticated(url, username: source.username,
                                                              password: password)
            }
            media = VLCMedia(url: playbackURL)
        }
        guard let media else {
            message = "无法打开视频文件。"
            return
        }
        vlcResumePosition = resumeOverride ?? (item.watched ? 0 : item.position)
        resumeOverride = nil
        vlcPlayer.media = media
        useVLC = true
        vlcTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickVLC() }
        }
    }

    private func tickVLC() {
        if vlcPlayer.state == .error {
            message = "VLC 播放失败，请检查文件和网络连接。"
            return
        }
        if vlcPlayer.state == .stopped, !didFinish, vlcPlayer.time.intValue > 0 {
            finishCurrentPlayback()
            return
        }
        let seconds = Double(vlcPlayer.time.intValue) / 1000
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        if vlcPlayer.isPlaying {
            if abs(seconds - lastVLCPosition) >= 0.2 {
                lastVLCPosition = seconds
                lastVLCProgressAt = Date()
                reportedVLCStall = false
                isBuffering = false
            } else if Date().timeIntervalSince(lastVLCProgressAt) > 2 {
                isBuffering = true
                if !reportedVLCStall {
                    stallCount += 1
                    reportedVLCStall = true
                }
            }
        } else if vlcPlayer.state == .opening {
            isBuffering = true
        } else if vlcPlayer.state == .paused {
            isBuffering = false
            lastVLCProgressAt = Date()
        }
        let mediaDuration = Double(vlcPlayer.media?.length.intValue ?? 0) / 1000
        if mediaDuration.isFinite, mediaDuration > 0 { duration = mediaDuration }
        if vlcResumePosition > 0, vlcPlayer.isPlaying {
            vlcPlayer.time = VLCTime(int: Int32(min(vlcResumePosition * 1000, Double(Int32.max))))
            vlcResumePosition = 0
        }
        if !nativeSubtitleAttached, vlcPlayer.isPlaying, let nativeSubtitleURL {
            let result = vlcPlayer.addPlaybackSlave(nativeSubtitleURL, type: .subtitle, enforce: true)
            if result == 0 {
                nativeSubtitleAttached = true
                nativeSubtitleTrackIndex = max(0, vlcPlayer.textTracks.count - 1)
                vlcPlayer.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000)
            } else if nativeSubtitleURL.pathExtension.lowercased() != "sup",
                      let data = try? Data(contentsOf: nativeSubtitleURL) {
                subtitleCues = SubtitleParser.parse(data, fileExtension: nativeSubtitleURL.pathExtension)
                self.nativeSubtitleURL = nil
            } else {
                message = "无法载入 PGS 字幕。"
                self.nativeSubtitleURL = nil
            }
        }
        if !externalAudioAttached, vlcPlayer.isPlaying, let externalAudioURL {
            if vlcPlayer.addPlaybackSlave(externalAudioURL, type: .audio, enforce: true) == 0 {
                externalAudioAttached = true
            } else {
                message = "无法载入外挂音轨。"
                self.externalAudioURL = nil
            }
        }
        let subtitleTime = seconds - subtitleDelay
        subtitleText = subtitlesEnabled
            ? (subtitleCues.first { $0.start <= subtitleTime && subtitleTime < $0.end }?.text ?? "")
            : ""
        if Date().timeIntervalSince(lastProgressSave) >= 5 {
            library?.updateProgress(id: item.id, position: seconds,
                                    duration: Double(vlcPlayer.media?.length.intValue ?? 0) / 1000)
            lastProgressSave = Date()
        }
        let availableAudio = vlcPlayer.audioTracks.map(\.trackName)
        let availableSubtitles = vlcPlayer.textTracks.map(\.trackName)
        if audioOptions != availableAudio { audioOptions = availableAudio }
        if subtitleOptions != availableSubtitles { subtitleOptions = availableSubtitles }
        if chapters.isEmpty, vlcPlayer.currentTitleIndex >= 0 {
            chapters = vlcPlayer.chapterDescriptions(ofTitle: vlcPlayer.currentTitleIndex).enumerated().map {
                index, chapter in
                PlaybackChapter(index: index, title: chapter.name ?? "章节 \(index + 1)",
                                start: Double(chapter.timeOffset.intValue) / 1000)
            }
            if segments.isEmpty {
                segments = PlaybackSegmentClient.fromChapters(chapters, duration: duration)
            }
        }
        let titles = vlcPlayer.titleDescriptions.enumerated().map { index, title in
            title.name ?? (title.isMenu ? "菜单 \(index + 1)" : "标题 \(index + 1)")
        }
        if titles != discTitles { discTitles = titles }
        applyAutomaticSkip(at: seconds)
    }
    #endif

    func selectChapter(_ chapter: PlaybackChapter) {
        #if canImport(VLCKit)
        if useVLC { vlcPlayer.currentChapterIndex = Int32(chapter.index) }
        else { player.seek(to: CMTime(seconds: chapter.start, preferredTimescale: 600)) }
        #else
        player.seek(to: CMTime(seconds: chapter.start, preferredTimescale: 600))
        #endif
    }

    func selectDiscTitle(_ index: Int) {
        #if canImport(VLCKit)
        guard useVLC, vlcPlayer.titleDescriptions.indices.contains(index) else { return }
        vlcPlayer.currentTitleIndex = vlcPlayer.titleDescriptions[index].titleIndex
        chapters = []
        if isOpticalMedia { segments = []; lastSkippedSegmentID = nil }
        #endif
    }

    func navigateDisc(_ action: VLCMediaPlaybackNavigationAction) {
        #if canImport(VLCKit)
        guard useVLC else { return }
        vlcPlayer.perform(action)
        #endif
    }

    func setAspectRatio(_ ratio: String?) {
        #if canImport(VLCKit)
        guard useVLC else { return }
        vlcPlayer.videoAspectRatio = ratio
        #endif
    }

    #if !os(tvOS)
    func selectRenderer(_ renderer: VLCRendererItem?) {
        #if canImport(VLCKit)
        guard useVLC else { return }
        if !vlcPlayer.setRendererItem(renderer) {
            message = "无法连接投屏设备。"
        }
        #endif
    }
    #endif

    func skip(by seconds: Double) {
        #if canImport(VLCKit)
        if useVLC {
            let current = Double(vlcPlayer.time.intValue) / 1000
            let target = max(0, current + seconds)
            vlcPlayer.time = VLCTime(int: Int32(min(target * 1000, Double(Int32.max))))
            return
        }
        #endif
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let duration = player.currentItem?.duration.seconds
        let target = max(0, current + seconds)
        let clamped = duration.flatMap { $0.isFinite && $0 > 0 ? min(target, $0) : nil } ?? target
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        #if canImport(VLCKit)
        if useVLC {
            vlcPlayer.time = VLCTime(int: Int32(min(target * 1000, Double(Int32.max))))
            currentTime = target
            return
        }
        #endif
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        #if canImport(VLCKit)
        if useVLC { vlcPlayer.rate = rate }
        else { player.rate = rate }
        #else
        player.rate = rate
        #endif
    }

    func setPreferredPeakBitRate(_ bitsPerSecond: Double) {
        preferredPeakBitRate = max(0, bitsPerSecond)
        player.currentItem?.preferredPeakBitRate = preferredPeakBitRate
    }

    func togglePlayback() {
        #if canImport(VLCKit)
        if useVLC {
            if vlcPlayer.isPlaying { vlcPlayer.pause() }
            else { vlcPlayer.play() }
            return
        }
        #endif
        if player.rate > 0 {
            player.pause()
        } else {
            player.play()
            if playbackRate != 1 { player.rate = playbackRate }
        }
    }

    func close() {
        #if canImport(VLCKit)
        vlcTimer?.invalidate()
        vlcTimer = nil
        #endif
        loadingTask?.cancel()
        loadingTask = nil
        subtitleTask?.cancel()
        subtitleTask = nil
        tracksTask?.cancel()
        tracksTask = nil
        segmentTask?.cancel()
        segmentTask = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let playbackErrorObserver {
            NotificationCenter.default.removeObserver(playbackErrorObserver)
            self.playbackErrorObserver = nil
        }
        if let stallObserver {
            NotificationCenter.default.removeObserver(stallObserver)
            self.stallObserver = nil
        }
        #if canImport(VLCKit)
        let seconds = useVLC ? Double(vlcPlayer.time.intValue) / 1000 : player.currentTime().seconds
        let duration = useVLC ? Double(vlcPlayer.media?.length.intValue ?? 0) / 1000 : player.currentItem?.duration.seconds
        let hasItem = useVLC || player.currentItem != nil
        #else
        let seconds = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds
        let hasItem = player.currentItem != nil
        #endif
        if hasItem, seconds.isFinite, seconds >= 0 {
            library?.finishPlayback(id: item.id, position: seconds, duration: duration)
        }
        #if canImport(VLCKit)
        if useVLC { vlcPlayer.stop(); vlcPlayer.drawable = nil; vlcPlayer.media = nil }
        #endif
        player.pause()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        player.replaceCurrentItem(with: nil)
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
        smbServer?.stop()
        smbServer = nil
        if let plexTranscode {
            Task {
                await ServerTranscodeClient.stopPlex(baseAddress: plexTranscode.address,
                    token: plexTranscode.token, sessionID: plexTranscode.sessionID)
            }
            self.plexTranscode = nil
        }
        if let temporarySubtitleURL { try? FileManager.default.removeItem(at: temporarySubtitleURL) }
        temporarySubtitleURL = nil
    }

    private func tick(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        applyAutomaticSkip(at: seconds)
        if let value = player.currentItem?.duration.seconds, value.isFinite, value > 0 { duration = value }
        if player.timeControlStatus == .playing { isBuffering = false }
        else if player.timeControlStatus == .waitingToPlayAtSpecifiedRate { isBuffering = true }
        let subtitleTime = seconds - subtitleDelay
        subtitleText = subtitlesEnabled
            ? (subtitleCues.first { $0.start <= subtitleTime && subtitleTime < $0.end }?.text ?? "")
            : ""
        if Date().timeIntervalSince(lastProgressSave) >= 5 {
            record(seconds)
            lastProgressSave = Date()
        }
    }

    func toggleSidecarSubtitle() {
        subtitlesEnabled.toggle()
        if !subtitlesEnabled { subtitleText = "" }
        #if canImport(VLCKit)
        if useVLC, nativeSubtitleAttached {
            if subtitlesEnabled, let nativeSubtitleTrackIndex {
                vlcPlayer.selectTrack(at: nativeSubtitleTrackIndex, type: .text)
            } else {
                vlcPlayer.deselectAllTextTracks()
            }
        }
        #endif
    }

    func adjustSubtitleDelay(by change: Double) {
        subtitleDelay = min(10, max(-10, subtitleDelay + change))
        #if canImport(VLCKit)
        if useVLC, nativeSubtitleAttached {
            vlcPlayer.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000)
        }
        #endif
    }

    func selectAudio(_ index: Int) {
        #if canImport(VLCKit)
        if useVLC {
            vlcPlayer.selectTrack(at: index, type: .audio)
            return
        }
        #endif
        guard let group = audioGroup, group.options.indices.contains(index) else { return }
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.currentItem?.select(group.options[index], in: group)
    }

    func selectEmbeddedSubtitle(_ index: Int?) {
        #if canImport(VLCKit)
        if useVLC {
            if let index { vlcPlayer.selectTrack(at: index, type: .text) }
            else { vlcPlayer.deselectAllTextTracks() }
            return
        }
        #endif
        guard let group = subtitleGroup else { return }
        player.appliesMediaSelectionCriteriaAutomatically = false
        let option = index.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
        player.currentItem?.select(option, in: group)
    }

    private func loadLocalSubtitle(videoURL: URL) {
        for ext in ["m4a", "aac", "mp3", "flac", "ac3", "dts", "wav"] {
            let url = videoURL.deletingPathExtension().appendingPathExtension(ext)
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                externalAudioURL = url
                break
            }
        }
        guard !hasSidecarSubtitle else { return }
        for ext in ["srt", "vtt", "ass", "ssa", "sup"] {
            let url = videoURL.deletingPathExtension().appendingPathExtension(ext)
            guard (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map({ $0 <= 5_000_000 }) == true else { continue }
            if Self.usesNativeSubtitle(ext) {
                nativeSubtitleURL = url
                hasSidecarSubtitle = true
                return
            }
            guard let data = try? Data(contentsOf: url) else { continue }
            let cues = SubtitleParser.parse(data, fileExtension: ext)
            if !cues.isEmpty {
                subtitleCues = cues
                hasSidecarSubtitle = true
                return
            }
        }
    }

    private func loadSMBSubtitle(source: SMBSource, password: String?, path: String) {
        guard !hasSidecarSubtitle else { return }
        subtitleTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Data, String)? in
                for ext in ["srt", "vtt", "ass", "ssa", "sup"] {
                    let subtitlePath = (path as NSString).deletingPathExtension + "." + ext
                    if let data = try? SubtitleRangeLoader.read(range: { offset, length in
                        try SMBScanner.readRange(source: source, password: password,
                                                 path: subtitlePath, offset: offset, length: length)
                    }) {
                        return (data, ext)
                    }
                }
                return nil
            }.value
            guard !Task.isCancelled, let result else { return }
            self?.useSubtitleData(result.0, fileExtension: result.1)
        }
    }

    private func loadWebDAVSubtitle(source: WebDAVSource, password: String?, path: String) {
        guard !hasSidecarSubtitle else { return }
        subtitleTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (Data, String)? in
                for ext in ["srt", "vtt", "ass", "ssa", "sup"] {
                    let subtitlePath = (path as NSString).deletingPathExtension + "." + ext
                    if let data = try? SubtitleRangeLoader.read(range: { offset, length in
                        try WebDAVClient.readRange(source: source, password: password,
                                                   path: subtitlePath, offset: offset, length: length)
                    }) {
                        return (data, ext)
                    }
                }
                return nil
            }.value
            guard !Task.isCancelled, let result else { return }
            self?.useSubtitleData(result.0, fileExtension: result.1)
        }
    }

    private func useSubtitleData(_ data: Data, fileExtension: String) {
        if useVLC, Self.usesNativeSubtitle(fileExtension) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LucentSubtitle-\(UUID().uuidString).\(fileExtension)")
            do {
                try data.write(to: url, options: .atomic)
                temporarySubtitleURL = url
                nativeSubtitleURL = url
                hasSidecarSubtitle = true
            } catch { message = "无法准备外挂字幕：\(error.localizedDescription)" }
        } else {
            subtitleCues = SubtitleParser.parse(data, fileExtension: fileExtension)
            hasSidecarSubtitle = !subtitleCues.isEmpty
        }
    }

    private func record(_ seconds: Double) {
        if let failure = player.currentItem?.error {
            message = "播放失败：\(failure.localizedDescription)"
        }
        guard seconds.isFinite, seconds >= 0 else { return }
        let duration = player.currentItem?.duration.seconds
        library?.updateProgress(id: item.id, position: seconds, duration: duration)
    }

    private func resolve(_ location: MediaLocation) throws -> URL {
        switch location {
        case .remote(let url): return url
        case .smbFile:
            throw PlaybackError.fileUnavailable
        case .webDAVFile:
            throw PlaybackError.fileUnavailable
        case .jellyfinItem:
            throw PlaybackError.fileUnavailable
        case .embyItem:
            throw PlaybackError.fileUnavailable
        case .plexItem:
            throw PlaybackError.fileUnavailable
        case .cloudFile:
            throw PlaybackError.fileUnavailable
        case .bookmark(let data):
            #if os(tvOS)
            throw PlaybackError.fileUnavailable
            #else
            var stale = false
            #if os(macOS)
            let url: URL
            if let scoped = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                     relativeTo: nil, bookmarkDataIsStale: &stale) {
                url = scoped
            } else {
                url = try URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            }
            #else
            let url = try URL(resolvingBookmarkData: data, options: [],
                              relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            let uploadRoot = library?.uploadDirectory.standardizedFileURL.path ?? ""
            if !stale, !uploadRoot.isEmpty,
               url.standardizedFileURL.path.hasPrefix(uploadRoot + "/"),
               FileManager.default.fileExists(atPath: url.path) {
                return url
            }
            guard !stale, url.startAccessingSecurityScopedResource() else {
                throw PlaybackError.fileUnavailable
            }
            scopedURL = url
            return url
            #endif
        case .folderFile(let sourceID, let relativePath):
            #if os(tvOS)
            throw PlaybackError.fileUnavailable
            #else
            guard let source = library?.folders.first(where: { $0.id == sourceID }),
                  !relativePath.isEmpty,
                  !relativePath.split(separator: "/").contains("..") else {
                throw PlaybackError.fileUnavailable
            }
            var stale = false
            #if os(macOS)
            let root = try URL(resolvingBookmarkData: source.bookmark, options: .withSecurityScope,
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            #else
            let root = try URL(resolvingBookmarkData: source.bookmark, options: [],
                               relativeTo: nil, bookmarkDataIsStale: &stale)
            #endif
            guard !stale, root.startAccessingSecurityScopedResource() else {
                throw PlaybackError.fileUnavailable
            }
            scopedURL = root
            let file = root.appendingPathComponent(relativePath).standardizedFileURL
            guard file.path.hasPrefix(root.standardizedFileURL.path + "/") else {
                throw PlaybackError.fileUnavailable
            }
            return file
            #endif
        }
    }
}

private enum PlaybackError: LocalizedError {
    case fileUnavailable
    var errorDescription: String? {
        switch self {
        case .fileUnavailable: "原文件无法访问，请从媒体库移除后重新添加。"
        }
    }
}

struct PlaybackView: View {
    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lucent.subtitleFontScale") private var subtitleFontScale = 1.0
    @AppStorage("lucent.subtitleBackgroundOpacity") private var subtitleBackgroundOpacity = 0.6
    @StateObject private var session: PlaybackSession
    @StateObject private var castDiscovery = CastDiscovery()
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    private let item: MediaItem
    private let nextItem: MediaItem?
    private let onContinue: (() -> Void)?
    private let transcodeBitrate: Int?

    init(item: MediaItem, nextItem: MediaItem? = nil,
         serverMediaSourceID: String? = nil, serverContainer: String? = nil,
         serverDolbyVision: Bool = false,
         forceRemoteVersion: Bool = false,
         transcodeBitrate: Int? = nil,
         audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
         plexPartID: Int? = nil, plexMediaIndex: Int = 0,
         serverTracks: ServerPlaybackTracks = .empty,
         onContinue: (() -> Void)? = nil) {
        self.item = item
        self.nextItem = nextItem
        self.onContinue = onContinue
        self.transcodeBitrate = transcodeBitrate
        _session = StateObject(wrappedValue: PlaybackSession(
            item: item, serverMediaSourceID: serverMediaSourceID,
            serverContainer: serverContainer, serverDolbyVision: serverDolbyVision,
            forceRemoteVersion: forceRemoteVersion, transcodeBitrate: transcodeBitrate,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex,
            plexPartID: plexPartID, plexMediaIndex: plexMediaIndex, serverTracks: serverTracks))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("关闭", systemImage: "xmark") { dismiss() }
                Text(item.title).font(.headline).lineLimit(1)
                if session.dolbyVisionDetected {
                    Text("Dolby Vision").font(.caption.weight(.bold))
                        .foregroundStyle(.yellow)
                }
                Spacer()
            }
            .padding()
            ZStack(alignment: .bottom) {
                #if canImport(VLCKit)
                if session.useVLC {
                    VLCPlayerSurface(player: session.vlcPlayer)
                } else {
                    PlayerSurface(player: session.player)
                }
                #else
                PlayerSurface(player: session.player)
                #endif
                if !session.subtitleText.isEmpty {
                    Text(session.subtitleText)
                        .font(.system(size: 22 * subtitleFontScale, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 5)
                        .padding(12)
                        .background(.black.opacity(subtitleBackgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 48)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            if session.useVLC {
                HStack(spacing: 12) {
                    Text(Self.timeLabel(isSeeking ? seekPosition : session.currentTime))
                        .monospacedDigit()
                    #if os(tvOS)
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.white.opacity(0.3))
                            Capsule().fill(.white)
                                .frame(width: geometry.size.width * min(1, session.currentTime / max(1, session.duration)))
                        }
                    }
                    .frame(height: 8)
                    #else
                    Slider(value: Binding(
                        get: { isSeeking ? seekPosition : session.currentTime },
                        set: { seekPosition = $0 }),
                        in: 0...max(1, session.duration),
                        onEditingChanged: { editing in
                            if editing {
                                seekPosition = session.currentTime
                                isSeeking = true
                            } else {
                                session.seek(to: seekPosition)
                                isSeeking = false
                            }
                        }
                    )
                    .accessibilityLabel("播放进度")
                    #endif
                    Text(Self.timeLabel(session.duration))
                        .monospacedDigit()
                }
                .font(.caption)
                .padding(.horizontal)
            }
            HStack(spacing: 24) {
                if session.useVLC {
                    Button("播放或暂停", systemImage: "playpause.fill") { session.togglePlayback() }
                }
                Button("后退 10 秒", systemImage: "gobackward.10") { session.skip(by: -10) }
                Spacer()
                Menu {
                    ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button("\(rate.formatted())×") { session.setPlaybackRate(Float(rate)) }
                    }
                } label: {
                    Text("\(Double(session.playbackRate).formatted())×")
                }
                if !session.useVLC {
                    Menu("播放画质") {
                        Button("自动") { session.setPreferredPeakBitRate(0) }
                        ForEach([20, 10, 5, 2], id: \.self) { megabits in
                            Button("最高 \(megabits) Mbps") {
                                session.setPreferredPeakBitRate(Double(megabits) * 1_000_000)
                            }
                        }
                    }
                }
                #if os(iOS)
                AudioRoutePicker()
                    .frame(width: 36, height: 36)
                    .accessibilityLabel("音频输出设备")
                #endif
                #if os(tvOS)
                if session.useVLC, session.duration > 0 {
                    Menu("跳转") {
                        ForEach([0.1, 0.25, 0.5, 0.75, 0.9], id: \.self) { fraction in
                            Button("\(Int(fraction * 100))% · \(Self.timeLabel(session.duration * fraction))") {
                                session.seek(to: session.duration * fraction)
                            }
                        }
                    }
                }
                #endif
                if session.hasSidecarSubtitle {
                    Button(session.subtitlesEnabled ? "关闭外挂字幕" : "开启外挂字幕",
                           systemImage: "captions.bubble") { session.toggleSidecarSubtitle() }
                    Menu("字幕延迟 \(session.subtitleDelay.formatted(.number.precision(.fractionLength(1)))) 秒") {
                        Button("提前 0.5 秒") { session.adjustSubtitleDelay(by: -0.5) }
                        Button("延后 0.5 秒") { session.adjustSubtitleDelay(by: 0.5) }
                        Button("重置") { session.subtitleDelay = 0 }
                    }
                    Menu("字幕样式") {
                        ForEach([0.8, 1.0, 1.2, 1.5], id: \.self) { scale in
                            Button("字号 \(Int(scale * 100))%") { subtitleFontScale = scale }
                        }
                        Divider()
                        Button("透明底色") { subtitleBackgroundOpacity = 0 }
                        Button("半透明底色") { subtitleBackgroundOpacity = 0.6 }
                        Button("深色底色") { subtitleBackgroundOpacity = 0.85 }
                    }
                }
                if !session.audioOptions.isEmpty {
                    Menu("音轨") {
                        ForEach(session.audioOptions.indices, id: \.self) { index in
                            Button(session.audioOptions[index]) { session.selectAudio(index) }
                        }
                    }
                }
                if transcodeBitrate != nil, !session.serverTracks.audio.isEmpty {
                    Menu("转码音轨") {
                        ForEach(session.serverTracks.audio) { track in
                            Button(track.title) { session.switchServerAudio(track.id) }
                        }
                    }
                }
                if transcodeBitrate != nil, !session.serverTracks.subtitles.isEmpty {
                    Menu("转码字幕") {
                        Button("关闭") { session.switchServerSubtitle(0) }
                        ForEach(session.serverTracks.subtitles) { track in
                            Button(track.title) { session.switchServerSubtitle(track.id) }
                        }
                    }
                }
                if !session.subtitleOptions.isEmpty {
                    Menu("内嵌字幕") {
                        Button("关闭") { session.selectEmbeddedSubtitle(nil) }
                        ForEach(session.subtitleOptions.indices, id: \.self) { index in
                            Button(session.subtitleOptions[index]) { session.selectEmbeddedSubtitle(index) }
                        }
                    }
                }
                if !session.chapters.isEmpty {
                    Menu("章节") {
                        ForEach(session.chapters) { chapter in
                            Button(chapter.title) { session.selectChapter(chapter) }
                        }
                    }
                }
                if session.useVLC {
                    Menu("画面比例") {
                        Button("原始比例") { session.setAspectRatio(nil) }
                        Button("16:9") { session.setAspectRatio("16:9") }
                        Button("4:3") { session.setAspectRatio("4:3") }
                        Button("2.35:1") { session.setAspectRatio("2.35:1") }
                    }
                }
                if session.isOpticalMedia, session.useVLC {
                    Menu("光盘菜单") {
                        ForEach(session.discTitles.indices, id: \.self) { index in
                            Button(session.discTitles[index]) { session.selectDiscTitle(index) }
                        }
                        Divider()
                        Button("上") { session.navigateDisc(.up) }
                        Button("下") { session.navigateDisc(.down) }
                        Button("左") { session.navigateDisc(.left) }
                        Button("右") { session.navigateDisc(.right) }
                        Button("确定") { session.navigateDisc(.activate) }
                    }
                }
                if session.playlistEntries.count > 1 {
                    Menu("播放列表") {
                        ForEach(session.playlistEntries) { entry in
                            Button(entry.title) { session.selectPlaylistEntry(entry) }
                        }
                    }
                }
                #if !os(tvOS)
                if session.useVLC {
                    Menu("投屏") {
                        Button("本机播放") { session.selectRenderer(nil) }
                        ForEach(castDiscovery.renderers.indices, id: \.self) { index in
                            Button(castDiscovery.renderers[index].name) {
                                session.selectRenderer(castDiscovery.renderers[index])
                            }
                        }
                        if castDiscovery.renderers.isEmpty { Text("正在寻找 Chromecast 设备") }
                    }
                }
                #endif
                Spacer()
                Button("前进 30 秒", systemImage: "goforward.30") { session.skip(by: 30) }
            }
            .buttonStyle(.bordered)
            .padding()
            if !session.segments.isEmpty {
                Toggle("自动跳过片段", isOn: $session.autoSkipSegments)
                    .font(.caption)
                    .padding(.horizontal)
            }
            if !session.autoSkipSegments,
               let segment = session.segments.first(where: {
                   $0.start <= session.currentTime && session.currentTime < $0.end
               }) {
                Button("跳过\(segment.title)", systemImage: "forward.end.fill") {
                    session.seek(to: segment.end)
                }
                .buttonStyle(.borderedProminent)
            }
            if let introEnd = item.skipIntroEnd,
               session.currentTime < introEnd,
               introEnd - session.currentTime <= 180 {
                Button("跳过片头", systemImage: "forward.end.fill") { session.seek(to: introEnd) }
                    .buttonStyle(.borderedProminent)
            }
            if let creditsStart = item.skipCreditsStart,
               session.currentTime >= creditsStart,
               session.duration > creditsStart + 5 {
                Button("跳过片尾", systemImage: "forward.end.fill") {
                    session.seek(to: max(0, session.duration - 1))
                }
                .buttonStyle(.borderedProminent)
            }
            if let nextItem {
                Button("下一集：\(nextItem.title)", systemImage: "forward.end.fill") {
                    onContinue?()
                }
                .padding(.bottom, 12)
            }
            if let message = session.message {
                Text(message)
                    .foregroundStyle(.red)
                    .padding()
            }
            if session.isBuffering {
                Text("正在缓冲 · 已中断 \(session.stallCount) 次")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 8)
            }
        }
        .background(.black)
        .onAppear { session.start(library: library); castDiscovery.start() }
        .onDisappear { castDiscovery.stop(); session.close() }
        #if os(tvOS)
        .onPlayPauseCommand { session.togglePlayback() }
        #endif
        #if os(macOS)
        .onKeyPress(.space) { session.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { session.skip(by: -10); return .handled }
        .onKeyPress(.rightArrow) { session.skip(by: 30); return .handled }
        #endif
        .onChange(of: session.didFinish) { _, finished in
            if finished, nextItem != nil { onContinue?() }
        }
    }

    private static func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let value = Int(seconds)
        let hours = value / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, value / 60 % 60, value % 60)
        }
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

}
