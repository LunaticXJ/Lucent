import AVKit
import Combine
import os
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

enum PlaybackEnginePreference: String, CaseIterable {
    case automatic, system, mpv
    var title: String {
        switch self {
        case .automatic: "自动选择"
        case .system: "AVPlayer"
        case .mpv: "MPV"
        }
    }
}

@MainActor
final class PlaybackSession: ObservableObject {
    private static let diagnosticLog = Logger(subsystem: "com.lucent.app", category: "PlaybackSeek")
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
    @Published private(set) var diagnostics = PlaybackDiagnostics()
    @Published private(set) var seekPreview: CGImage?
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
    @Published var useMPV = false
    @Published private(set) var mpvVideoReady = false
    @Published private(set) var enginePreference = PlaybackEnginePreference(
        rawValue: UserDefaults.standard.string(forKey: "lucent.playbackEngine") ?? "") ?? .automatic
    @Published private(set) var discTitles: [String] = []
    @Published private(set) var isOpticalMedia = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    let player = AVPlayer()
    private var mpvEngineStorage: MPVPlaybackEngine?
    var mpvEngine: MPVPlaybackEngine? {
        if mpvEngineStorage == nil { mpvEngineStorage = MPVPlaybackEngine() }
        return mpvEngineStorage
    }
    private var mpvTimer: Timer?
    private var mpvResumePosition: Double = 0
    private var mpvAttachedSubtitle = false
    private var mpvAttachedAudio = false
    private var activePlaybackURL: URL?
    #if canImport(VLCKit)
    let vlcPlayer = VLCMediaPlayer(options: ["--keystore=memory", "--quiet"])
    private var vlcTimer: Timer?
    // VLCKit's stream close callback can outlive media replacement. Keep the
    // callback object alive until the playback session itself is released.
    private var vlcInputStreams: [InputStream] = []
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
    private var seekPreviewTask: Task<Void, Never>?
    private var segmentTask: Task<Void, Never>?
    private var lastSkippedSegmentID: String?
    private var endObserver: NSObjectProtocol?
    private var playbackErrorObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var lastProgressSave = Date.distantPast
    private var resumeOverride: Double?
    private let item: MediaItem
    private let serverMediaSourceID: String?
    private var activeEmbyMediaSourceID: String?
    private let serverContainer: String?
    private let serverDolbyVision: Bool
    private let mediaFeatures: PlaybackMediaFeatures
    private let forceRemoteVersion: Bool
    private let transcodeBitrate: Int?
    private var automaticTranscodeBitrate: Int?
    private var directPlaybackFailure: String?
    private var directReconnectAttempts = 0
    private var lastMPVAdvanceAt = Date()
    private var lastMPVPosition: Double = 0
    private var audioStreamIndex: Int?
    private var subtitleStreamIndex: Int?
    private let plexPartID: Int?
    private let plexMediaIndex: Int
    let serverTracks: ServerPlaybackTracks
    private var plexTranscode: (address: String, token: String, sessionID: UUID)?
    private weak var library: LibraryStore?

    init(item: MediaItem, serverMediaSourceID: String? = nil,
         serverContainer: String? = nil, serverDolbyVision: Bool = false,
         mediaFeatures: PlaybackMediaFeatures = .unknown,
         forceRemoteVersion: Bool = false, transcodeBitrate: Int? = nil,
         audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
         plexPartID: Int? = nil, plexMediaIndex: Int = 0,
         serverTracks: ServerPlaybackTracks = .empty) {
        self.item = item
        self.serverMediaSourceID = serverMediaSourceID
        self.serverContainer = serverContainer
        self.serverDolbyVision = serverDolbyVision
        self.mediaFeatures = mediaFeatures
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
                loadingTask = Task { [weak self] in
                    defer { self?.loadingTask = nil }
                    do {
                        let stream = try await EmbyClient.transcodingURL(
                            source: source, token: token, itemID: itemID,
                            mediaSourceID: self?.serverMediaSourceID, bitrate: transcodeBitrate)
                        guard !Task.isCancelled else { return }
                        self?.play(url: stream)
                    } catch {
                        self?.message = "Emby 转码不可用：\(error.localizedDescription)"
                    }
                }
                return
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
            loadingTask = Task { [weak self] in
                defer { self?.loadingTask = nil }
                var activeServer: RangeHTTPServer?
                do {
                    let versions = try? await EmbyClient.versions(source: source, token: token, itemID: itemID)
                    guard !Task.isCancelled, let self else { return }
                    let selected = versions?.first(where: { $0.id == self.serverMediaSourceID })
                        ?? versions?.first
                    let mediaSourceID = self.serverMediaSourceID ?? selected?.id
                    self.activeEmbyMediaSourceID = mediaSourceID
                    let declaredContainer = selected?.container ?? self.serverContainer
                        ?? self.item.serverFileExtension ?? "mp4"
                    // A STRM entry names a link, not the linked video's container.
                    // Expose it as an opaque stream so MPV probes the actual bytes.
                    let container = declaredContainer.lowercased() == "strm" ? "bin" : declaredContainer
                    let server = RangeHTTPServer(fileExtension: container, maxReadAttempts: 2,
                        blockLength: 524_288,
                        readRange: { offset, length in
                            try EmbyClient.readRange(source: source, token: token, itemID: itemID,
                                                     offset: offset, length: length,
                                                     mediaSourceID: mediaSourceID)
                        }, onReadFailure: { [weak self] error in
                            Task { @MainActor [weak self] in
                                guard let self, self.smbServer != nil else { return }
                                if self.currentTime > 0.5 {
                                    self.directPlaybackFailure = error.localizedDescription
                                } else {
                                    self.fallbackFromDirectEmby(source: source, token: token,
                                                                itemID: itemID, failure: error)
                                }
                            }
                        })
                    activeServer = server
                    self.smbServer = server
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self.play(url: url)
                } catch {
                    self?.message = "无法播放 Emby 视频：\(error.localizedDescription)"
                    activeServer?.stop()
                }
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

    private func fallbackFromDirectEmby(source: EmbySource, token: String,
                                        itemID: String, failure: Error) {
        guard automaticTranscodeBitrate == nil, smbServer != nil else { return }
        directPlaybackFailure = failure.localizedDescription
        startEmbyTranscode(source: source, token: token, itemID: itemID,
                           bitrate: 8_000_000, originalFailure: failure)
    }

    func selectEmbyTranscodeBitrate(_ bitrate: Int) {
        guard case .embyItem(let sourceID, let itemID) = item.location,
              let source = library?.embySources.first(where: { $0.id == sourceID }),
              let token = try? KeychainPasswordStore.embyToken(for: sourceID),
              !token.isEmpty else {
            message = "Emby 授权不可用。"
            return
        }
        directPlaybackFailure = nil
        startEmbyTranscode(source: source, token: token, itemID: itemID,
                           bitrate: bitrate, originalFailure: nil)
    }

    private func startEmbyTranscode(source: EmbySource, token: String, itemID: String,
                                    bitrate: Int, originalFailure: Error?) {
        loadingTask?.cancel()
        automaticTranscodeBitrate = bitrate
        if currentTime.isFinite, currentTime > 0 { resumeOverride = currentTime }
        smbServer?.stop()
        smbServer = nil
        let mediaSourceID = activeEmbyMediaSourceID ?? serverMediaSourceID
        loadingTask = Task { [weak self] in
            defer { self?.loadingTask = nil }
            do {
                let fallback = try await EmbyClient.transcodingURL(
                    source: source, token: token, itemID: itemID,
                    mediaSourceID: mediaSourceID, bitrate: bitrate)
                guard !Task.isCancelled else { return }
                self?.play(url: fallback)
            } catch {
                let prefix = originalFailure.map { "直连失败：\($0.localizedDescription)；" } ?? ""
                self?.message = "\(prefix)Emby 转码不可用：\(error.localizedDescription)"
            }
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
        let needsExtendedEngine = Self.needsExtendedEngine(url)
        let hasNativeSubtitle = nativeSubtitleURL != nil
        let hasExternalAudio = externalAudioURL != nil
        let extendedRoute = needsExtendedEngine || hasNativeSubtitle || hasExternalAudio
        #if canImport(VLCKit)
        let opticalFallback = isOpticalMedia && enginePreference != .mpv
        #else
        let opticalFallback = false
        #endif
        let mpvRoute = !opticalFallback && (enginePreference == .mpv || (enginePreference == .automatic && extendedRoute))
        var report = PlaybackDiagnostics()
        report.engine = opticalFallback ? .vlc : (mpvRoute ? .mpv : .native)
        if transcodeBitrate != nil || automaticTranscodeBitrate != nil {
            report.delivery = "服务器转码 HLS"
        } else {
            switch item.location {
            case .bookmark, .folderFile: report.delivery = "本地文件"
            case .remote: report.delivery = "网络地址直连"
            default: report.delivery = "远程文件直连"
            }
        }
        report.container = transcodeBitrate == nil && automaticTranscodeBitrate == nil ?
            (mediaFeatures.container ?? serverContainer ?? url.pathExtension).uppercased() : "HLS"
        report.videoCodec = transcodeBitrate == nil && automaticTranscodeBitrate == nil ? (mediaFeatures.videoCodec ?? "待识别") : "服务器决定"
        report.audioCodec = transcodeBitrate == nil && automaticTranscodeBitrate == nil ? (mediaFeatures.audioCodec ?? "待识别") : "服务器决定"
        report.dynamicRange = transcodeBitrate == nil && automaticTranscodeBitrate == nil ? (mediaFeatures.dynamicRange ?? "待识别") : "由服务器处理"
        report.resolution = mediaFeatures.resolution ?? "待识别"
        report.requestedDolbyVision = serverDolbyVision
        report.routeReason = opticalFallback ? "光盘菜单暂由 VLC 播放" :
            automaticTranscodeBitrate != nil ? "直连中断，已自动切换 Emby 转码" :
            transcodeBitrate != nil ? "已选择服务器转码画质" :
            enginePreference == .mpv ? "用户选择 MPV" :
            needsExtendedEngine ? "容器或协议需由 MPV 处理" :
            hasNativeSubtitle ? "外挂位图或样式字幕需由 MPV 处理" :
            hasExternalAudio ? "外挂音轨需由 MPV 处理" :
            serverDolbyVision ? "优先使用系统播放器保留兼容的杜比视界流" :
            "容器适合系统播放器直连"
        diagnostics = report
        activePlaybackURL = url
        #if canImport(VLCKit)
        if opticalFallback {
            playWithVLC(url: url)
            return
        }
        #endif
        if mpvRoute {
            playWithMPV(url: url)
            return
        }
        player.allowsExternalPlayback = true
        let playerItem = AVPlayerItem(url: url)
        playerItem.preferredPeakBitRate = preferredPeakBitRate
        player.replaceCurrentItem(with: playerItem)
        playerItemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            let detail = item.error?.localizedDescription ?? "无法载入视频流。"
            Task { @MainActor [weak self] in
                guard let self else { return }
                let source = self.directPlaybackFailure.map { "（直连也失败：\($0)）" } ?? ""
                self.message = "播放失败：\(detail)\(source)"
            }
        }
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
            Task { @MainActor [weak self] in
                guard let self else { return }
                let source = self.directPlaybackFailure.map { "（直连也失败：\($0)）" } ?? ""
                self.message = "播放失败：\(detail)\(source)"
            }
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
                let detected = await DolbyVisionSupport.assetHasDolbyVision(playerItem.asset)
                self?.dolbyVisionDetected = detected
                self?.diagnostics.detectedDolbyVision = detected
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
        playerItemStatusObservation = nil
        seekPreviewTask?.cancel()
        seekPreviewTask = nil
        seekPreview = nil
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
        mpvTimer?.invalidate()
        mpvTimer = nil
        if useMPV { mpvEngine?.stop() }
        useMPV = false
        mpvVideoReady = false
        mpvAttachedSubtitle = false
        mpvAttachedAudio = false
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

    private static func needsExtendedEngine(_ url: URL) -> Bool {
        if ["VIDEO_TS", "BDMV"].contains(url.lastPathComponent.uppercased()) { return true }
        if url.isFileURL, url.pathExtension.lowercased() == "m3u8" { return true }
        if ["ftp", "ftps", "sftp", "nfs"].contains(url.scheme?.lowercased() ?? "") { return true }
        return ["bin", "mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts", "vob", "mpg", "mpeg", "ogv", "iso"]
            .contains(url.pathExtension.lowercased())
    }

    func preview(at seconds: Double) {
        seekPreviewTask?.cancel()
        guard !useVLC, seconds.isFinite, seconds >= 0,
              let url = (player.currentItem?.asset as? AVURLAsset)?.url else {
            seekPreview = nil
            return
        }
        seekPreviewTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(180))
            guard !Task.isCancelled else { return }
            let image = await Self.generateSeekPreview(url: url, seconds: seconds)
            guard !Task.isCancelled else { return }
            self?.seekPreview = image
        }
    }

    private nonisolated static func generateSeekPreview(url: URL, seconds: Double) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: 360, height: 204)
        generator.appliesPreferredTrackTransform = true
        return try? await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600)).image
    }

    func clearPreview() {
        seekPreviewTask?.cancel()
        seekPreviewTask = nil
        seekPreview = nil
    }

    private static func usesNativeSubtitle(_ fileExtension: String) -> Bool {
        ["ass", "ssa", "sup"].contains(fileExtension.lowercased())
    }

    private func playWithMPV(url: URL) {
        guard let mpvEngine else {
            message = "MPV 播放内核无法初始化。"
            return
        }
        mpvResumePosition = resumeOverride ?? (item.watched ? 0 : item.position)
        resumeOverride = nil
        useMPV = true
        lastMPVAdvanceAt = Date()
        lastMPVPosition = 0
        mpvEngine.load(url)
        mpvTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickMPV() }
        }
    }

    private func tickMPV() {
        guard useMPV, let mpvEngine else { return }
        mpvEngine.pollEvents()
        if let playbackError = mpvEngine.playbackError {
            if retryDirectMPV() { return }
            message = playbackError
        }
        if mpvEngine.ended { didFinish = true; return }
        let mediaDuration = mpvEngine.duration
        let videoReady = mpvEngine.hasVideoOutput && mpvEngine.time > 0.1
        if mpvVideoReady != videoReady { mpvVideoReady = videoReady }
        if mediaDuration.isFinite, mediaDuration > 0 { duration = mediaDuration }
        if mpvResumePosition > 0, duration > 0, mpvEngine.isSeekable {
            mpvEngine.seek(to: mpvResumePosition)
            mpvResumePosition = 0
        }
        let seconds = mpvEngine.time
        guard seconds.isFinite, seconds >= 0 else { return }
        currentTime = seconds
        isBuffering = mpvEngine.isBuffering
        if abs(seconds - lastMPVPosition) > 0.1 {
            lastMPVPosition = seconds
            lastMPVAdvanceAt = Date()
        } else if isBuffering, directPlaybackFailure != nil,
                  Date().timeIntervalSince(lastMPVAdvanceAt) > 8 {
            if retryDirectMPV() { return }
            message = "外部视频连接持续中断：\(directPlaybackFailure ?? "未知错误")"
        }
        if !mpvAttachedSubtitle, let nativeSubtitleURL, duration > 0 {
            mpvEngine.addSubtitle(nativeSubtitleURL)
            mpvAttachedSubtitle = true
        }
        if !mpvAttachedAudio, let externalAudioURL, duration > 0 {
            mpvEngine.addAudio(externalAudioURL)
            mpvAttachedAudio = true
        }
        let availableAudio = mpvEngine.trackNames(type: "audio")
        let availableSubtitles = mpvEngine.trackNames(type: "sub")
        if audioOptions != availableAudio { audioOptions = availableAudio }
        if subtitleOptions != availableSubtitles { subtitleOptions = availableSubtitles }
        let subtitleTime = seconds - subtitleDelay
        subtitleText = subtitlesEnabled
            ? (subtitleCues.first { $0.start <= subtitleTime && subtitleTime < $0.end }?.text ?? "")
            : ""
        if Date().timeIntervalSince(lastProgressSave) >= 5 {
            library?.updateProgress(id: item.id, position: seconds, duration: duration)
            lastProgressSave = Date()
        }
        applyAutomaticSkip(at: seconds)
    }

    private func retryDirectMPV() -> Bool {
        guard directPlaybackFailure != nil, directReconnectAttempts < 2,
              smbServer != nil, let activePlaybackURL, let mpvEngine else { return false }
        directReconnectAttempts += 1
        mpvResumePosition = currentTime
        mpvVideoReady = false
        lastMPVAdvanceAt = Date()
        mpvEngine.load(activePlaybackURL)
        return true
    }

    #if canImport(VLCKit)
    private func playWithVLC(url: URL) {
        let media: VLCMedia?
        if let smbServer, smbServer.supportsSynchronousInputStream {
            let input = smbServer.makeInputStream()
            vlcInputStreams.append(input)
            media = VLCMedia(stream: input)
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
        let seconds = (vlcPlayer.time.value?.doubleValue ?? 0) / 1000
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
        let mediaDuration = (vlcPlayer.media?.length.value?.doubleValue ?? 0) / 1000
        if mediaDuration.isFinite, mediaDuration > 0 { duration = mediaDuration }
        if vlcResumePosition > 0, duration > 0, vlcPlayer.isPlaying {
            seek(to: vlcResumePosition)
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
        if useMPV { seek(to: chapter.start); return }
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
        if useMPV { mpvEngine?.setAspectRatio(ratio); return }
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
        if useMPV { seek(to: (mpvEngine?.time ?? currentTime) + seconds); return }
        #if canImport(VLCKit)
        if useVLC {
            let current = (vlcPlayer.time.value?.doubleValue ?? 0) / 1000
            let target = max(0, current + seconds)
            seek(to: target)
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
        if useMPV {
            if mpvEngine?.ended == true, let activePlaybackURL {
                mpvResumePosition = target
                didFinish = false
                mpvEngine?.load(activePlaybackURL)
            } else {
                mpvEngine?.seek(to: target)
            }
            currentTime = target
            return
        }
        #if canImport(VLCKit)
        if useVLC {
            #if DEBUG
            Self.diagnosticLog.info("seek request seconds=\(target) duration=\(self.duration) seekable=\(self.vlcPlayer.isSeekable) state=\(String(describing: self.vlcPlayer.state))")
            #endif
            if smbServer != nil, duration > 0 {
                vlcPlayer.position = target / duration
            } else {
                vlcPlayer.time = VLCTime(number: NSNumber(value: Int64(target * 1000)))
            }
            currentTime = target
            return
        }
        #endif
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if useMPV { mpvEngine?.setRate(rate); return }
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

    func selectEnginePreference(_ preference: PlaybackEnginePreference) {
        guard enginePreference != preference else { return }
        enginePreference = preference
        UserDefaults.standard.set(preference.rawValue, forKey: "lucent.playbackEngine")
        guard let activePlaybackURL else { return }
        resumeOverride = currentTime
        play(url: activePlaybackURL)
    }

    func togglePlayback() {
        if useMPV {
            guard let mpvEngine else { return }
            if mpvEngine.ended, let activePlaybackURL {
                mpvResumePosition = currentTime < max(0, duration - 1) ? currentTime : 0
                didFinish = false
                mpvEngine.load(activePlaybackURL)
                return
            }
            mpvEngine.setPaused(!mpvEngine.isPaused)
            return
        }
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
        playerItemStatusObservation = nil
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
        mpvTimer?.invalidate()
        mpvTimer = nil
        #if canImport(VLCKit)
        let seconds = useVLC ? Double(vlcPlayer.time.intValue) / 1000 : player.currentTime().seconds
        let duration = useVLC ? Double(vlcPlayer.media?.length.intValue ?? 0) / 1000 : player.currentItem?.duration.seconds
        let hasItem = useVLC || player.currentItem != nil
        #else
        let seconds = player.currentTime().seconds
        let duration = player.currentItem?.duration.seconds
        let hasItem = player.currentItem != nil
        #endif
        let finalSeconds = useMPV ? (mpvEngine?.time ?? currentTime) : seconds
        let finalDuration = useMPV ? self.duration : duration
        if hasItem || useMPV, finalSeconds.isFinite, finalSeconds >= 0 {
            library?.finishPlayback(id: item.id, position: finalSeconds, duration: finalDuration)
        }
        mpvEngineStorage?.destroy()
        mpvEngineStorage = nil
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
        if useMPV { mpvEngine?.setSubtitleTrack(subtitlesEnabled ? 0 : nil); return }
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
        if useMPV { mpvEngine?.setSubtitleDelay(subtitleDelay); return }
        #if canImport(VLCKit)
        if useVLC, nativeSubtitleAttached {
            vlcPlayer.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000)
        }
        #endif
    }

    func selectAudio(_ index: Int) {
        if useMPV { mpvEngine?.setAudioTrack(index); return }
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
        if useMPV { mpvEngine?.setSubtitleTrack(index); return }
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
            let source = directPlaybackFailure.map { "（直连也失败：\($0)）" } ?? ""
            message = "播放失败：\(failure.localizedDescription)\(source)"
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

#if os(iOS)
@MainActor private enum EpisodeCardCache {
    static let images = NSCache<NSString, UIImage>()
}

private struct EpisodeCardArtwork: View {
    @EnvironmentObject private var library: LibraryStore
    let itemID: String
    let storedItem: MediaItem?
    let currentLocation: MediaLocation
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.18, green: 0.23, blue: 0.29),
                                    Color(red: 0.08, green: 0.11, blue: 0.17)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "film.stack")
                    .font(.system(size: 28, weight: .ultraLight))
                    .foregroundStyle(.white.opacity(0.42))
            }
        }
        .clipped()
        .task(id: itemID) { await loadArtwork() }
    }

    private func loadArtwork() async {
        if let storedItem, let url = library.posterURL(for: storedItem),
           let local = UIImage(contentsOfFile: url.path) {
            image = local
            return
        }
        let source: (URL, UUID)?
        switch currentLocation {
        case .embyItem(let sourceID, _):
            source = library.embySources.first(where: { $0.id == sourceID })
                .flatMap { URL(string: $0.baseAddress).map { ($0, sourceID) } }
        case .jellyfinItem(let sourceID, _):
            source = library.jellyfinSources.first(where: { $0.id == sourceID })
                .flatMap { URL(string: $0.baseAddress).map { ($0, sourceID) } }
        default:
            source = nil
        }
        guard let (base, sourceID) = source else { return }
        let key = "\(sourceID)|\(itemID)" as NSString
        if let cached = EpisodeCardCache.images.object(forKey: key) {
            image = cached
            return
        }
        let token: String?
        switch currentLocation {
        case .embyItem: token = try? KeychainPasswordStore.embyToken(for: sourceID)
        case .jellyfinItem: token = try? KeychainPasswordStore.jellyfinToken(for: sourceID)
        default: token = nil
        }
        guard let token, !token.isEmpty else { return }
        for imagePath in ["Backdrop/0", "Primary"] {
            var imageURL = base.appendingPathComponent("Items")
                .appendingPathComponent(itemID).appendingPathComponent("Images")
            for component in imagePath.split(separator: "/") {
                imageURL.appendPathComponent(String(component))
            }
            var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "maxWidth", value: "500")]
            var request = URLRequest(url: components.url!)
            request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  data.count < 5_000_000, let loaded = UIImage(data: data) else { continue }
            EpisodeCardCache.images.setObject(loaded, forKey: key)
            image = loaded
            return
        }
    }
}
#endif

struct PlaybackView: View {
    private struct EpisodeChoice: Identifiable {
        let id: String
        let title: String
        let season: Int
        let number: Int
        let watched: Bool
        let item: MediaItem?
        let remote: JellyfinItem?
    }

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lucent.subtitleFontScale") private var subtitleFontScale = 1.0
    @AppStorage("lucent.subtitleBackgroundOpacity") private var subtitleBackgroundOpacity = 0.6
    @StateObject private var session: PlaybackSession
    @StateObject private var castDiscovery = CastDiscovery()
    @State private var seekPosition: Double = 0
    @State private var isSeeking = false
    @State private var showDiagnostics = false
    @State private var controlsLocked = false
    @State private var showEpisodeList = false
    @State private var selectedEpisodeSeason: Int?
    @State private var episodeChoices: [EpisodeChoice] = []
    @State private var episodeLoading = false
    @State private var episodeError: String?
    private let item: MediaItem
    private let nextItem: MediaItem?
    private let onContinue: (() -> Void)?
    private let onSelectEpisode: ((MediaItem) -> Void)?
    private let transcodeBitrate: Int?

    init(item: MediaItem, nextItem: MediaItem? = nil,
         serverMediaSourceID: String? = nil, serverContainer: String? = nil,
         serverDolbyVision: Bool = false,
         mediaFeatures: PlaybackMediaFeatures = .unknown,
         forceRemoteVersion: Bool = false,
         transcodeBitrate: Int? = nil,
         audioStreamIndex: Int? = nil, subtitleStreamIndex: Int? = nil,
         plexPartID: Int? = nil, plexMediaIndex: Int = 0,
         serverTracks: ServerPlaybackTracks = .empty,
         onContinue: (() -> Void)? = nil,
         onSelectEpisode: ((MediaItem) -> Void)? = nil) {
        self.item = item
        self.nextItem = nextItem
        self.onContinue = onContinue
        self.onSelectEpisode = onSelectEpisode
        self.transcodeBitrate = transcodeBitrate
        if case .episode(_, let season, _, _) = item.identity {
            _selectedEpisodeSeason = State(initialValue: season)
        }
        _session = StateObject(wrappedValue: PlaybackSession(
            item: item, serverMediaSourceID: serverMediaSourceID,
            serverContainer: serverContainer, serverDolbyVision: serverDolbyVision,
            mediaFeatures: mediaFeatures,
            forceRemoteVersion: forceRemoteVersion, transcodeBitrate: transcodeBitrate,
            audioStreamIndex: audioStreamIndex, subtitleStreamIndex: subtitleStreamIndex,
            plexPartID: plexPartID, plexMediaIndex: plexMediaIndex, serverTracks: serverTracks))
    }

    var body: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                if session.useMPV, let engine = session.mpvEngine {
                    MPVPlayerSurface(engine: engine)
                    if !session.mpvVideoReady { Color.black.allowsHitTesting(false) }
                } else {
                #if canImport(VLCKit)
                if session.useVLC {
                    VLCPlayerSurface(player: session.vlcPlayer)
                } else {
                    PlayerSurface(player: session.player)
                }
                #else
                PlayerSurface(player: session.player)
                #endif
                }
                if !session.subtitleText.isEmpty {
                    Text(session.subtitleText)
                        .font(.system(size: 22 * subtitleFontScale, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 5)
                        .padding(12)
                        .background(.black.opacity(subtitleBackgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, controlsLocked ? 32 : 138)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            VStack(spacing: 0) {
                if !controlsLocked && !showEpisodeList { playbackHeader }
                Spacer(minLength: 0)
                if !showEpisodeList {
                    HStack {
                        roundControl("锁定或解锁控制", systemImage: controlsLocked ? "lock.fill" : "lock.open") {
                            controlsLocked.toggle()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                }
                Spacer(minLength: 0)
                if !controlsLocked && !showEpisodeList { playbackFooter }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(iOS)
            if showEpisodeList { episodeCarousel }
            #endif
        }
        .ignoresSafeArea(edges: .vertical)
        .background(.black)
        .foregroundStyle(.white)
        .tint(.white)
        .sheet(isPresented: $showDiagnostics) {
            PlaybackDiagnosticsPanel(report: session.diagnostics,
                                     buffering: session.isBuffering,
                                     stalls: session.stallCount,
                                     failure: session.message)
        }
        #if !os(iOS)
        .sheet(isPresented: $showEpisodeList) { episodeList }
        #endif
        .task(id: item.id) { await loadEpisodeChoices() }
        .onAppear {
            #if os(iOS)
            LucentOrientationDelegate.setPlaybackPresented(true)
            #endif
            session.start(library: library)
            castDiscovery.start()
        }
        .onDisappear {
            castDiscovery.stop()
            session.close()
            #if os(iOS)
            LucentOrientationDelegate.setPlaybackPresented(false)
            #endif
        }
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

    private var episodeList: some View {
        NavigationStack {
            List {
                if episodeLoading { ProgressView("正在读取剧集…") }
                if let episodeError {
                    Section {
                        Text(episodeError).foregroundStyle(.secondary)
                        Button("重试") { Task { await loadEpisodeChoices() } }
                    }
                }
                ForEach(Array(Set(episodeChoices.map(\.season))).sorted(), id: \.self) { season in
                    Section(season == 0 ? "特别篇" : "第 \(season) 季") {
                        ForEach(episodeChoices.filter { $0.season == season }) { choice in
                            Button { selectEpisode(choice) } label: {
                                HStack(spacing: 12) {
                                    Text(choice.number > 0 ? String(format: "%02d", choice.number) : "·")
                                        .font(.subheadline.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                        .frame(width: 30, alignment: .leading)
                                    Text(choice.title).lineLimit(2)
                                    Spacer()
                                    if choice.id == currentEpisodeID || choice.item?.id == item.id {
                                        Image(systemName: "waveform").foregroundStyle(.tint)
                                    } else if choice.watched {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !episodeLoading && episodeChoices.isEmpty && episodeError == nil {
                    ContentUnavailableView("暂无剧集", systemImage: "list.bullet.rectangle")
                }
            }
            .navigationTitle(item.identity?.seriesName ?? "剧集列表")
            .toolbar { Button("完成") { showEpisodeList = false } }
        }
        .preferredColorScheme(.dark)
    }

    #if os(iOS)
    private var episodeCarousel: some View {
        ZStack {
            Color.black.opacity(0.48)
                .ignoresSafeArea()
                .onTapGesture { showEpisodeList = false }
            VStack(spacing: 0) {
                playbackHeader
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 14) {
                        Text("选集")
                            .font(.system(size: 16, weight: .semibold))
                        Menu {
                            Button("全部剧集") { selectedEpisodeSeason = nil }
                            ForEach(Array(Set(episodeChoices.map(\.season))).sorted(), id: \.self) { season in
                                Button(season == 0 ? "特别篇" : "第 \(season) 季") {
                                    selectedEpisodeSeason = season
                                }
                            }
                        } label: {
                            HStack(spacing: 5) {
                                Text(selectedEpisodeSeason.map { $0 == 0 ? "特别篇" : "第 \($0) 季" } ?? "全部剧集")
                                Image(systemName: "chevron.down").font(.caption2)
                            }
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                        }
                        Spacer()
                        if episodeLoading { ProgressView().tint(.white) }
                        Text("\(filteredEpisodeChoices.count) 集")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                        Button("关闭选集", systemImage: "xmark") { showEpisodeList = false }
                            .labelStyle(.iconOnly)
                            .font(.system(size: 14, weight: .semibold))
                            .frame(width: 28, height: 28)
                            .background(.white.opacity(0.15), in: Circle())
                    }
                    .padding(.horizontal, 28)
                    if let episodeError {
                        Text(episodeError)
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                            .padding(.horizontal, 28)
                    }
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(alignment: .top, spacing: 15) {
                                ForEach(filteredEpisodeChoices) { choice in
                                    Button { selectEpisode(choice) } label: {
                                        VStack(alignment: .leading, spacing: 5) {
                                            EpisodeCardArtwork(itemID: choice.id,
                                                               storedItem: choice.item,
                                                               currentLocation: item.location)
                                                .frame(width: 190, height: 107)
                                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                                .overlay {
                                                    RoundedRectangle(cornerRadius: 12)
                                                        .strokeBorder(choice.id == currentEpisodeID || choice.item?.id == item.id
                                                                      ? Color.green : .clear, lineWidth: 2)
                                                }
                                                .overlay(alignment: .bottomTrailing) {
                                                    if choice.id == currentEpisodeID || choice.item?.id == item.id {
                                                        Image(systemName: "waveform")
                                                            .font(.system(size: 13, weight: .semibold))
                                                            .padding(8)
                                                            .background(.black.opacity(0.68), in: Circle())
                                                            .padding(5)
                                                    }
                                                }
                                            Text(choice.title)
                                                .font(.system(size: 13, weight: .medium))
                                                .lineLimit(1)
                                                .frame(width: 190, alignment: .leading)
                                            Text(choice.season == 0
                                                 ? "特别篇 · 第 \(choice.number) 集"
                                                 : "第 \(choice.season) 季 · 第 \(choice.number) 集")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.62))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .id(choice.id)
                                }
                            }
                            .padding(.horizontal, 28)
                        }
                        .onAppear { proxy.scrollTo(selectedEpisodeChoiceID, anchor: .center) }
                        .onChange(of: episodeChoices.map(\.id)) { _, _ in
                            proxy.scrollTo(selectedEpisodeChoiceID, anchor: .center)
                        }
                        .onChange(of: selectedEpisodeSeason) { _, _ in
                            if let first = filteredEpisodeChoices.first {
                                proxy.scrollTo(first.id, anchor: .leading)
                            }
                        }
                    }
                    .frame(height: 164)
                }
                .padding(.top, 18)
                .padding(.bottom, 20)
                .background(.linearGradient(colors: [.clear, .black.opacity(0.72), .black.opacity(0.95)],
                                            startPoint: .top, endPoint: .bottom))
            }
        }
        .transition(.opacity)
    }

    private var filteredEpisodeChoices: [EpisodeChoice] {
        episodeChoices.filter { selectedEpisodeSeason == nil || $0.season == selectedEpisodeSeason }
    }

    private var selectedEpisodeChoiceID: String {
        filteredEpisodeChoices.first(where: { $0.id == currentEpisodeID || $0.item?.id == item.id })?.id
            ?? filteredEpisodeChoices.first?.id ?? currentEpisodeID
    }
    #endif

    private var currentEpisodeID: String {
        switch item.location {
        case .embyItem(_, let id), .jellyfinItem(_, let id): return id
        default: return item.id.uuidString
        }
    }

    private func selectEpisode(_ choice: EpisodeChoice) {
        if choice.id == currentEpisodeID || choice.item?.id == item.id {
            showEpisodeList = false
            return
        }
        guard onSelectEpisode != nil else { return }
        let selected: MediaItem?
        if let stored = choice.item {
            selected = stored
        } else if let remote = choice.remote {
            switch item.location {
            case .embyItem(let sourceID, _):
                selected = library.openEmbyItem(sourceID: sourceID, remote: remote)
            case .jellyfinItem(let sourceID, _):
                selected = library.openJellyfinItem(sourceID: sourceID, remote: remote)
            default:
                selected = nil
            }
        } else {
            selected = nil
        }
        guard let selected else { return }
        showEpisodeList = false
        onSelectEpisode?(selected)
    }

    private func loadEpisodeChoices() async {
        guard let series = item.identity?.seriesName else { return }
        episodeLoading = true
        episodeError = nil
        let local = library.visibleItems.filter {
            $0.identity?.seriesName == series && sameEpisodeSource($0.location, item.location)
        }
        episodeChoices = local.compactMap { candidate in
            guard case .episode(_, let season, let number, _) = candidate.identity else { return nil }
            return EpisodeChoice(id: candidate.id.uuidString, title: candidate.title,
                                 season: season, number: number, watched: candidate.watched,
                                 item: candidate, remote: nil)
        }.sorted { ($0.season, $0.number, $0.title) < ($1.season, $1.number, $1.title) }
        if episodeChoices.isEmpty,
           case .episode(_, let season, let number, _) = item.identity {
            episodeChoices = [EpisodeChoice(id: currentEpisodeID, title: item.title,
                                            season: season, number: number, watched: item.watched,
                                            item: item, remote: nil)]
        }

        let source: (base: String, userID: String, itemID: String, token: String)?
        do {
            switch item.location {
            case .embyItem(let sourceID, let itemID):
                guard let server = library.embySources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.embyToken(for: sourceID) else {
                    throw PlaybackError.fileUnavailable
                }
                source = (server.baseAddress, server.userID, itemID, token)
            case .jellyfinItem(let sourceID, let itemID):
                guard let server = library.jellyfinSources.first(where: { $0.id == sourceID }),
                      let token = try KeychainPasswordStore.jellyfinToken(for: sourceID) else {
                    throw PlaybackError.fileUnavailable
                }
                source = (server.baseAddress, server.userID, itemID, token)
            default:
                source = nil
            }
            if let source {
                let remote = try await ServerEpisodeClient.episodes(baseAddress: source.base,
                    userID: source.userID, itemID: source.itemID, token: source.token)
                if !remote.isEmpty {
                    episodeChoices = remote.map { episode in
                        EpisodeChoice(id: episode.id, title: episode.name,
                                      season: episode.parentIndexNumber ?? 0,
                                      number: episode.indexNumber ?? 0,
                                      watched: episode.userData?.played ?? false,
                                      item: nil, remote: episode)
                    }
                }
            }
        } catch {
            episodeError = "无法读取服务器剧集：\(error.localizedDescription)"
        }
        episodeLoading = false
    }

    private func sameEpisodeSource(_ candidate: MediaLocation, _ current: MediaLocation) -> Bool {
        switch (candidate, current) {
        case (.embyItem(let lhs, _), .embyItem(let rhs, _)),
             (.jellyfinItem(let lhs, _), .jellyfinItem(let rhs, _)),
             (.plexItem(let lhs, _, _), .plexItem(let rhs, _, _)):
            return lhs == rhs
        case (.embyItem, _), (.jellyfinItem, _), (.plexItem, _):
            return false
        case (_, .embyItem), (_, .jellyfinItem), (_, .plexItem):
            return false
        default:
            return true
        }
    }

    private var playbackHeader: some View {
        ZStack {
            Text(item.title)
                .font(.system(size: 15, weight: .medium))
                .lineLimit(1)
                .frame(maxWidth: 500)
                .padding(.horizontal, 140)
            HStack(spacing: 12) {
                roundControl("关闭", systemImage: "xmark") { dismiss() }
                Spacer()
                if session.dolbyVisionDetected {
                    Text("Dolby Vision")
                        .font(.caption2.bold())
                        .foregroundStyle(.yellow)
                }
                #if os(iOS)
                if !session.useMPV { AudioRoutePicker()
                    .frame(width: 48, height: 48)
                    .background(.black.opacity(0.4), in: Circle())
                    .accessibilityLabel("音频输出设备") }
                #endif
                roundControl("播放信息", systemImage: "info.circle") { showDiagnostics = true }
            }
        }
        .padding(.horizontal, 28)
        .padding(.top, 12)
        .padding(.bottom, 30)
        .background(.linearGradient(colors: [.black.opacity(0.75), .clear],
                                    startPoint: .top, endPoint: .bottom))
    }

    private var playbackFooter: some View {
        VStack(spacing: 2) {
            HStack(spacing: 8) {
                if !session.autoSkipSegments,
                   let segment = session.segments.first(where: {
                       $0.start <= session.currentTime && session.currentTime < $0.end
                   }) {
                    skipButton("跳过\(segment.title)") { session.seek(to: segment.end) }
                }
                if let introEnd = item.skipIntroEnd,
                   session.currentTime < introEnd,
                   introEnd - session.currentTime <= 180 {
                    skipButton("跳过片头") { session.seek(to: introEnd) }
                }
                if let creditsStart = item.skipCreditsStart,
                   session.currentTime >= creditsStart,
                   session.duration > creditsStart + 5 {
                    skipButton("跳过片尾") { session.seek(to: max(0, session.duration - 1)) }
                }
                if let nextItem {
                    skipButton("下一集：\(nextItem.title)") { onContinue?() }
                }
                Spacer(minLength: 0)
            }
            .frame(height: 40)

            if let message = session.message {
                Text(message).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if session.isBuffering {
                Text("正在缓冲 · 已中断 \(session.stallCount) 次")
                    .font(.caption).foregroundStyle(.white.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isSeeking, let preview = session.seekPreview {
                Image(decorative: preview, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 128, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: .infinity)
            }

            HStack(spacing: 12) {
                Text(Self.timeLabel(isSeeking ? seekPosition : session.currentTime))
                    .frame(minWidth: 46, alignment: .leading)
                seekTrack
                Text(Self.timeLabel(session.duration))
                    .frame(minWidth: 46, alignment: .trailing)
            }
            .font(.system(size: 13, weight: .medium, design: .monospaced))

            HStack(spacing: 0) {
                HStack(spacing: 24) {
                    if item.identity?.seriesName != nil {
                        Button("剧集列表", systemImage: "list.bullet") { showEpisodeList = true }
                            .labelStyle(.iconOnly)
                    }
                    if session.playlistEntries.count > 1 {
                        Menu("播放列表", systemImage: "list.bullet") {
                            ForEach(session.playlistEntries) { entry in
                                Button(entry.title) { session.selectPlaylistEntry(entry) }
                            }
                        }
                        .labelStyle(.iconOnly)
                    }
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button("\(rate.formatted())×") { session.setPlaybackRate(Float(rate)) }
                        }
                    } label: {
                        Text("\(Double(session.playbackRate).formatted())×")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    Button("后退 10 秒", systemImage: "gobackward.10") { session.skip(by: -10) }
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.45), in: Circle())
                    Button("播放或暂停", systemImage: playbackIsActive ? "pause.fill" : "play.fill") {
                        session.togglePlayback()
                    }
                    .font(.system(size: 25, weight: .semibold))
                    .frame(width: 72, height: 52)
                    .background(.black.opacity(0.48), in: Capsule())
                    Button("前进 10 秒", systemImage: "goforward.10") { session.skip(by: 10) }
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.45), in: Circle())
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 22))

                HStack(spacing: 22) {
                    Menu {
                        trackControls
                    } label: {
                        Label("字幕与音轨", systemImage: "captions.bubble")
                    }
                    Menu {
                        Menu("播放内核") {
                            ForEach(PlaybackEnginePreference.allCases, id: \.self) { preference in
                                Button {
                                    session.selectEnginePreference(preference)
                                } label: {
                                    if session.enginePreference == preference {
                                        Label(preference.title, systemImage: "checkmark")
                                    } else {
                                        Text(preference.title)
                                    }
                                }
                            }
                        }
                        advancedControls
                        if !session.segments.isEmpty {
                            Button(session.autoSkipSegments ? "关闭自动跳过片段" : "开启自动跳过片段") {
                                session.autoSkipSegments.toggle()
                            }
                        }
                    } label: {
                        Label("播放设置", systemImage: "gearshape")
                    }
                }
                .labelStyle(.iconOnly)
                .font(.system(size: 20))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .buttonStyle(.plain)
            .frame(height: 56)
        }
        .padding(.horizontal, 28)
        .padding(.top, 16)
        .padding(.bottom, 18)
        .background(.linearGradient(colors: [.clear, .black.opacity(0.72), .black.opacity(0.92)],
                                    startPoint: .top, endPoint: .bottom))
    }

    private var playbackIsActive: Bool {
        if session.useMPV { return session.mpvEngine?.isPlaying == true }
        #if canImport(VLCKit)
        if session.useVLC { return session.vlcPlayer.isPlaying }
        #endif
        return session.player.timeControlStatus == .playing
    }

    private var seekTrack: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let rawFraction = (isSeeking ? seekPosition : session.currentTime) / max(1, session.duration)
            let fraction = rawFraction.isFinite ? min(1, max(0, rawFraction)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.24)).frame(height: 4)
                Capsule().fill(.white).frame(width: max(0, width * fraction), height: 4)
                Capsule().fill(.white).frame(width: 7, height: 17)
                    .offset(x: min(width - 7, max(0, width * fraction - 3.5)))
            }
            .frame(height: 42)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    isSeeking = true
                    seekPosition = min(1, max(0, value.location.x / width)) * session.duration
                    session.preview(at: seekPosition)
                }
                .onEnded { _ in
                    session.seek(to: seekPosition)
                    session.clearPreview()
                    isSeeking = false
                })
            #endif
        }
        .frame(height: 42)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.timeLabel(session.currentTime))，共 \(Self.timeLabel(session.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.skip(by: 10)
            case .decrement: session.skip(by: -10)
            @unknown default: break
            }
        }
    }

    private func roundControl(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly)
            .font(.system(size: 21, weight: .regular))
            .frame(width: 48, height: 48)
            .background(.black.opacity(0.48), in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.08)))
    }

    private func skipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .font(.system(size: 13, weight: .medium))
            .padding(.horizontal, 18)
            .frame(height: 30)
            .background(.white.opacity(0.12), in: Capsule())
    }

    @ViewBuilder private var trackControls: some View {
        if !session.audioOptions.isEmpty {
            Menu("音轨") {
                ForEach(session.audioOptions.indices, id: \.self) { index in
                    Button(session.audioOptions[index]) { session.selectAudio(index) }
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
        if session.hasSidecarSubtitle {
            Button(session.subtitlesEnabled ? "关闭外挂字幕" : "开启外挂字幕") {
                session.toggleSidecarSubtitle()
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
        if session.audioOptions.isEmpty && session.subtitleOptions.isEmpty && !session.hasSidecarSubtitle
            && session.serverTracks.audio.isEmpty && session.serverTracks.subtitles.isEmpty {
            Text("当前影片没有可切换的音轨或字幕")
        }
    }

    @ViewBuilder private var advancedControls: some View {
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
                if case .embyItem = item.location {
                    Menu("尝试 Emby 转码") {
                        ForEach([2, 5, 8, 12, 20], id: \.self) { megabits in
                            Button("请求码率上限 \(megabits) Mbps") {
                                session.selectEmbyTranscodeBitrate(megabits * 1_000_000)
                            }
                        }
                    }
                }
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
    }

    private struct PlaybackDiagnosticsPanel: View {
        let report: PlaybackDiagnostics
        let buffering: Bool
        let stalls: Int
        let failure: String?
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(report.engine.rawValue).font(.title2.bold())
                            Text(report.routeReason).font(.subheadline).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))

                        detail("播放方式", report.delivery)
                        detail("容器", report.container)
                        detail("视频编码", report.videoCodec)
                        detail("音频编码", report.audioCodec)
                        detail("分辨率", report.resolution)
                        detail("动态范围", report.dynamicRange)
                        if let explanation = report.dolbyVisionExplanation {
                            Text(explanation).font(.subheadline)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(14)
                                .background(.yellow.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 12))
                        }
                        detail("缓冲状态", buffering ? "正在缓冲" : "正常")
                        detail("中断次数", String(stalls))
                        if let failure { Text(failure).foregroundStyle(.red) }
                    }
                    .frame(maxWidth: 520, alignment: .leading)
                    .padding(22)
                    .frame(maxWidth: .infinity)
                }
                .navigationTitle("播放信息")
                .toolbar { Button("完成") { dismiss() } }
            }
            .frame(minWidth: 360, minHeight: 470)
        }

        private func detail(_ title: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Text(title).foregroundStyle(.secondary)
                Spacer()
                #if os(tvOS)
                Text(value).multilineTextAlignment(.trailing)
                #else
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
                #endif
            }
            .font(.subheadline)
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
