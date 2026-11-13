import AVKit
import Combine
import SwiftUI
import LucentAether

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
    @Published var message: String? {
        didSet {
            if let message, message != oldValue {
                handoverTrace("failure: \(EngineLog.redacted(message))")
            }
        }
    }
    @Published var playbackRate: Float = 1
    @Published var preferredPeakBitRate: Double = 0
    @Published var subtitleText = ""
    @Published private(set) var subtitleBitmap: CGImage?
    @Published private(set) var subtitleBitmapPosition = CGRect.zero
    @Published var hasSidecarSubtitle = false
    @Published var subtitlesEnabled = true
    @Published var subtitleDelay: Double = 0
    @Published var audioOptions: [String] = []
    @Published private(set) var selectedAudioIndex: Int?
    @Published var subtitleOptions: [String] = []
    @Published private(set) var selectedSubtitleIndex: Int?
    @Published private(set) var subtitleNotice: String?
    @Published private(set) var pendingSubtitleIndex: Int?
    @Published private(set) var dolbyVisionDetected = false
    @Published private(set) var diagnostics = PlaybackDiagnostics()
    @Published private(set) var seekPreview: CGImage?
    @Published private(set) var seekPreviewLoading = false
    @Published private(set) var seekPreviewTime: Double?
    @Published private(set) var seekPreviewUnavailable = false
    @Published private(set) var manualIntroEnd: Double?
    @Published private(set) var manualCreditsStart: Double?
    @Published private(set) var manualCreditsDuration: Double?
    @Published private(set) var playlistEntries: [PlaylistResolver.Entry] = []
    @Published private(set) var currentPlaylistIndex = 0
    @Published private(set) var segments: [PlaybackSegment] = []
    @Published var autoSkipSegments = UserDefaults.standard.object(forKey: "lucent.autoSkipSegments") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoSkipSegments, forKey: "lucent.autoSkipSegments") }
    }
    @Published private(set) var chapters: [PlaybackChapter] = []
    @Published var didFinish = false
    @Published private(set) var completionReached = false
    @Published var isBuffering = false
    @Published private(set) var isSeekingPlayback = false
    private var seekGeneration = UUID()
    @Published private(set) var isPreparing = true
    @Published var stallCount = 0
    @Published var useMPV = false
    @Published var useAether = false
    @Published private(set) var switchingToAether = false
    @Published private(set) var aetherTransitionOpacity = 0.0
    @Published private(set) var aetherAVPlayer: AVPlayer?
    @Published private(set) var aetherUsesSoftwareSurface = false
    @Published private(set) var aetherInitialLoadPending = false
    var aetherSurfaceReady = false
    @Published private(set) var mpvVideoReady = false
    @Published private(set) var mpvTransitionOpacity = 1.0
    @Published private(set) var enginePreference: PlaybackEnginePreference = .automatic
    @Published private(set) var engineSwitchTarget: PlaybackEnginePreference?
    @Published private(set) var engineSwitchNotice: String?
    private var engineSwitchNoticeTask: Task<Void, Never>?
    var activeEngineTitle: String {
        if useMPV && (!useAether || switchingToAether) { return "MPV" }
        if useAether && aetherUsesSoftwareSurface { return "AetherEngine" }
        return "AVPlayer"
    }
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    /// Furthest media position the active engine has buffered, for the seek bar's loading range.
    @Published private(set) var bufferedTime: Double = 0
    let player = AVPlayer()
    private var mpvEngineStorage: MPVPlaybackEngine?
    @Published private(set) var videoScaleMode = VideoScaleMode(
        rawValue: UserDefaults.standard.string(forKey: "lucent.player.videoScaleMode") ?? "fit") ?? .fit
    var mpvEngine: MPVPlaybackEngine? {
        if mpvEngineStorage == nil {
            mpvEngineStorage = MPVPlaybackEngine()
            mpvEngineStorage?.setVideoScaleMode(videoScaleMode)
        }
        return mpvEngineStorage
    }
    private var mpvTimer: Timer?
    private var aetherEngineStorage: AetherEngine?
    private var aetherRoutingLog: [String] = []
    var aetherEngine: AetherEngine? {
        if aetherEngineStorage == nil {
            EngineLog.handler = { [weak self] line in
                #if DEBUG
                if ProcessInfo.processInfo.environment["LUCENT_TRANSPORT_TRACE"] == "1" {
                    NSLog("Lucent engine %@", line)
                }
                #endif
                guard line.contains("[Lucent]") || line.contains("[MPV]") || line.contains("[AetherEngine]") || line.contains("[HLSVideoEngine]") ||
                        line.localizedCaseInsensitiveContains("dolby") ||
                        line.localizedCaseInsensitiveContains("probe") else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.aetherRoutingLog.append(line)
                    if self.aetherRoutingLog.count > 160 { self.aetherRoutingLog.removeFirst() }
                    if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        try? self.aetherRoutingLog.joined(separator: "\n").write(
                            to: folder.appendingPathComponent("AetherRouting.log"),
                            atomically: true, encoding: .utf8)
                    }
                }
            }
            aetherEngineStorage = try? AetherEngine()
            aetherEngineStorage?.videoGravity = videoScaleMode.videoGravity
        }
        return aetherEngineStorage
    }
    private var aetherTimer: Timer?
    private var aetherLoadTask: Task<Void, Never>?
    private var nativeDiagnosticsTask: Task<Void, Never>?
    private var nativeDiagnosticsItemID: ObjectIdentifier?
    private var nativeDiagnosticsAudioIndex: Int?
    private var mpvTransitionTask: Task<Void, Never>?
    private var parkedRetirementTask: Task<Void, Never>?
    private let transitionCoordinator = PlaybackTransitionCoordinator()
    @Published private(set) var playbackRequested = true {
        didSet { transitionCoordinator.setIntent(playbackRequested) }
    }
    private var handoverGeneration: UUID { transitionCoordinator.generation }
    private var queuedEnginePreference: PlaybackEnginePreference?
    private var handoverLanding: Double? {
        get { transitionCoordinator.landing }
        set { transitionCoordinator.landing = newValue }
    }
    private var pendingMPVSubtitleStreamIndex: Int?
    private var mpvResumePosition: Double = 0
    private var mpvAttachedSubtitle = false
    private var mpvAttachedAudio = false
    private var activePlaybackURL: URL?
    private var embyAetherProxyURL: URL?
    private var retriedEmbyAetherProxy = false
    private var activeDolbyVisionProfile: Int?
    private var forcedMPVForCurrentPlayback = false
    private var nativeSubtitleURL: URL?
    private var externalAudioURL: URL?
    private var temporarySubtitleURL: URL?
    private var timeObserver: Any?
    private var scopedURL: URL?
    private var smbServer: RangeHTTPServer?
    private var loadingTask: Task<Void, Never>?
    private var subtitleTask: Task<Void, Never>?
    private var subtitleDeliveryTask: Task<Void, Never>?
    private var subtitleSelectionTask: Task<Void, Never>?
    private var subtitleSelectionGeneration = UUID()
    private var subtitleDeliveries: [EmbyClient.SubtitleDelivery] = []
    private var subtitleDeliveryContext: (address: String, token: String)?
    private var serverSubtitleChoices: [Int: EmbyClient.SubtitleDelivery] = [:]
    private var serverSubtitleCache: [Int: [SubtitleCue]] = [:]
    private var activeServerSubtitleID: Int?
    private var subtitleCues: [SubtitleCue] = []
    private var audioGroup: AVMediaSelectionGroup?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var tracksTask: Task<Void, Never>?
    private var nativeInspectionTask: Task<Void, Never>?
    private var seekPreviewTask: Task<Void, Never>?
    private var previewGeneration = UUID()
    private var previewRequested: Double?
    private var userIsScrubbing = false
    private var previewPending: Double?
    private var previewExtractor: FrameExtractor?
    private var previewExtractorURL: URL?
    private var previewCache: [Int: CGImage] = [:]
    private var previewCacheOrder: [Int] = []
    private var segmentTask: Task<Void, Never>?
    private var lastSkippedSegmentID: String?
    private var endObserver: NSObjectProtocol?
    private var playbackErrorObserver: NSObjectProtocol?
    private var playerItemStatusObservation: NSKeyValueObservation?
    private var stallObserver: NSObjectProtocol?
    private var lastProgressSave = Date.distantPast
    private var resumeOverride: Double?
    private var progressTracker: PlaybackProgressTracker
    private var isClosed = false
    private var sourceLoadGeneration = UUID()
    private let item: MediaItem
    private let serverMediaSourceID: String?
    private var activeEmbyMediaSourceID: String?
    private let serverContainer: String?
    private let serverDolbyVision: Bool
    private var activeVideoCodecTag: String?
    private var mediaFeatures: PlaybackMediaFeatures
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
        self.manualIntroEnd = item.skipIntroEnd
        self.manualCreditsStart = item.skipCreditsStart
        self.manualCreditsDuration = item.skipCreditsDuration
        self.progressTracker = PlaybackProgressTracker(initialPosition: item.resumePosition)
        if let knownDuration = item.duration, knownDuration.isFinite, knownDuration > 0 {
            self.duration = knownDuration
        }
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
        #if DEBUG
        if ProcessInfo.processInfo.environment["LUCENT_PLAYBACK_AUDIT"] == "1" {
            #if os(iOS)
            if ProcessInfo.processInfo.environment["LUCENT_TRANSPORT_TRACE"] == "1" {
                AVPlayer.enableLucentTransportAudit()
            }
            #endif
            enginePreference = PlaybackEnginePreference(rawValue:
                ProcessInfo.processInfo.environment["LUCENT_AUDIT_INITIAL_ENGINE"] ?? "automatic") ?? .automatic
        }
        #endif
    }

    func start(library: LibraryStore) {
        guard timeObserver == nil, loadingTask == nil, mpvTimer == nil,
              aetherTimer == nil else { return }
        isClosed = false
        sourceLoadGeneration = UUID()
        isPreparing = true
        self.library = library
        if let latest = library.items.first(where: { $0.id == item.id }) {
            manualIntroEnd = latest.skipIntroEnd
            manualCreditsStart = latest.skipCreditsStart
            manualCreditsDuration = latest.skipCreditsDuration
        }
        // A detail view can retain an old item snapshot after returning from
        // playback. Honor the newer local state, including an intentional rewind.
        if let latest = library.items.first(where: { $0.id == item.id }),
           (latest.stateUpdatedAt ?? .distantPast) > (item.stateUpdatedAt ?? .distantPast) {
            progressTracker = PlaybackProgressTracker(initialPosition: latest.resumePosition)
        }
        if let resumeOverride { progressTracker.beginLoad(at: resumeOverride) }
        currentTime = progressTracker.recoveryPosition
        #if DEBUG
        PlaybackLogHistory.archiveLatest()
        #endif
        handoverTrace("session start item=\(item.id) saved=\(item.position) watched=\(item.watched) resume=\(progressTracker.recoveryPosition)")
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
            let server = RangeHTTPServer(fileExtension: (path as NSString).pathExtension,
                                         cacheKey: "webdav|\(sourceID)|\(path)") { offset, length in
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
            let server = RangeHTTPServer(fileExtension: serverContainer ?? item.serverFileExtension ?? "mp4",
                                         cacheKey: "jellyfin|\(sourceID)|\(itemID)|\(serverMediaSourceID ?? "default")") { offset, length in
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
            let generation = sourceLoadGeneration
            loadingTask = Task { [weak self] in
                defer {
                    if self?.sourceLoadGeneration == generation { self?.loadingTask = nil }
                }
                var activeServer: RangeHTTPServer?
                do {
                    let versions = try? await EmbyClient.versions(source: source, token: token, itemID: itemID)
                    guard !Task.isCancelled, let self, self.sourceLoadGeneration == generation else { return }
                    let selected = versions?.first(where: { $0.id == self.serverMediaSourceID })
                        ?? versions?.first
                    if let selected { self.mediaFeatures.merge(selected.playbackFeatures) }
                    self.activeVideoCodecTag = selected?.mediaStreams?.first(where: {
                        $0.type?.caseInsensitiveCompare("Video") == .orderedSame
                    })?.codecTag
                    let mediaSourceID = self.serverMediaSourceID ?? selected?.id
                    self.activeEmbyMediaSourceID = mediaSourceID
                    if let mediaSourceID {
                        self.loadSubtitleDeliveries(source: source, token: token,
                                                    itemID: itemID, mediaSourceID: mediaSourceID)
                    }
                    let declaredContainer = selected?.container ?? self.serverContainer
                        ?? self.item.serverFileExtension ?? "mp4"
                    // A STRM entry names a link, not the linked video's container.
                    // Expose it as an opaque stream so MPV probes the actual bytes.
                    let container = declaredContainer.lowercased() == "strm" ? "bin" : declaredContainer
                    let server = RangeHTTPServer(fileExtension: container,
                        cacheKey: "emby|\(sourceID)|\(itemID)|\(mediaSourceID ?? "default")",
                        maxReadAttempts: 1,
                        blockLength: 1_048_576,
                        readRange: { offset, length in
                            try EmbyClient.readRange(source: source, token: token, itemID: itemID,
                                                     offset: offset, length: length,
                                                     mediaSourceID: mediaSourceID)
                        }, onReadFailure: { [weak self] error in
                            Task { @MainActor [weak self] in
                                guard let self, self.sourceLoadGeneration == generation,
                                      self.smbServer != nil else { return }
                                let detail = PlaybackDiagnosticPrivacy.removingMediaURLs(from: error.localizedDescription)
                                self.directPlaybackFailure = detail
                                self.handoverTrace("Emby range read failed: \(detail)")
                            }
                        })
                    activeServer = server
                    self.smbServer = server
                    let url = try await server.start()
                    guard !Task.isCancelled else { server.stop(); return }
                    self.embyAetherProxyURL = url
                    let direct = EmbyClient.directPlaybackURL(
                        source: source, token: token, itemID: itemID,
                        mediaSourceID: mediaSourceID, container: container)
                    if self.enginePreference != .mpv, let direct {
                        self.play(url: direct)
                    } else {
                        self.play(url: url)
                    }
                } catch {
                    activeServer?.stop()
                    guard !Task.isCancelled, self?.sourceLoadGeneration == generation else { return }
                    self?.message = "无法播放 Emby 视频：\(error.localizedDescription)"
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
            let server = RangeHTTPServer(fileExtension: (partKey as NSString).pathExtension,
                                         cacheKey: "plex|\(sourceID)|\(partKey)") { offset, length in
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
                                                 cacheKey: "cloud|\(sourceID)|\(identifier)",
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

    private func play(url: URL, probe: SourceProbe? = nil, probeAttempted: Bool = false) {
        guard !isClosed else { return }
        // File suffixes do not establish native compatibility: MP4 can contain hev1.
        // Inspect only the title being opened, using AVFoundation and the existing
        // Range cache; this is independent of optional library-wide FFmpeg indexing.
        if !probeAttempted, enginePreference != .mpv, !forcedMPVForCurrentPlayback,
           PlaybackNativeInspection.requiresInspection(url: url, features: mediaFeatures) {
            nativeInspectionTask?.cancel()
            isPreparing = true
            let generation = sourceLoadGeneration
            let asset = AVURLAsset(url: url)
            nativeInspectionTask = Task { [weak self] in
                let info = await withTaskCancellationHandler {
                    await NativePlaybackMediaInfo.read(asset: asset, selectedAudioSubtype: nil)
                } onCancel: { asset.cancelLoading() }
                guard !Task.isCancelled, let self, !self.isClosed, self.sourceLoadGeneration == generation else { return }
                self.nativeInspectionTask = nil
                self.mediaFeatures.videoCodec = info.videoCodec ?? self.mediaFeatures.videoCodec
                self.mediaFeatures.videoCodecTag = info.videoCodecTag ?? self.mediaFeatures.videoCodecTag
                self.mediaFeatures.dynamicRange = info.dynamicRange ?? self.mediaFeatures.dynamicRange
                self.mediaFeatures.resolution = info.resolution ?? self.mediaFeatures.resolution
                self.mediaFeatures.audioCodec = info.audioCodec ?? self.mediaFeatures.audioCodec
                self.activeVideoCodecTag = info.videoCodecTag ?? self.activeVideoCodecTag
                EngineLog.emit("[Lucent] native track inspection codec=\(info.videoCodec ?? "unknown") tag=\(info.videoCodecTag ?? "unknown")")
                self.play(url: url, probe: probe, probeAttempted: true)
            }
            return
        }
        let retireParkedMPV = mpvEngineStorage?.isParked == true || parkedRetirementTask != nil
        prepareForReplacement()
        isPreparing = true
        if retireParkedMPV, let oldMPV = mpvEngineStorage {
            // Changing source is a cold load, not a handover. Release the warm
            // MPV fully before a new route can activate its audio session.
            let generation = handoverGeneration
            activePlaybackURL = url
            parkedRetirementTask = Task { [weak self] in
                do {
                    try await oldMPV.stopAndWait()
                    try Task.checkCancellation()
                    guard let self, self.handoverGeneration == generation else { return }
                    self.parkedRetirementTask = nil
                    self.play(url: url, probe: probe, probeAttempted: probeAttempted)
                } catch {
                    guard !Task.isCancelled, let self, self.handoverGeneration == generation else { return }
                    self.parkedRetirementTask = nil
                    self.message = "释放上一部影片的音频输出失败：\(error.localizedDescription)"
                }
            }
            return
        }
        dolbyVisionDetected = false
        activeDolbyVisionProfile = probe?.dvProfile
        let preferNativeDolbyVision = serverDolbyVision &&
            DolbyVisionSupport.isApplePlaybackContainer(url.pathExtension)
        if enginePreference == .system && preferNativeDolbyVision,
           let subtitleURL = nativeSubtitleURL,
           ["ass", "ssa"].contains(subtitleURL.pathExtension.lowercased()),
           let data = try? Data(contentsOf: subtitleURL) {
            subtitleCues = SubtitleParser.parse(data, fileExtension: subtitleURL.pathExtension)
            nativeSubtitleURL = nil
        }
        var routeFeatures = mediaFeatures
        routeFeatures.videoCodecTag = activeVideoCodecTag ?? mediaFeatures.videoCodecTag
        let decision = PlaybackRouteDecision.choose(
            preference: enginePreference, url: url, features: routeFeatures,
            hasStyledSubtitle: nativeSubtitleURL != nil ||
                (subtitleStreamIndex.map { mediaFeatures.styledSubtitleStreamIndices.contains($0) } ??
                 mediaFeatures.defaultStyledSubtitle),
            hasExternalAudio: externalAudioURL != nil,
            serverDolbyVision: serverDolbyVision)
        let hasStyledSubtitle = nativeSubtitleURL != nil ||
            (subtitleStreamIndex.map { mediaFeatures.styledSubtitleStreamIndices.contains($0) } ??
             mediaFeatures.defaultStyledSubtitle)
        let probedAudio = probe?.audioTracks.first(where: \.isDefault)?.codec ?? probe?.audioTracks.first?.codec
        let detectedDolbyVision = serverDolbyVision || probe?.isDolbyVision == true
        // AetherEngine can remux these containers into a native AVPlayer HLS
        // session. Let it inspect the actual bitstream before falling back to
        // MPV; Emby metadata can omit the Dolby Vision flag (notably for MKV).
        let aetherContainer = ["mkv", "ts", "m2ts", "mts", "webm", "bin"]
            .contains(url.pathExtension.lowercased())
        let unsupportedNativeCodec = ["vc1", "vc-1", "mpeg2video", "mpeg2", "mpeg-2"]
            .contains((mediaFeatures.videoCodec ?? "").lowercased())
        let requiresHEVCRemux = decision.useAether && transcodeBitrate == nil && automaticTranscodeBitrate == nil
        let nativeEnhancedRoute = enginePreference != .mpv && !forcedMPVForCurrentPlayback &&
            externalAudioURL == nil && !unsupportedNativeCodec &&
            (detectedDolbyVision || aetherContainer || requiresHEVCRemux ||
             (probeAttempted && mediaFeatures.videoCodecTag == nil && ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())) ||
             (!hasStyledSubtitle && ["truehd", "mlp", "dts", "dts-hd", "dca"]
                .contains((mediaFeatures.audioCodec ?? probedAudio ?? "").lowercased())))
        let mpvRoute = !nativeEnhancedRoute && (decision.useMPV || forcedMPVForCurrentPlayback)
        var report = PlaybackDiagnostics()
        report.engine = nativeEnhancedRoute ? .aether : (mpvRoute ? .mpv : .native)
        if transcodeBitrate != nil || automaticTranscodeBitrate != nil {
            report.delivery = "服务器转码 HLS"
        } else if case .embyItem = item.location {
            report.delivery = url == embyAetherProxyURL ? "Emby · 本机 Range 代理" : "Emby · 服务器地址直连"
        } else {
            switch item.location {
            case .bookmark, .folderFile: report.delivery = "本地文件"
            case .remote: report.delivery = "网络地址直连"
            default: report.delivery = "远程文件直连"
            }
        }
        if transcodeBitrate == nil && automaticTranscodeBitrate == nil {
            report.apply(mediaFeatures)
            if report.container == "待识别",
               let container = MediaInfoLabels.container(serverContainer) ?? MediaInfoLabels.container(url.pathExtension) {
                report.container = container
            }
        } else { report.container = "HLS" }
        report.requestedDolbyVision = detectedDolbyVision ||
            mediaFeatures.dynamicRange?.lowercased().contains("dolby") == true
        report.detectedDolbyVision = probe?.isDolbyVision == true
        report.routeReason = automaticTranscodeBitrate != nil ? "已手动选择 Emby 转码画质" :
            transcodeBitrate != nil ? "已选择服务器转码画质" :
            forcedMPVForCurrentPlayback ? "原生内核失败，自动改用 MPV 重试" :
            nativeEnhancedRoute && probe?.dvProfile == 5 ?
                "AetherEngine 杜比视界 P5：由系统读取片源色彩信息" :
            nativeEnhancedRoute ? (decision.useAether ? decision.reason : "AetherEngine 优先尝试原生视频路径") : decision.reason
        diagnostics = report
        activePlaybackURL = url
        if nativeEnhancedRoute {
            // Aether's hev1 remuxer also uses libavformat. Give it the same
            // system-network-backed file bytes that avoid the observed CDN TLS failure.
            let nativeURL = requiresHEVCRemux ? mpvPlaybackURL(url) : url
            if nativeURL == embyAetherProxyURL {
                diagnostics.delivery = "Emby · 本机 Range 代理"
                handoverTrace("Aether hev1 transport=system-range")
            }
            playWithAether(url: nativeURL)
            return
        }
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
                guard let self, self.player.currentItem === item else { return }
                if self.retryNativeFailureWithMPV(url: url) { return }
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
                guard let self, self.player.currentItem === playerItem else { return }
                if self.retryNativeFailureWithMPV(url: url) { return }
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
        let resume = consumeResumePosition()
        if resume > 0 {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, self.player.currentItem === playerItem else { return }
                self.tick(time.seconds)
            }
        }
        player.play()
        tracksTask = Task { [weak self] in
            do {
                let audio = try await playerItem.asset.loadMediaSelectionGroup(for: .audible)
                let subtitles = try await playerItem.asset.loadMediaSelectionGroup(for: .legible)
                guard !Task.isCancelled else { return }
                self?.audioGroup = audio
                self?.subtitleGroup = subtitles
                self?.audioOptions = audio?.options.map(\.displayName) ?? []
                self?.subtitleOptions = subtitles?.options.map { SubtitleLanguageDisplay.title($0.displayName, language: $0.extendedLanguageTag ?? $0.locale?.identifier) } ?? []
                if let self, self.subtitleStreamIndex == nil, !self.hasSidecarSubtitle, subtitles != nil {
                    let preferences = AVPlayerMediaSelectionCriteria(preferredLanguages: LocalizationPreferences.current.subtitleTrackLanguages,
                        preferredMediaCharacteristics: nil)
                    self.player.setMediaSelectionCriteria(preferences, forMediaCharacteristic: .legible)
                }
                if self?.audioStreamIndex == nil, !LocalizationPreferences.current.audioTrackLanguages.isEmpty {
                    self?.player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(
                        preferredLanguages: LocalizationPreferences.current.audioTrackLanguages,
                        preferredMediaCharacteristics: nil), forMediaCharacteristic: .audible)
                }
                let groups = try await playerItem.asset.loadChapterMetadataGroups(
                    bestMatchingPreferredLanguages: [LocalizationPreferences.current.contentLanguage])
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

    private func retryNativeFailureWithMPV(url: URL) -> Bool {
        guard enginePreference == .automatic, !forcedMPVForCurrentPlayback,
              activePlaybackURL == url else { return false }
        let position = player.currentTime().seconds
        resumeOverride = position.isFinite && position > 0 ? position : progressTracker.recoveryPosition
        forcedMPVForCurrentPlayback = true
        message = nil
        play(url: url)
        return true
    }

    func selectPlaylistEntry(_ entry: PlaylistResolver.Entry) {
        forcedMPVForCurrentPlayback = false
        currentPlaylistIndex = entry.index
        segments = []
        lastSkippedSegmentID = nil
        resumeOverride = 0
        play(url: entry.url)
    }

    private func finishCurrentPlayback() {
        guard !didFinish else { return }
        let next = currentPlaylistIndex + 1
        if playlistEntries.indices.contains(next) {
            selectPlaylistEntry(playlistEntries[next])
        } else {
            completionReached = true
            library?.markWatched(id: item.id)
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

    var effectiveSegments: [PlaybackSegment] {
        PlaybackSkipRules.resolved(server: segments, introEnd: manualIntroEnd,
            creditsStart: manualCreditsStart, creditsDuration: manualCreditsDuration, duration: duration)
    }
    var activeSkipSegment: PlaybackSegment? { PlaybackSkipRules.active(in: effectiveSegments, at: currentTime) }
    func setManualSkipTimes(intro: Double?, credits: Double?) {
        manualIntroEnd = intro; manualCreditsDuration = credits; manualCreditsStart = nil
        lastSkippedSegmentID = nil
    }
    func skipSegment(_ segment: PlaybackSegment) {
        lastSkippedSegmentID = segment.id
        seek(to: duration > 0 ? min(segment.end, max(0, duration - 0.1)) : segment.end)
    }
    private func applyAutomaticSkip(at seconds: Double) {
        guard autoSkipSegments, playbackRequested, !userIsScrubbing, !isPreparing, !isBuffering,
              !isSeekingPlayback, engineSwitchTarget == nil, !didFinish,
              let segment = PlaybackSkipRules.active(in: effectiveSegments, at: seconds),
              segment.id != lastSkippedSegmentID else { return }
        skipSegment(segment)
    }

    var selectedServerAudioID: Int? { audioStreamIndex }
    var selectedServerSubtitleID: Int? { subtitleStreamIndex }

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
        nativeInspectionTask?.cancel()
        nativeInspectionTask = nil
        parkedRetirementTask?.cancel()
        parkedRetirementTask = nil
        nativeDiagnosticsTask?.cancel()
        nativeDiagnosticsTask = nil
        nativeDiagnosticsItemID = nil
        nativeDiagnosticsAudioIndex = nil
        subtitleBitmap = nil
        seekGeneration = UUID()
        isSeekingPlayback = false
        isBuffering = false
        playerItemStatusObservation = nil
        resetPreview()
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
        transitionCoordinator.invalidate()
        handoverLanding = nil
        mpvTransitionTask?.cancel()
        engineSwitchTarget = nil
        engineSwitchNoticeTask?.cancel()
        engineSwitchNotice = nil
        queuedEnginePreference = nil
        switchingToAether = false
        mpvTransitionTask = nil
        pendingMPVSubtitleStreamIndex = nil
        mpvTransitionOpacity = 1
        aetherLoadTask?.cancel()
        aetherLoadTask = nil
        aetherTimer?.invalidate()
        aetherTimer = nil
        if useAether { aetherEngineStorage?.stop() }
        useAether = false
        aetherAVPlayer = nil
        aetherUsesSoftwareSurface = false
        aetherInitialLoadPending = false
        aetherSurfaceReady = false
        // A warm, parked MPV still owns this source even while native is active.
        mpvEngineStorage?.stop()
        useMPV = false
        mpvVideoReady = false
        mpvAttachedSubtitle = false
        mpvAttachedAudio = false
        chapters = []
        bufferedTime = 0
        audioOptions = []
        selectedAudioIndex = nil
        subtitleOptions = []
        selectedSubtitleIndex = nil
        didFinish = false
    }

    func preview(at seconds: Double) {
        guard seconds.isFinite, seconds >= 0, !isClosed else { return }
        userIsScrubbing = true
        guard UserDefaults.standard.object(forKey: "lucent.player.seekPreview") as? Bool ?? true else { return }
        let target = duration > 0 ? min(seconds, max(0, duration - 0.1)) : seconds
        let key = Int(target / 2)
        previewRequested = target
        if let cached = previewCache[key] {
            seekPreview = cached; seekPreviewTime = target; seekPreviewLoading = false; seekPreviewUnavailable = false
            previewPending = nil
            return
        }
        previewPending = target
        seekPreviewLoading = true
        seekPreviewUnavailable = false
        guard seekPreviewTask == nil else { return }
        let generation = previewGeneration
        seekPreviewTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.previewGeneration == generation { self.seekPreviewTask = nil; self.seekPreviewLoading = false }
            }
            while !Task.isCancelled, self.previewGeneration == generation, let target = self.previewPending {
                self.previewPending = nil
                let image = await self.extractPreview(at: target)
                guard !Task.isCancelled, self.previewGeneration == generation else { return }
                let key = Int(target / 2)
                if let image {
                    self.previewCache[key] = image
                    self.previewCacheOrder.removeAll { $0 == key }
                    self.previewCacheOrder.append(key)
                    while self.previewCacheOrder.count > 40 { self.previewCache.removeValue(forKey: self.previewCacheOrder.removeFirst()) }
                }
                let matchesTarget = self.previewRequested.map { Int($0 / 2) == key } ?? false
                if let image, matchesTarget || self.previewPending != nil {
                    // Publish useful intermediate frames during continuous dragging; label their
                    // approximate requested timestamp instead of claiming they match the latest target.
                    self.seekPreview = image
                    self.seekPreviewTime = target
                }
                if matchesTarget {
                    self.seekPreview = image
                    if image == nil { self.seekPreviewTime = nil }
                    self.seekPreviewUnavailable = image == nil
                    self.seekPreviewLoading = false
                }
                // Coalesce all input events during extraction; do not debounce forever while dragging.
                if self.previewPending != nil { try? await Task.sleep(for: .milliseconds(100)) }
            }
        }
    }

    private func extractPreview(at seconds: Double) async -> CGImage? {
        guard !isPreparing, !isBuffering, !isSeekingPlayback, engineSwitchTarget == nil else { return nil }
        if useAether, let engine = aetherEngineStorage,
           let cached = await engine.scrubThumbnail(atSeconds: seconds, maxWidth: 320) { return cached }
        guard !Task.isCancelled, let url = activePlaybackURL else { return nil }
        let previewURL = useMPV ? mpvPlaybackURL(url) : url
        if previewExtractorURL != previewURL || previewExtractor == nil {
            if let previous = previewExtractor { Task { await previous.shutdown() } }
            previewExtractorURL = previewURL
            if useAether, let engine = aetherEngineStorage {
                previewExtractor = engine.makeFrameExtractor() ?? engine.makeFrameExtractor(url: previewURL)
            } else { previewExtractor = FrameExtractor(url: previewURL) }
        }
        return await previewExtractor?.thumbnail(at: seconds, maxWidth: 320)
    }

    func clearPreview() {
        userIsScrubbing = false
        previewGeneration = UUID()
        seekPreviewTask?.cancel(); seekPreviewTask = nil
        previewPending = nil; previewRequested = nil
        seekPreviewLoading = false; seekPreviewUnavailable = false; seekPreview = nil; seekPreviewTime = nil
        if let extractor = previewExtractor { Task { await extractor.shutdown() } }
        previewExtractor = nil; previewExtractorURL = nil
    }
    private func resetPreview() {
        clearPreview()
        previewCache.removeAll(); previewCacheOrder.removeAll()
    }

    private static func usesNativeSubtitle(_ fileExtension: String) -> Bool {
        ["ass", "ssa", "sup"].contains(fileExtension.lowercased())
    }

    #if DEBUG
    private var auditLines: [String] = []
    private var auditStarted = false
    func auditSnapshot(_ event: String) {
        let native = aetherEngineStorage
        let av = native?.currentAVPlayer
        let line = "\(Date().timeIntervalSince1970) \(event) flags A=\(useAether) M=\(useMPV) reverse=\(switchingToAether) task=\(mpvTransitionTask != nil) preparing=\(isPreparing) pending=\(aetherInitialLoadPending) surface=\(aetherSurfaceReady) time=\(currentTime) native=[state=\(String(describing: native?.state)) time=\(native?.currentTime ?? -1) rate=\(av?.rate ?? -1) volume=\(native?.volume ?? -1) muted=\(av?.isMuted ?? false) delivery=\(String(describing: native?.audioDelivery))] mpv=[\(mpvEngineStorage?.diagnosticState ?? "nil")] error=\(message ?? "none")"
        auditLines.append(line)
        NSLog("Lucent audit %@", line)
        if let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? auditLines.joined(separator: "\n").write(to: folder.appendingPathComponent("PlaybackAudit.log"), atomically: true, encoding: .utf8)
        }
    }
    func runPlaybackAudit() async {
        guard !auditStarted else { return }
        auditStarted = true
        func wait(_ label: String, timeout: Int, until predicate: () -> Bool) async throws {
            for _ in 0..<timeout {
                try Task.checkCancellation()
                auditSnapshot(label)
                if predicate() { return }
                try await Task.sleep(for: .seconds(1))
            }
            throw NSError(domain: "Audit", code: 1, userInfo: [NSLocalizedDescriptionKey: "timeout \(label)"])
        }
        do {
            try await wait("startup", timeout: 90) { !self.isPreparing && self.currentTime >= 180 }
            if useMPV {
                auditSnapshot("initial MPV presented time \(mpvEngineStorage?.firstPresentedTime ?? -1)")
                guard mpvEngineStorage?.firstPresentedTime ?? -1 >= 179.75 else {
                    throw NSError(domain: "Audit", code: 4, userInfo: [NSLocalizedDescriptionKey: "MPV presented before resume position"])
                }
                selectEnginePreference(.system)
                try await wait("initial MPV to native", timeout: 60) {
                    self.useAether && !self.useMPV && self.mpvTransitionTask == nil
                }
            }
            for cycle in 1...3 {
                auditSnapshot("request MPV cycle \(cycle)")
                selectEnginePreference(.mpv)
                try await wait("wait MPV cycle \(cycle)", timeout: 45) { self.useMPV && !self.useAether && self.mpvTransitionTask == nil }
                let mpvStart = mpvEngineStorage?.time ?? 0
                try await Task.sleep(for: .seconds(3))
                auditSnapshot("check MPV progress cycle \(cycle)")
                guard let mpv = mpvEngineStorage, !mpv.isPaused, mpv.time > mpvStart + 1 else {
                    throw NSError(domain: "Audit", code: 2, userInfo: [NSLocalizedDescriptionKey: "MPV stopped after handover"])
                }
                selectEnginePreference(.system)
                try await wait("wait native cycle \(cycle)", timeout: 60) { self.useAether && !self.useMPV && self.mpvTransitionTask == nil }
                let nativeStart = aetherEngineStorage?.currentTime ?? 0
                try await Task.sleep(for: .seconds(3))
                auditSnapshot("check native progress cycle \(cycle)")
                guard let native = aetherEngineStorage, native.currentTime > nativeStart + 1,
                      native.volume > 0.5, native.currentAVPlayer?.rate ?? 0 > 0 else {
                    throw NSError(domain: "Audit", code: 3, userInfo: [NSLocalizedDescriptionKey: "native stopped or muted after handover"])
                }
            }
            auditSnapshot("PASS three round trips")
        } catch { auditSnapshot("FAIL \(error.localizedDescription)") }
    }
    #endif

    private func playWithAether(url: URL) {
        guard let engine = aetherEngine else {
            message = "AetherEngine 无法初始化。"
            return
        }
        useAether = true
        aetherInitialLoadPending = true
        let resume = consumeResumePosition()
        let layout = SpatialSpeakerLayout(rawValue:
            UserDefaults.standard.string(forKey: "lucent.playback.atmosLayout") ?? "5.1.2") ?? .l512
        let options = LoadOptions(preferDualLayerDolbyVision: true,
                                  objectAudioRendering: .apac(layout), confirmAtmos: true,
                                  preferredAudioLanguages: audioStreamIndex == nil ? LocalizationPreferences.current.audioTrackLanguages : [],
                                  preferredSubtitleLanguages: hasSidecarSubtitle || subtitleStreamIndex != nil ? [] : LocalizationPreferences.current.subtitleTrackLanguages,
                                  autoplay: false)
        aetherLoadTask = Task { [weak self] in
            do {
                _ = try await engine.load(url: url, startPosition: max(0, resume), options: options)
                guard !Task.isCancelled, self?.useAether == true else { return }
                self?.aetherAVPlayer = engine.currentAVPlayer
                try await self?.waitForAetherSession(engine)
                if resume > 0 { await engine.seek(to: resume) }
                try await self?.waitForAetherSession(engine)
                guard !Task.isCancelled, self?.useAether == true else { return }
                self?.activeDolbyVisionProfile = engine.sourceDVProfile
                engine.volume = 1
                if self?.playbackRequested == true {
                    engine.play()
                    engine.setRate(self?.playbackRate ?? 1)
                }
                let deadline = Date().addingTimeInterval(15)
                var resumePictureReady = false
                while Date() < deadline {
                    try Task.checkCancellation()
                    let pictureAtResume = engine.sourceTime >= max(0, resume - 0.2)
                    let surfaceReady = self?.aetherUsesSoftwareSurface == true ? engine.hasFirstFrameReadyForDisplay : self?.aetherSurfaceReady == true
                    if surfaceReady && pictureAtResume { resumePictureReady = true; break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                guard !Task.isCancelled, self?.useAether == true else { return }
                guard resumePictureReady else {
                    throw NSError(domain: "Lucent.Resume", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "未能定位到继续播放的位置，已保留原播放进度。"])
                }
                self?.aetherInitialLoadPending = false
                self?.handoverTrace("initial native reveal sourceTime=\(engine.sourceTime) requested=\(resume)")
                self?.tickAether()
            } catch {
                guard !Task.isCancelled, let self, self.useAether else { return }
                self.fallbackAetherToMPV(url: url, reason: error.localizedDescription)
            }
        }
        aetherTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickAether() }
        }
    }

    private func tickAether() {
        guard useAether, let engine = aetherEngineStorage else { return }
        guard !switchingToAether else { return }
        if mpvTransitionTask != nil && handoverLanding != nil { return }
        refreshAetherDiagnostics(engine)
        // The live profile can arrive after dispatch. A successful software
        // load is not a valid success for IPT-only P5. Retry through our sized,
        // seekable Range source before presenting incorrectly coloured frames.
        if engine.videoRoute == .software, engine.sourceDVProfile == 5 {
            if !retriedEmbyAetherProxy, let proxy = embyAetherProxyURL,
               activePlaybackURL != proxy {
                retriedEmbyAetherProxy = true
                resumeOverride = progressTracker.recoveryPosition
                play(url: proxy)
                return
            }
            engine.pause()
            message = "杜比视界 P5 被分配到不兼容的软件画面路径，已暂停以避免偏色。"
            return
        }
        if aetherAVPlayer !== engine.currentAVPlayer {
            aetherAVPlayer = engine.currentAVPlayer
        }
        let usesSoftwareSurface = engine.videoRoute == .software
        let nativeOutput = engine.videoRoute == .loopback || engine.videoRoute == .remoteBypass
        if diagnostics.nativeVideoOutput != nativeOutput { diagnostics.nativeVideoOutput = nativeOutput }
        if aetherUsesSoftwareSurface != usesSoftwareSurface {
            aetherUsesSoftwareSurface = usesSoftwareSurface
        }
        if aetherInitialLoadPending { return }
        let actualRoute: String? = switch engine.videoRoute {
        case .loopback, .remoteBypass: "AetherEngine · AVPlayer 原生画面"
        case .software: "AetherEngine · 软件画面"
        case .audio, .none: nil
        }
        if let actualRoute, diagnostics.routeReason != actualRoute {
            diagnostics.routeReason = actualRoute
        }
        if engine.sourceDVProfile != nil && !diagnostics.detectedDolbyVision {
            diagnostics.detectedDolbyVision = true
        }
        if let profile = engine.sourceDVProfile {
            let range = "Dolby Vision P\(profile)"
            if diagnostics.dynamicRange != range { diagnostics.dynamicRange = range }
        }
        switch engine.state {
        case .playing, .paused:
            isPreparing = false
            isSeekingPlayback = false
        case .loading:
            isPreparing = true
        case .seeking:
            isSeekingPlayback = true
        case .ended:
            finishCurrentPlayback()
        case .error(let detail):
            if let activePlaybackURL { fallbackAetherToMPV(url: activePlaybackURL, reason: detail) }
            else { message = detail }
            return
        case .idle: break
        }
        let time = engine.currentTime
        let length = engine.duration
        if length.isFinite && length > 0 { duration = length }
        guard observeProgress(time, ready: engine.isSessionReady && engine.state != .loading && engine.state != .seeking) else { return }
        currentTime = time
        bufferedTime = engine.bufferedPosition
        isBuffering = engine.isBuffering
        if chapters.isEmpty, !engine.mediaChapters.isEmpty {
            chapters = engine.mediaChapters.map { .init(index: $0.id, title: $0.name, start: $0.startSeconds) }
            if segments.isEmpty { segments = PlaybackSegmentClient.fromChapters(chapters, duration: duration) }
        }
        audioOptions = engine.audioTracks.map(\.name)
        subtitleOptions = engine.subtitleTracks.map { SubtitleLanguageDisplay.title($0.name, language: $0.language) }
        selectedAudioIndex = engine.audioTracks.firstIndex { $0.id == engine.activeAudioTrackIndex }
        selectedSubtitleIndex = engine.subtitleTracks.firstIndex { $0.id == engine.activeSubtitleTrackIndex }
        applyAutomaticSkip(at: currentTime)
        let subtitleTime = currentTime - subtitleDelay
        let ownCue = subtitleCues.first { $0.start <= subtitleTime && subtitleTime < $0.end }?.text
        let aetherCue = engine.subtitleCues.first {
            $0.startTime <= subtitleTime && subtitleTime < $0.endTime
        }
        subtitleText = subtitlesEnabled ? (ownCue ?? aetherCue?.text ?? "") : ""
        subtitleBitmap = nil
        if subtitlesEnabled, ownCue == nil, let aetherCue,
           case .image(let image) = aetherCue.body {
            subtitleBitmap = image.cgImage
            subtitleBitmapPosition = image.position
        }
        if Date().timeIntervalSince(lastProgressSave) >= 5 {
            record(currentTime)
            lastProgressSave = Date()
        }
    }

    private func fallbackAetherToMPV(url: URL, reason: String) {
        if !retriedEmbyAetherProxy, let proxy = embyAetherProxyURL, proxy != url {
            retriedEmbyAetherProxy = true
            resumeOverride = progressTracker.recoveryPosition
            play(url: proxy)
            return
        }
        // Profile 5 is IPT-PQ-c2 and has no ordinary HDR10 base layer. MPV's
        // software path can decode its pixels but cannot present their colours.
        if activeDolbyVisionProfile == 5 || aetherEngineStorage?.sourceDVProfile == 5 {
            message = "杜比视界 P5 原生播放失败：\(reason)"
            return
        }
        guard !forcedMPVForCurrentPlayback, enginePreference == .automatic else {
            message = "原生播放失败：\(reason)"
            return
        }
        resumeOverride = progressTracker.recoveryPosition
        forcedMPVForCurrentPlayback = true
        play(url: url)
    }

    private func transitionAetherToMPV(subtitleStreamIndex: Int? = nil) {
        guard useAether, !useMPV, let url = embyAetherProxyURL ?? activePlaybackURL else { return }
        pendingMPVSubtitleStreamIndex = subtitleStreamIndex
        beginHandover(toMPV: true, url: url)
    }

    private func transitionMPVToAether(url: URL) {
        guard useMPV, !useAether else { return }
        beginHandover(toMPV: false, url: embyAetherProxyURL ?? url)
    }

    private func handoverTrace(_ event: String) {
        #if DEBUG
        auditSnapshot(event)
        #endif
        EngineLog.emit("[Lucent] handover: \(event)")
    }

    private func activatePlaybackAudio() async throws {
        #if os(iOS) || os(tvOS)
        // Recovery only. Successful warm handovers keep the session active.
        try await Task.detached(priority: .userInitiated) {
            let session = AVAudioSession.sharedInstance()
            if session.category != .playback || session.mode != .moviePlayback {
                try session.setCategory(.playback, mode: .moviePlayback, options: session.categoryOptions)
            }
            try session.setActive(true)
        }.value
        #endif
    }

    private func beginHandover(toMPV: Bool, url: URL) {
        guard mpvTransitionTask == nil else { return }
        guard let native = aetherEngine, let mpv = mpvEngine else {
            message = "无法初始化目标播放内核，已保留当前播放。"
            enginePreference = useMPV ? .mpv : .automatic
            return
        }
        engineSwitchNoticeTask?.cancel()
        engineSwitchNotice = nil
        engineSwitchTarget = toMPV ? .mpv : .system
        guard let generation = transitionCoordinator.begin(target: toMPV ? .mpv : .native) else { return }
        handoverLanding = nil
        let preference = enginePreference
        let startingTime = toMPV ? native.currentTime : mpv.time
        switchingToAether = !toMPV
        aetherInitialLoadPending = false
        aetherTransitionOpacity = 0
        mpvTransitionOpacity = 0
        mpvVideoReady = false
        mpvResumePosition = 0
        useAether = true
        useMPV = true
        if toMPV {
            mpv.setVolume(0)
            let warmTime = playbackRequested ? min(startingTime + 2 * Double(playbackRate), max(startingTime, duration - 1)) : startingTime
            mpv.load(mpvPlaybackURL(url), startPosition: warmTime, paused: true)
            mpvTimer?.invalidate()
            mpvTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in self?.tickMPV() }
            }
        } else {
            native.volume = 0
            aetherSurfaceReady = false
            aetherAVPlayer = nil
        }
        handoverTrace("begin \(toMPV ? "MPV" : "native") at \(startingTime)")
        mpvTransitionTask = Task { [weak self] in
            guard let self else { return }
            var sourceStopped = false
            var sourceRetiring = false
            var landingTime = startingTime
            defer {
                if self.handoverGeneration == generation {
                    self.mpvTransitionTask = nil
                    self.engineSwitchTarget = nil
                    self.switchingToAether = false
                    self.transitionCoordinator.finish(generation)
                    self.handoverLanding = nil
                    let queued = self.queuedEnginePreference
                    self.queuedEnginePreference = nil
                    if let queued {
                        Task { @MainActor [weak self] in
                            await Task.yield()
                            guard self?.handoverGeneration == generation else { return }
                            self?.selectEnginePreference(queued)
                        }
                    }
                }
            }
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard self.handoverGeneration == generation else { throw CancellationError() }
                if let failure = mpv.playbackError { throw self.handoverError(failure) }
                if case .error(let failure) = native.state { throw self.handoverError(failure) }
            }
            @MainActor func wait(_ stage: String, seconds: Double = 30, until ready: @MainActor () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(seconds)
                while !ready() {
                    try check()
                    guard Date() < deadline else { throw self.handoverError("等待\(stage)超时") }
                    try await Task.sleep(for: .milliseconds(50))
                }
                try check()
                self.handoverTrace(stage)
            }
            do {
                if !toMPV {
                    let layout = SpatialSpeakerLayout(rawValue:
                        UserDefaults.standard.string(forKey: "lucent.playback.atmosLayout") ?? "5.1.2") ?? .l512
                    _ = try await native.load(url: url, startPosition: startingTime,
                        options: LoadOptions(preferDualLayerDolbyVision: false,
                                             objectAudioRendering: .apac(layout), confirmAtmos: true,
                                             preferredAudioLanguages: [],
                                             preferredSubtitleLanguages: [], autoplay: false))
                    try check()
                    guard native.videoRoute == .loopback || native.videoRoute == .remoteBypass else {
                        throw self.handoverError("目标未能建立原生画面路径")
                    }
                    self.aetherAVPlayer = native.currentAVPlayer
                    self.aetherUsesSoftwareSurface = false
                    try await self.waitForAetherSession(native)
                    try check()
                }
                // The target remains fully visible behind the old surface while
                // warming; opacity zero can stall a Metal swapchain's first frame.
                try await wait("target first frame") {
                    if toMPV { return mpv.hasVideoOutput && !mpv.isSeeking && !mpv.isBuffering }
                    return self.aetherUsesSoftwareSurface ? native.hasFirstFrameReadyForDisplay : self.aetherSurfaceReady
                }
                // Engine.currentTime is published at ~10 Hz. Reading that for
                // audio overlap can accept a 100ms clock error. Fold AVPlayer's
                // live item clock through Aether's public, epoch-aware PTS map.
                var nativeDisplayOrigin = native.sourceTime - native.currentTime
                @MainActor func nativePosition() -> Double {
                    guard native.videoRoute == .loopback,
                          let raw = native.currentAVPlayer?.currentTime().seconds,
                          raw.isFinite,
                          let pts = native.presentationAxisMap.sourceSeconds(forItemSeconds: raw) else {
                        return native.currentTime
                    }
                    return max(0, pts - nativeDisplayOrigin)
                }
                @MainActor func sourcePosition() -> Double { toMPV ? nativePosition() : mpv.time }
                @MainActor func targetPosition() -> Double { toMPV ? mpv.time : nativePosition() }
                @MainActor func seekTarget(_ time: Double) async throws {
                    self.handoverTrace("target seek \(time), source still running")
                    if toMPV {
                        mpv.setPaused(true)
                        mpv.seek(to: time)
                        try await wait("MPV seek landed", seconds: 12) {
                            !mpv.isSeeking && abs(mpv.time - time) < 0.5
                        }
                    } else {
                        native.pause()
                        await native.seek(to: time)
                        try await self.waitForAetherSession(native)
                        nativeDisplayOrigin = native.sourceTime - native.currentTime
                        try await wait("native seek landed", seconds: 12) {
                            abs(native.currentTime - time) < 0.5
                        }
                    }
                }
                if toMPV, let index = self.pendingMPVSubtitleStreamIndex {
                    mpv.selectSubtitleStreamIndex(index)
                    self.pendingMPVSubtitleStreamIndex = nil
                }
                @MainActor func setTargetPlaying(_ playing: Bool) {
                    if toMPV {
                        mpv.setRate(self.playbackRate)
                        mpv.setPaused(!playing)
                    } else if playing {
                        native.play()
                        native.setRate(self.playbackRate)
                    } else { native.pause() }
                }
                var aligned = false
                var targetStarted = false
                for attempt in 0..<3 {
                    try check()
                    if !self.playbackRequested || sourcePosition() >= self.duration - 2 {
                        try await seekTarget(sourcePosition())
                        aligned = true
                        break
                    }
                    let lead = Double(2 << attempt) * Double(self.playbackRate)
                    if targetPosition() < sourcePosition() + 0.1 {
                        try await seekTarget(min(sourcePosition() + lead, self.duration - 1))
                    }
                    let marker = targetPosition()
                    self.handoverTrace("wait source catch target \(marker)")
                    let catchDeadline = Date().addingTimeInterval(15)
                    let startLead = toMPV ? 0.02 : 0.08
                    while self.playbackRequested && sourcePosition() < marker - startLead {
                        try check()
                        guard Date() < catchDeadline else { throw self.handoverError("源播放未能前进到交接时间") }
                        try await Task.sleep(for: .milliseconds(25))
                    }
                    if !self.playbackRequested { continue }
                    if abs(sourcePosition() - marker) < 0.5 {
                        let rollStart = targetPosition()
                        setTargetPlaying(true)
                        targetStarted = true
                        // A ready paused frame/rate=1 is not audible rolling
                        // playback. Keep the old engine running until the new
                        // clock actually advances and its output has started.
                        try await wait("target transport running", seconds: 8) {
                            if !self.playbackRequested { return true }
                            guard targetPosition() > rollStart + 0.04 else { return false }
                            if toMPV { return !mpv.isSeeking && !mpv.isBuffering && !mpv.isPaused }
                            return native.currentAVPlayer?.timeControlStatus == .playing && !native.isBuffering
                        }
                        if !self.playbackRequested { aligned = true; break }
                        let drift = abs(sourcePosition() - targetPosition())
                        if drift <= max(0.12, 0.08 * Double(self.playbackRate)) {
                            aligned = true
                            break
                        }
                        self.handoverTrace("rolling clock drift \(drift)s; realign while source plays")
                        setTargetPlaying(false)
                        targetStarted = false
                    }
                }
                guard aligned else { throw self.handoverError("目标画面未能与源播放对齐") }
                let landing = sourcePosition()
                landingTime = landing
                self.handoverLanding = landing
                self.currentTime = landing
                self.handoverTrace("aligned, begin visual handover at \(landing)")
                if !targetStarted || !self.playbackRequested {
                    setTargetPlaying(self.playbackRequested)
                }
                // One compositor animation, with both transports still rolling;
                // do not rebuild a short SwiftUI animation for every audio step.
                withAnimation(.linear(duration: 0.2)) {
                    if toMPV { self.mpvTransitionOpacity = 1 }
                    else { self.aetherTransitionOpacity = 1 }
                }
                for step in 1...10 {
                    try check()
                    let fraction = Double(step) / 10
                    if toMPV {
                        native.volume = Float(1 - fraction)
                        mpv.setVolume(100 * fraction)
                    } else {
                        mpv.setVolume(100 * (1 - fraction))
                        native.volume = Float(fraction)
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                if toMPV {
                    sourceRetiring = true
                    native.pause()
                    native.stop()
                    self.aetherAVPlayer = nil
                    self.aetherTimer?.invalidate()
                    self.aetherTimer = nil
                } else {
                    // AO uninit deactivates the shared session and tears down
                    // Metal on the core thread. Neither belongs in the audible
                    // handover. Park one muted instance until reuse/close.
                    mpv.parkForHandover()
                    self.mpvTimer?.invalidate()
                    self.mpvTimer = nil
                }
                sourceStopped = toMPV
                try check()
                if toMPV {
                    mpv.setVolume(100)
                    mpv.setRate(self.playbackRate)
                    mpv.setPaused(!self.playbackRequested)
                    self.useAether = false
                    self.mpvVideoReady = true
                } else {
                    native.volume = 1
                    if !self.playbackRequested { native.pause() }
                    self.useMPV = false
                    self.aetherTimer?.invalidate()
                    self.aetherTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                        Task { @MainActor [weak self] in self?.tickAether() }
                    }
                }
                self.isPreparing = false
                self.isSeekingPlayback = false
                self.currentTime = toMPV ? mpv.time : native.currentTime
                self.diagnostics.engine = toMPV ? .mpv : .aether
                self.enginePreference = preference
                self.handoverTrace("committed \(toMPV ? "MPV" : "native")")
                self.showEngineSwitchNotice("已切换至 \(self.activeEngineTitle)")
            } catch {
                guard self.handoverGeneration == generation else { return }
                if toMPV {
                    try? await mpv.stopAndWait()
                    self.mpvTimer?.invalidate()
                    self.mpvTimer = nil
                    self.useMPV = false
                    self.useAether = true
                    if sourceStopped || sourceRetiring {
                        _ = try? await native.load(url: url, startPosition: landingTime)
                        self.aetherAVPlayer = native.currentAVPlayer
                        self.aetherTimer?.invalidate()
                        self.aetherTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.tickAether() }
                        }
                    }
                    try? await self.activatePlaybackAudio()
                    native.volume = 1
                    if self.playbackRequested { native.play(); native.setRate(self.playbackRate) }
                    else { native.pause() }
                    self.enginePreference = .automatic
                } else {
                    native.stop()
                    self.aetherAVPlayer = nil
                    self.useAether = false
                    self.useMPV = true
                    try? await self.activatePlaybackAudio()
                    if sourceStopped || sourceRetiring {
                        mpv.load(self.mpvPlaybackURL(url), startPosition: landingTime, paused: !self.playbackRequested)
                        self.mpvTimer?.invalidate()
                        self.mpvTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                            Task { @MainActor [weak self] in self?.tickMPV() }
                        }
                    }
                    mpv.setVolume(100)
                    mpv.setPaused(!self.playbackRequested)
                    self.enginePreference = .mpv
                }
                self.handoverTrace("rollback: \(error.localizedDescription)")
                if !(error is CancellationError) {
                    self.message = "内核切换失败，已恢复原内核：\(error.localizedDescription)"
                }
            }
        }
    }

    private func handoverError(_ description: String) -> NSError {
        NSError(domain: "Lucent.PlaybackHandover", code: 1,
                userInfo: [NSLocalizedDescriptionKey: description])
    }

    private func showEngineSwitchNotice(_ notice: String) {
        engineSwitchNoticeTask?.cancel()
        engineSwitchNotice = notice
        engineSwitchNoticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            self?.engineSwitchNotice = nil
        }
    }

    private func waitForAetherSession(_ engine: AetherEngine) async throws {
        // load() constructs a session; it does not promise AVPlayerItem readiness.
        // A pre-ready seek is deferred and can restore an obsolete pause intent
        // after the host has already committed its new transport state.
        let deadline = Date().addingTimeInterval(30)
        while !engine.isSessionReady || engine.state == .loading || engine.state == .seeking {
            try Task.checkCancellation()
            if case .error(let reason) = engine.state { throw handoverError(reason) }
            guard Date() < deadline else { throw handoverError("原生会话尚未完成加载或定位") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    private func mpvPlaybackURL(_ original: URL) -> URL {
        PlaybackTransportPolicy.mpvURL(for: original, embyFileProxy: embyAetherProxyURL,
                                      isTranscoding: transcodeBitrate != nil || automaticTranscodeBitrate != nil)
    }

    private func playWithMPV(url: URL) {
        guard let mpvEngine else {
            message = "MPV 播放内核无法初始化。"
            return
        }
        mpvResumePosition = consumeResumePosition()
        useMPV = true
        lastMPVAdvanceAt = Date()
        lastMPVPosition = 0
        let sourceURL = mpvPlaybackURL(url)
        if sourceURL == embyAetherProxyURL {
            diagnostics.delivery = "Emby · 本机 Range 代理"
            handoverTrace("MPV transport=system-range")
        }
        mpvEngine.load(sourceURL, startPosition: mpvResumePosition, paused: !playbackRequested)
        mpvResumePosition = 0
        mpvTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tickMPV() }
        }
    }

    private func tickMPV() {
        guard useMPV, let mpvEngine else { return }
        mpvEngine.pollEvents()
        if switchingToAether && handoverLanding != nil { return }
        if let playbackError = mpvEngine.playbackError {
            if mpvTransitionTask != nil { return }
            if useAether {
                EngineLog.emit("[Lucent] MPV handover failed: \(playbackError)")
                mpvTimer?.invalidate()
                mpvTimer = nil
                mpvEngine.stop()
                mpvEngine.setVolume(100)
                useMPV = false
                enginePreference = .automatic
                mpvTransitionOpacity = 1
                pendingMPVSubtitleStreamIndex = nil
                message = "切换 MPV 失败，原播放已保留：\(playbackError)"
                return
            }
            if retryDirectMPV() { return }
            message = playbackError
        }
        if mpvEngine.ended { finishCurrentPlayback(); return }
        let mediaDuration = mpvEngine.duration
        let videoReady = mpvEngine.hasVideoOutput && !mpvEngine.isSeeking
        // Retain the last frame during seek; don't replace it with a loading page.
        if videoReady { mpvVideoReady = true }
        if mediaDuration.isFinite, mediaDuration > 0 { duration = mediaDuration }
        if mpvResumePosition > 0, duration > 0, mpvEngine.isSeekable {
            mpvEngine.seek(to: mpvResumePosition)
            mpvResumePosition = 0
        }
        let seconds = mpvEngine.time
        guard seconds.isFinite, seconds >= 0 else { return }
        if useAether && !switchingToAether { return }
        if videoReady { persistPlaybackMedia(mpvEngine.mediaInfo, streams:mpvEngine.persistentStreams) }
        updateDiagnostics(mpvEngine.mediaInfo, observed: videoReady || mediaDuration > 0,
                          nativeOutput: false, preserveSpecificHDR: true)
        guard observeProgress(seconds, ready: videoReady && !mpvEngine.isBuffering) else { return }
        if videoReady { isPreparing = false }
        if chapters.isEmpty, !mpvEngine.chapters.isEmpty {
            chapters = mpvEngine.chapters
            if segments.isEmpty { segments = PlaybackSegmentClient.fromChapters(chapters, duration: duration) }
        }
        currentTime = seconds
        bufferedTime = seconds + mpvEngine.bufferedAhead
        isBuffering = mpvEngine.isBuffering
        isSeekingPlayback = mpvEngine.isSeeking
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
        var availableSubtitles = mpvEngine.trackNames(type: "sub")
        serverSubtitleChoices = [:]
        for delivery in subtitleDeliveries {
            guard let streamIndex = delivery.index else { continue }
            // Match by container stream id, never by language/title or ordinal.
            let embeddedIndex = delivery.isExternal == true ? nil : availableSubtitles.indices.first {
                mpvEngine.subtitleStreamIndex($0) == streamIndex
            }
            if let embeddedIndex {
                serverSubtitleChoices[embeddedIndex] = delivery
            } else {
                serverSubtitleChoices[availableSubtitles.count] = delivery
                availableSubtitles.append(SubtitleLanguageDisplay.title(delivery.displayTitle ?? "字幕 \(streamIndex)", language: delivery.language))
            }
        }
        if audioOptions != availableAudio { audioOptions = availableAudio }
        if selectedAudioIndex != mpvEngine.selectedAudioIndex {
            selectedAudioIndex = mpvEngine.selectedAudioIndex
        }
        if subtitleOptions != availableSubtitles { subtitleOptions = availableSubtitles }
        let selected: Int?
        if let id = activeServerSubtitleID {
            selected = subtitlesEnabled
                ? serverSubtitleChoices.first(where: { $0.value.index == id })?.key : nil
        } else {
            selected = mpvEngine.selectedSubtitleIndex
        }
        if selectedSubtitleIndex != selected { selectedSubtitleIndex = selected }
        let subtitleTime = seconds - subtitleDelay
        subtitleText = subtitlesEnabled
            ? (subtitleCues.first { $0.start <= subtitleTime && subtitleTime < $0.end }?.text ?? "")
            : ""
        if Date().timeIntervalSince(lastProgressSave) >= 5 {
            record(seconds)
            lastProgressSave = Date()
        }
        applyAutomaticSkip(at: seconds)
    }

    private func retryDirectMPV() -> Bool {
        guard directPlaybackFailure != nil, directReconnectAttempts < 2,
              smbServer != nil, let activePlaybackURL, let mpvEngine else { return false }
        directReconnectAttempts += 1
        mpvResumePosition = progressTracker.recoveryPosition
        progressTracker.beginLoad(at: mpvResumePosition)
        handoverTrace("Emby direct reconnect \(directReconnectAttempts) at \(mpvResumePosition)")
        mpvVideoReady = false
        lastMPVAdvanceAt = Date()
        mpvEngine.load(mpvPlaybackURL(activePlaybackURL), startPosition: mpvResumePosition, paused: !playbackRequested)
        mpvResumePosition = 0
        return true
    }

    func selectChapter(_ chapter: PlaybackChapter) {
        seek(to: chapter.start)
    }

    func setAspectRatio(_ ratio: String?) {
        guard useMPV else { return }
        mpvEngine?.setAspectRatio(ratio)
    }

    func setVideoScaleMode(_ mode: VideoScaleMode) {
        videoScaleMode = mode
        // Update both instances during a warm handover so its two pictures
        // have the same crop. A presentation change never reloads the source.
        aetherEngineStorage?.videoGravity = mode.videoGravity
        mpvEngineStorage?.setVideoScaleMode(mode)
    }

    func skip(by seconds: Double) {
        if useAether { seek(to: (aetherEngineStorage?.currentTime ?? currentTime) + seconds); return }
        if useMPV { seek(to: (mpvEngine?.time ?? currentTime) + seconds); return }
        let current = player.currentTime().seconds
        guard current.isFinite else { return }
        let duration = player.currentItem?.duration.seconds
        let target = max(0, current + seconds)
        let clamped = duration.flatMap { $0.isFinite && $0 > 0 ? min(target, $0) : nil } ?? target
        seek(to: clamped)
    }

    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        clearPreview()
        let target = max(0, duration > 0 ? min(seconds, duration) : seconds)
        isSeekingPlayback = true
        if useAether {
            Task { [weak self] in
                await self?.aetherEngineStorage?.seek(to: target)
                self?.isSeekingPlayback = false
            }
            currentTime = target
            return
        }
        if useMPV {
            if mpvEngine?.ended == true, let activePlaybackURL {
                didFinish = false
                mpvEngine?.load(mpvPlaybackURL(activePlaybackURL),
                                startPosition: target, paused: !playbackRequested)
                mpvResumePosition = 0
            } else {
                mpvEngine?.seek(to: target)
            }
            currentTime = target
            return
        }
        let generation = UUID()
        seekGeneration = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.seekGeneration == generation else { return }
                self.isSeekingPlayback = false
                self.isBuffering = self.player.timeControlStatus == .waitingToPlayAtSpecifiedRate
                if !finished { self.message = "播放跳转未完成，请重试。" }
            }
        }
    }

    func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        if useAether { aetherEngineStorage?.setRate(rate); return }
        if useMPV { mpvEngine?.setRate(rate); return }
        // Choosing a speed while paused changes the next resume rate only.
        if playbackRequested { player.rate = rate }
    }

    func setPreferredPeakBitRate(_ bitsPerSecond: Double) {
        preferredPeakBitRate = max(0, bitsPerSecond)
        player.currentItem?.preferredPeakBitRate = preferredPeakBitRate
    }

    func selectEnginePreference(_ preference: PlaybackEnginePreference) {
        handoverTrace("requested \(preference.rawValue)")
        guard mpvTransitionTask == nil, !switchingToAether, !(useAether && useMPV) else {
            queuedEnginePreference = preference
            showEngineSwitchNotice("随后切换至 \(preference.title)")
            handoverTrace("queued \(preference.rawValue)")
            return
        }
        let recoveringFromFailure = currentEngineHasFailed
        let alreadyUsingRequestedEngine = preference == .mpv ? useMPV : !useMPV
        guard recoveringFromFailure || enginePreference != preference || !alreadyUsingRequestedEngine else { return }
        message = nil
        enginePreference = preference
        forcedMPVForCurrentPlayback = false
        if recoveringFromFailure {
            // A failed source cannot participate in a warm clock-aligned
            // handover. Reopen the source; do not let its old error abort the
            // requested engine before it has had a chance to load.
            retryPlayback()
            return
        }
        if alreadyUsingRequestedEngine {
            showEngineSwitchNotice("当前正在使用 \(activeEngineTitle)")
            return
        }
        guard let activePlaybackURL else { return }
        if useAether && preference == .mpv {
            transitionAetherToMPV()
            return
        }
        if useMPV && preference != .mpv {
            transitionMPVToAether(url: activePlaybackURL)
            return
        }
        resumeOverride = currentTime
        play(url: activePlaybackURL)
    }

    var currentEngineHasFailed: Bool {
        if useMPV && !useAether { return mpvEngineStorage?.playbackError != nil }
        if useAether, case .error = aetherEngineStorage?.state { return true }
        return !useAether && !useMPV && player.currentItem?.status == .failed
    }

    func retryPlayback() {
        guard let library, !isClosed, mpvTransitionTask == nil else { return }
        let position = progressTracker.recoveryPosition
        handoverTrace("manual recovery \(enginePreference.rawValue) at \(position)")
        close()
        // Re-run source negotiation, including fresh Emby MediaSources and a
        // fresh range listener, rather than reopening an expired/stopped URL.
        resumeOverride = position
        progressTracker.beginLoad(at: position)
        activePlaybackURL = nil
        embyAetherProxyURL = nil
        automaticTranscodeBitrate = nil
        directPlaybackFailure = nil
        directReconnectAttempts = 0
        forcedMPVForCurrentPlayback = false
        useMPV = false
        didFinish = false
        playbackRequested = true
        message = nil
        start(library: library)
    }

    /// Stop readers too: merely pausing MPV/AVPlayer may continue filling a remote cache.
    func suspendForCellularConfirmation() -> Bool {
        let requested = playbackRequested
        let position = progressTracker.recoveryPosition
        close()
        resumeOverride = position
        progressTracker.beginLoad(at: position)
        activePlaybackURL = nil; embyAetherProxyURL = nil
        useMPV = false; useAether = false
        currentTime = position; playbackRequested = false
        return requested
    }

    func resumeAfterCellularConfirmation(library: LibraryStore, playing: Bool) {
        playbackRequested = playing; didFinish = false; message = nil
        start(library: library)
    }

    func setPictureInPictureActive(_ active: Bool) {
        aetherEngineStorage?.pictureInPictureActive = active
    }

    func setSystemPlayback(_ playing: Bool, explicit: Bool = false) {
        guard !isClosed, !didFinish, !currentEngineHasFailed else { return }
        if !explicit {
            guard engineSwitchTarget == nil, !isPreparing, !isSeekingPlayback,
                  !aetherInitialLoadPending else { return }
        }
        guard playbackRequested != playing else { return }
        togglePlayback()
    }

    func synchronizeSystemTransport() {
        guard !isClosed, engineSwitchTarget == nil, !isPreparing,
              !isSeekingPlayback, !isBuffering, !didFinish else { return }
        if useMPV {
            if let engine = mpvEngineStorage, engine.hasVideoOutput, !engine.isSeeking, !engine.isBuffering { setSystemPlayback(!engine.isPaused) }
        } else if let native = useAether ? aetherAVPlayer : player,
                  native.currentItem?.status == .readyToPlay {
            if native.timeControlStatus == .playing { setSystemPlayback(true) }
            else if native.timeControlStatus == .paused { setSystemPlayback(false) }
        }
    }

    func togglePlayback() {
        if currentEngineHasFailed { retryPlayback(); return }
        if useMPV && mpvEngineStorage?.ended == true, let activePlaybackURL {
            playbackRequested = true
            didFinish = false
            mpvEngineStorage?.load(mpvPlaybackURL(activePlaybackURL),
                                  startPosition: currentTime < max(0, duration - 1) ? currentTime : 0)
            return
        }
        playbackRequested.toggle()
        if useMPV && (!useAether || switchingToAether) {
            mpvEngineStorage?.setPaused(!playbackRequested)
        } else if useAether {
            if playbackRequested { aetherEngineStorage?.play(); aetherEngineStorage?.setRate(playbackRate) }
            else { aetherEngineStorage?.pause() }
        } else if playbackRequested {
            player.playImmediately(atRate: playbackRate)
        } else { player.pause() }
        if mpvTransitionTask != nil, handoverLanding != nil {
            // During the actual overlap both engines must honor a user pause.
            mpvEngineStorage?.setPaused(!playbackRequested)
            if playbackRequested { aetherEngineStorage?.play(); aetherEngineStorage?.setRate(playbackRate) }
            else { aetherEngineStorage?.pause() }
        }
        handoverTrace("user playback intent \(playbackRequested)")
    }

    func close() {
        resetPreview()
        guard !isClosed else { return }
        isClosed = true
        sourceLoadGeneration = UUID()
        // Capture the owner before clearing the handover direction. During a
        // reverse warm-up native is enabled but still at zero; MPV owns time.
        let finalPosition = positionForStop()
        let finalDuration = duration > 0 ? duration : nil
        handoverTrace("close checkpoint=\(finalPosition.map(String.init(describing:)) ?? "unchanged") resume=\(progressTracker.recoveryPosition)")
        parkedRetirementTask?.cancel()
        parkedRetirementTask = nil
        transitionCoordinator.invalidate(closing: true)
        mpvTransitionTask?.cancel()
        engineSwitchTarget = nil
        engineSwitchNoticeTask?.cancel()
        engineSwitchNotice = nil
        queuedEnginePreference = nil
        switchingToAether = false
        mpvTransitionTask = nil
        nativeDiagnosticsTask?.cancel()
        nativeDiagnosticsTask = nil
        nativeDiagnosticsItemID = nil
        nativeDiagnosticsAudioIndex = nil
        seekGeneration = UUID()
        isSeekingPlayback = false
        isBuffering = false
        isPreparing = false
        playerItemStatusObservation = nil
        nativeInspectionTask?.cancel()
        nativeInspectionTask = nil
        loadingTask?.cancel()
        loadingTask = nil
        subtitleTask?.cancel()
        subtitleTask = nil
        subtitleDeliveryTask?.cancel()
        subtitleDeliveryTask = nil
        subtitleSelectionTask?.cancel()
        subtitleSelectionTask = nil
        subtitleSelectionGeneration = UUID()
        subtitleDeliveries = []
        subtitleDeliveryContext = nil
        serverSubtitleChoices = [:]
        serverSubtitleCache = [:]
        activeServerSubtitleID = nil
        pendingSubtitleIndex = nil
        subtitleNotice = nil
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
        aetherLoadTask?.cancel()
        aetherLoadTask = nil
        aetherTimer?.invalidate()
        aetherTimer = nil
        if let finalPosition {
            library?.finishPlayback(id: item.id, position: finalPosition, duration: finalDuration)
        }
        aetherEngineStorage?.stop()
        aetherEngineStorage = nil
        useAether = false
        aetherAVPlayer = nil
        aetherInitialLoadPending = false
        aetherSurfaceReady = false
        mpvEngineStorage?.destroy()
        mpvEngineStorage = nil
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

    private func updateDiagnostics(_ features: PlaybackMediaFeatures, observed: Bool,
                                   nativeOutput: Bool, preserveSpecificHDR: Bool = false) {
        var report = diagnostics
        report.apply(features, observed: observed, preserveSpecificHDR: preserveSpecificHDR)
        report.nativeVideoOutput = nativeOutput
        if features.dynamicRange?.lowercased().contains("dolby") == true {
            report.detectedDolbyVision = true
            if !dolbyVisionDetected { dolbyVisionDetected = true }
        }
        // Tick callbacks must not republish an identical report and relayout
        // the complete player / information sheet on every video clock sample.
        if report != diagnostics { diagnostics = report }
    }

    private func persistPlaybackMedia(_ features: PlaybackMediaFeatures, streams: Data? = nil) {
        var observed = features
        observed.videoCodecTag = mediaFeatures.videoCodecTag ?? features.videoCodecTag
        observed.container = observed.container ?? mediaFeatures.container ?? activePlaybackURL?.pathExtension
        library?.recordPlaybackMedia(id:item.id,features:observed,duration:duration,streams:streams)
    }

    private func refreshAetherDiagnostics(_ engine: AetherEngine) {
        var features = PlaybackMediaFeatures(container: engine.sourceContainerFormat,
                                             videoCodec: engine.sourceVideoCodecName)
        let audio = engine.audioTracks.first { $0.id == engine.activeAudioTrackIndex }
            ?? engine.audioTracks.first { $0.isDefault }
        features.audioCodec = audio?.codec
        if engine.sourceVideoWidth > 0, engine.sourceVideoHeight > 0 {
            features.resolution = "\(engine.sourceVideoWidth)×\(engine.sourceVideoHeight)"
        }
        if engine.sourceVideoCodecName != nil || engine.sourceDVProfile != nil {
            switch engine.sourceVideoFormat {
            case .sdr: features.dynamicRange = "SDR"
            case .hdr10: features.dynamicRange = "HDR10"
            case .hdr10Plus: features.dynamicRange = "HDR10+"
            case .hlg: features.dynamicRange = "HLG"
            case .dolbyVision:
                features.dynamicRange = engine.sourceDVProfile.map { "Dolby Vision P\($0)" } ?? "Dolby Vision"
            }
        }
        if engine.isSessionReady {
            var rows: [[String:Any]] = []
            for (kind, tracks) in [("Audio",engine.audioTracks),("Subtitle",engine.subtitleTracks)] {
                for track in tracks where !track.isExternal {
                    var row: [String:Any] = ["Type":kind,"Index":track.id,"Codec":track.codec,
                        "DisplayTitle":track.name,"IsDefault":track.isDefault,"IsExternal":false]
                    row["Language"] = track.language
                    if track.channels > 0 { row["Channels"] = track.channels }
                    rows.append(row)
                }
            }
            persistPlaybackMedia(features,streams:try? JSONSerialization.data(withJSONObject:rows))
        }
        updateDiagnostics(features, observed: engine.isSessionReady,
                          nativeOutput: engine.videoRoute == .loopback || engine.videoRoute == .remoteBypass)
    }

    private func refreshNativeDiagnostics() {
        guard !isClosed, !useAether, !useMPV, nativeDiagnosticsTask == nil,
              let playerItem = player.currentItem, playerItem.status == .readyToPlay else { return }
        let itemID = ObjectIdentifier(playerItem)
        let audioIndex = selectedAudioIndex
        guard nativeDiagnosticsItemID != itemID || nativeDiagnosticsAudioIndex != audioIndex else { return }
        nativeDiagnosticsItemID = itemID
        nativeDiagnosticsAudioIndex = audioIndex
        let subtype = audioGroup.flatMap {
            playerItem.currentMediaSelection.selectedMediaOption(in: $0)?.mediaSubTypes.first?.uint32Value
        }
        let generation = handoverGeneration
        nativeDiagnosticsTask = Task { [weak self] in
            defer {
                if self?.handoverGeneration == generation { self?.nativeDiagnosticsTask = nil }
            }
            let features = await NativePlaybackMediaInfo.read(asset: playerItem.asset, selectedAudioSubtype: subtype)
            guard !Task.isCancelled, let self, !self.isClosed,
                  self.handoverGeneration == generation, self.player.currentItem === playerItem,
                  !self.useMPV, !self.useAether else { return }
            let streams = await NativePlaybackMediaInfo.streamData(asset: playerItem.asset)
            guard !Task.isCancelled, self.player.currentItem === playerItem else { return }
            self.persistPlaybackMedia(features, streams: streams)
            self.updateDiagnostics(features, observed: true, nativeOutput: true, preserveSpecificHDR: true)
        }
    }

    private func updateNativeSubtitleSelection() {
        guard !useMPV, let subtitleGroup,
              let option = player.currentItem?.currentMediaSelection.selectedMediaOption(in: subtitleGroup) else {
            if !useMPV { selectedSubtitleIndex = nil }
            return
        }
        selectedSubtitleIndex = subtitleGroup.options.firstIndex(of: option)
    }

    private func updateNativeAudioSelection() {
        guard !useMPV, let audioGroup,
              let option = player.currentItem?.currentMediaSelection.selectedMediaOption(in: audioGroup) else {
            if !useMPV { selectedAudioIndex = nil }
            return
        }
        selectedAudioIndex = audioGroup.options.firstIndex(of: option)
    }

    private func tick(_ seconds: Double) {
        guard !useMPV, !useAether, player.currentItem != nil else { return }
        updateNativeAudioSelection()
        updateNativeSubtitleSelection()
        refreshNativeDiagnostics()
        guard seconds.isFinite, seconds >= 0 else { return }
        if let value = player.currentItem?.duration.seconds, value.isFinite, value > 0 { duration = value }
        guard observeProgress(seconds, ready: player.currentItem?.status == .readyToPlay && !isSeekingPlayback) else { return }
        if seconds > 0.05 { isPreparing = false }
        currentTime = seconds
        bufferedTime = Self.bufferedEnd(of: player.currentItem)
        applyAutomaticSkip(at: seconds)
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

    private static func bufferedEnd(of item: AVPlayerItem?) -> Double {
        guard let ranges = item?.loadedTimeRanges else { return 0 }
        return ranges.compactMap { range -> Double? in
            let value = range.timeRangeValue
            let end = CMTimeAdd(value.start, value.duration).seconds
            return end.isFinite ? end : nil
        }.max() ?? 0
    }

    func toggleSidecarSubtitle() {
        subtitlesEnabled.toggle()
        if !subtitlesEnabled { subtitleText = "" }
        if activeServerSubtitleID != nil { return }
        if useMPV {
            // Text overlays must not also enable an embedded MPV subtitle track.
            let index = max(0, (mpvEngine?.trackNames(type: "sub").count ?? 1) - 1)
            mpvEngine?.setSubtitleTrack(subtitlesEnabled && subtitleCues.isEmpty ? index : nil)
        }
    }

    func adjustSubtitleDelay(by change: Double) {
        subtitleDelay = min(10, max(-10, subtitleDelay + change))
        if useMPV { mpvEngine?.setSubtitleDelay(subtitleDelay) }
    }

    func selectAudio(_ index: Int) {
        if useAether {
            guard let tracks = aetherEngineStorage?.audioTracks, tracks.indices.contains(index) else { return }
            aetherEngineStorage?.selectAudioTrack(index: tracks[index].id)
            selectedAudioIndex = index
            return
        }
        if useMPV { mpvEngine?.setAudioTrack(index); return }
        guard let group = audioGroup, group.options.indices.contains(index) else { return }
        player.appliesMediaSelectionCriteriaAutomatically = false
        player.currentItem?.select(group.options[index], in: group)
        updateNativeAudioSelection()
    }

    func selectEmbeddedSubtitle(_ index: Int?) {
        if useAether {
            guard let engine = aetherEngineStorage else { return }
            subtitlesEnabled = index != nil
            if let index, engine.subtitleTracks.indices.contains(index) {
                let track = engine.subtitleTracks[index]
                if ["ass", "ssa"].contains(track.codec.lowercased()),
                   enginePreference != .system {
                    transitionAetherToMPV(subtitleStreamIndex: track.id)
                    return
                }
                engine.selectSubtitleTrack(index: track.id)
                selectedSubtitleIndex = index
            } else {
                engine.clearSubtitle()
                selectedSubtitleIndex = nil
            }
            return
        }
        if useMPV {
            subtitleSelectionTask?.cancel()
            let generation = UUID()
            subtitleSelectionGeneration = generation
            pendingSubtitleIndex = nil
            subtitleNotice = nil
            if let index, let delivery = serverSubtitleChoices[index],
               let streamID = delivery.index, let context = subtitleDeliveryContext {
                if activeServerSubtitleID == streamID {
                    subtitlesEnabled = true
                    selectedSubtitleIndex = index
                    return
                }
                pendingSubtitleIndex = index
                subtitleNotice = "正在加载独立字幕，影片继续播放…"
                subtitleSelectionTask = Task { [weak self] in
                    do {
                        let cues: [SubtitleCue]
                        if let cached = self?.serverSubtitleCache[streamID] { cues = cached }
                        else {
                            cues = try await EmbyClient.subtitleCues(delivery: delivery,
                                baseAddress: context.address, token: context.token)
                        }
                        guard !Task.isCancelled, let self,
                              self.subtitleSelectionGeneration == generation else { return }
                        if self.serverSubtitleCache.count >= 4 {
                            self.serverSubtitleCache.removeAll()
                        }
                        self.serverSubtitleCache[streamID] = cues
                        self.subtitleCues = cues
                        self.subtitleText = ""
                        self.subtitlesEnabled = true
                        self.activeServerSubtitleID = streamID
                        // Hide, don't deselect the media's embedded track. Video
                        // and audio keep their demuxer and cached packets intact.
                        self.mpvEngine?.setSubtitleTrack(nil)
                        self.selectedSubtitleIndex = index
                        self.pendingSubtitleIndex = nil
                        self.subtitleNotice = nil
                    } catch {
                        guard !Task.isCancelled, let self,
                              self.subtitleSelectionGeneration == generation else { return }
                        self.pendingSubtitleIndex = nil
                        EmbyClient.logSubtitleFailure(error, stage: "selection")
                        let reason = (error as? SubtitleDeliveryError)?.localizedDescription
                            ?? "字幕读取失败（错误码 \((error as NSError).code)）"
                        self.subtitleNotice = "\(reason)。已保留原字幕和播放。"
                    }
                }
                return
            }
            if activeServerSubtitleID != nil {
                subtitleCues = []
                subtitleText = ""
                activeServerSubtitleID = nil
            }
            if let index, selectedSubtitleIndex != index {
                subtitleNotice = "此轨道未提供独立字幕；切换内嵌字幕可能短暂缓冲。"
            }
            subtitlesEnabled = index != nil
            mpvEngine?.setSubtitleTrack(index)
            return
        }
        guard let group = subtitleGroup else { return }
        subtitlesEnabled = index != nil
        player.appliesMediaSelectionCriteriaAutomatically = false
        let option = index.flatMap { group.options.indices.contains($0) ? group.options[$0] : nil }
        player.currentItem?.select(option, in: group)
        updateNativeSubtitleSelection()
    }

    private func loadSubtitleDeliveries(source: EmbySource, token: String,
                                       itemID: String, mediaSourceID: String) {
        subtitleDeliveryTask?.cancel()
        subtitleDeliveryTask = Task { [weak self] in
            do {
                let deliveries = try await EmbyClient.subtitleDeliveries(source: source,
                    token: token, itemID: itemID, mediaSourceID: mediaSourceID)
                guard !Task.isCancelled, let self else { return }
                self.subtitleDeliveries = deliveries
                self.subtitleDeliveryContext = (source.baseAddress, token)
            } catch {
                // Discovery failure must not interrupt video or remove embedded tracks.
                guard !Task.isCancelled else { return }
                EmbyClient.logSubtitleFailure(error, stage: "discovery")
            }
        }
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
            if Self.usesNativeSubtitle(ext), let data = try? Data(contentsOf: url) {
                useSubtitleData(data, fileExtension: ext)
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

    func installExternalSubtitle(_ data: Data, filename: String) {
        guard engineSwitchTarget == nil, !isClosed else { return }
        subtitleTask?.cancel(); subtitleSelectionTask?.cancel(); subtitleDeliveryTask?.cancel()
        subtitleSelectionGeneration = UUID(); pendingSubtitleIndex = nil
        selectEmbeddedSubtitle(nil)
        activeServerSubtitleID = nil; subtitleCues = []; subtitleText = ""; subtitleBitmap = nil
        if let temporarySubtitleURL { try? FileManager.default.removeItem(at: temporarySubtitleURL) }
        temporarySubtitleURL = nil; nativeSubtitleURL = nil; mpvAttachedSubtitle = false
        let ext = (filename as NSString).pathExtension.lowercased()
        useSubtitleData(data, fileExtension: ext)
        subtitlesEnabled = true
        if Self.usesNativeSubtitle(ext) {
            if useMPV, let url = nativeSubtitleURL { mpvEngine?.addSubtitle(url); mpvAttachedSubtitle = true }
            else if enginePreference != .system { selectEnginePreference(.mpv) }
            else if ["ass", "ssa"].contains(ext) {
                subtitleCues = SubtitleParser.parse(data, fileExtension: ext)
                nativeSubtitleURL = nil
                subtitleNotice = "原生内核使用文本字幕；保留特效请切换 MPV。"
            } else { subtitleNotice = "此位图字幕需要 MPV 内核。" }
        }
    }

    private func useSubtitleData(_ data: Data, fileExtension: String) {
        if Self.usesNativeSubtitle(fileExtension) {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("LucentSubtitle-\(UUID().uuidString).\(fileExtension)")
            do {
                // ASS/SSA are text; normalize legacy Chinese encodings before
                // passing them to libass. Bitmap SUP data must stay untouched.
                let isText = ["ass", "ssa"].contains(fileExtension.lowercased())
                let output = isText ? SubtitleTextDecoder.decode(data).map { Data($0.utf8) } ?? data : data
                try output.write(to: url, options: .atomic)
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
        guard progressTracker.confirmedPosition != nil, progressTracker.resumeTarget == nil,
              seconds.isFinite, seconds >= 0 else { return }
        library?.updateProgress(id: item.id, position: seconds, duration: duration > 0 ? duration : nil)
    }

    private func consumeResumePosition() -> Double {
        let target = resumeOverride ?? progressTracker.recoveryPosition
        resumeOverride = nil
        progressTracker.beginLoad(at: target)
        currentTime = progressTracker.recoveryPosition
        handoverTrace("load resume target=\(currentTime)")
        return currentTime
    }

    private func observeProgress(_ seconds: Double, ready: Bool) -> Bool {
        guard !isClosed else { return false }
        let pending = progressTracker.resumeTarget
        guard progressTracker.observe(seconds, ready: ready) else { return false }
        let completed = PlaybackProgressPolicy.current.isCompleted(position: seconds, duration: duration)
        if completionReached != completed {
            completionReached = completed
            if completed { record(seconds) }
        }
        if let pending { handoverTrace("resume landed requested=\(pending) actual=\(seconds)") }
        return true
    }

    private func positionForStop() -> Double? {
        guard let confirmed = progressTracker.confirmedPosition,
              progressTracker.resumeTarget == nil else { return nil }
        let position: Double?
        switch PlaybackProgressTracker.owner(useAether: useAether, useMPV: useMPV, switchingToAether: switchingToAether) {
        case .mpv:
            let engine = mpvEngineStorage
            position = engine?.hasVideoOutput == true && engine?.isSeeking == false ? engine?.time : nil
        case .aether:
            let engine = aetherEngineStorage
            position = engine?.isSessionReady == true && engine?.state != .loading && engine?.state != .seeking
                ? engine?.currentTime : nil
        case .system:
            position = player.currentItem?.status == .readyToPlay && !isSeekingPlayback ? player.currentTime().seconds : nil
        }
        guard let position, position.isFinite, position >= 0 else { return confirmed }
        // A teardown/reset zero cannot erase a positive confirmed checkpoint.
        return position == 0 && confirmed > 0 ? confirmed : position
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

enum PlaybackError: LocalizedError {
    case fileUnavailable
    var errorDescription: String? {
        switch self {
        case .fileUnavailable: "原文件无法访问，请从媒体库移除后重新添加。"
        }
    }
}
