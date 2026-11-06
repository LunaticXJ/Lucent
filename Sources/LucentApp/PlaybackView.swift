import AVKit
import Combine
import SwiftUI
import LucentAether

private struct EpisodeCardArtwork: View {
    @EnvironmentObject private var library: LibraryStore
    let itemID: String
    let storedItem: MediaItem?
    let currentLocation: MediaLocation
    private var server: (base: String, token: String)? {
        switch currentLocation {
        case .embyItem(let id, _):
            if let source = library.embySources.first(where: { $0.id == id }),
               let token = try? KeychainPasswordStore.embyToken(for: id) { return (source.baseAddress, token) }
        case .jellyfinItem(let id, _):
            if let source = library.jellyfinSources.first(where: { $0.id == id }),
               let token = try? KeychainPasswordStore.jellyfinToken(for: id) { return (source.baseAddress, token) }
        default: break
        }
        return nil
    }
    var body: some View {
        SeriesArtwork(baseAddress: server?.base, token: server?.token, itemID: itemID, backdrop: true,
            fallback: storedItem.flatMap { library.posterURL(for: $0) },
            preferredURL: storedItem?.catalogEpisode?.stillPath.flatMap { URL(string: "https://image.tmdb.org/t/p/w780\($0)") },
            maximumWidth: 500)
    }
}

enum PlayerControlStyle {
    static let secondary = Color.white.opacity(0.64)
    static let rowFill = Color.white.opacity(0.055)
    static let selectedFill = Color.white.opacity(0.14)
    static let divider = Color.white.opacity(0.1)
    #if os(tvOS)
    static let controlSize: CGFloat = 72
    static let panelRadius: CGFloat = 32
    static let rowHeight: CGFloat = 88
    static let panelInset: CGFloat = 32
    static let outerInset: CGFloat = 60
    #else
    static let controlSize: CGFloat = 44
    static let panelRadius: CGFloat = 26
    static let rowHeight: CGFloat = 58
    static let panelInset: CGFloat = 16
    static let outerInset: CGFloat = 20
    #endif
    static func scaled(_ size: CGFloat) -> CGFloat {
        #if os(tvOS)
        size * 1.65
        #else
        size
        #endif
    }
    static func panelWidth(_ available: CGFloat) -> CGFloat {
        #if os(tvOS)
        min(760, max(620, available * 0.4))
        #else
        min(400, max(300, available * 0.46))
        #endif
    }
}

private struct PlayerOptionRow: View {
    let title: String
    var detail: String? = nil
    var selected = false
    var pending = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: PlayerControlStyle.scaled(19), weight: .medium))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: PlayerControlStyle.scaled(15), weight: selected ? .semibold : .medium))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: PlayerControlStyle.scaled(12)))
                        .foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if pending { LucentLoadingView().tint(.white).controlSize(.small) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: PlayerControlStyle.rowHeight, alignment: .leading)
        .background(selected ? PlayerControlStyle.selectedFill : .clear,
                    in: RoundedRectangle(cornerRadius: 15))
        .overlay(RoundedRectangle(cornerRadius: 15)
            .strokeBorder(.white.opacity(selected ? 0.18 : 0), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 15))
    }
}

struct PlaybackView: View {
    private struct EpisodeChoice: Identifiable {
        let id: String
        let title: String
        let season: Int
        let number: Int
        let watched: Bool
        let item: MediaItem?
        let remote: JellyfinItem?
        var detail: JellyfinItem? { remote ?? item?.localDetailItem() }
        var summary: String? { detail?.overview }
        var rating: Double? { detail?.communityRating }
    }

    @EnvironmentObject private var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("lucent.subtitleFontScale") private var subtitleFontScale = 1.0
    @AppStorage("lucent.subtitleBackgroundOpacity") private var subtitleBackgroundOpacity = 0.6
    @AppStorage("lucent.player.controlsAutoHideDelay") private var controlsAutoHideDelay = 3.0
    @AppStorage("lucent.player.seekInterval") private var seekInterval = 10.0
    @AppStorage("lucent.player.showRemainingTime") private var showRemainingTime = false
    @AppStorage("lucent.player.videoScaleMode") private var videoScaleModeRaw = VideoScaleMode.fit.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var session: PlaybackSession
    #if !os(iOS)
    @StateObject private var nativeActivity = NativePlaybackActivity()
    #endif
    @State private var seekPosition: Double = 0
    @State private var previousIdleTimerDisabled: Bool?
    @AppStorage("lucent.player.seekPreview") private var seekPreviewEnabled = true
    @State private var isSeeking = false
    #if os(tvOS)
    @FocusState private var seekTrackFocused: Bool
    @Namespace private var playerFocusScope
    #endif
    @State private var nextPromptDismissed = false
    @AppStorage("lucent.player.nextEpisodePrompt") private var nextEpisodePrompt = true
    @StateObject private var playerWindow = PlayerWindowController()
    @StateObject private var danmaku = DanmakuModel()
    @AppStorage("lucent.danmaku.enabled") private var danmakuEnabled = false
    @State private var showSkipSettings = false
    @State private var showSubtitleSearch = false
    @Environment(\.scenePhase) private var scenePhase
    #if os(iOS)
    @AppStorage(NetworkUsagePolicy.playbackKey) private var cellularApproved = true
    @State private var showCellularConfirmation = false
    @State private var playbackStarted = false
    @State private var networkSuspended = false
    @State private var resumePlayingAfterNetworkConsent = true
    #endif
    #if os(iOS)
    @StateObject private var gestureVolume = PlaybackVolumeControl()
    @State private var gestureHUD: String?
    @State private var gestureActive = false
    @State private var gesturePreviewing = false
    @State private var gestureStartTime = 0.0
    @State private var gestureTarget = 0.0
    @State private var gestureStartLevel: CGFloat = 0
    @State private var gestureRightSide = false
    @State private var heldRate: Float?
    @State private var originalBrightness: CGFloat?
    @State private var hudTask: Task<Void, Never>?
    #endif
    @State private var controlsLocked = false
    @State private var controlsVisible = true
    @State private var lastControlInteraction = Date()
    @State private var secondaryPanel: ControlPanel?
    private enum ControlPanel: String { case danmaku = "弹幕", audio = "音轨", subtitles = "字幕", rate = "播放速度", settings = "更多设置", playlist = "播放列表", diagnostics = "播放信息" }
    private var primaryControlsVisible: Bool {
        controlsVisible && secondaryPanel == nil && !showEpisodeList
    }
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
    private let forceRemotePlayback: Bool

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
        self.forceRemotePlayback = forceRemoteVersion || transcodeBitrate != nil
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
        GeometryReader { geometry in
            playerContent
                .task(id: geometry.size.width > geometry.size.height) {
                    #if os(iOS)
                    guard geometry.size.width > geometry.size.height else { return }
                    #endif
                    // Mount the landscape player shell before resolving a source.
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    #if os(iOS)
                    await startWithNetworkConsent()
                    #else
                    session.start(library: library)
                    #endif
                }
        }
        .background(.black)
        #if os(iOS)
        .alert("是否使用移动网络播放？", isPresented: $showCellularConfirmation) {
            Button("取消播放", role: .cancel) { dismiss() }
            Button("使用移动网络播放") {
                cellularApproved = true
                if networkSuspended {
                    networkSuspended = false
                    session.resumeAfterCellularConfirmation(library: library, playing: resumePlayingAfterNetworkConsent)
                } else { session.start(library: library); playbackStarted = true }
            }
        } message: {
            Text("在线播放可能消耗较多移动网络流量。允许后将记住选择，可在设置中关闭。")
        }
        .onReceive(NotificationCenter.default.publisher(for: NetworkUsagePolicy.changed).receive(on: RunLoop.main)) { _ in
            handlePlaybackNetworkChange()
        }
        .onChange(of: playbackStarted) { _, _ in handlePlaybackNetworkChange() }
        #endif
        .onAppear { [session] in
            #if os(iOS)
            LucentOrientationDelegate.setPlaybackPresented(true)
            if previousIdleTimerDisabled == nil {
                previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled
            }
            UIApplication.shared.isIdleTimerDisabled = true
            #endif
            playerWindow.onClose = { [weak session] in session?.setSystemPlayback(false, explicit: true) }
            playerWindow.onActiveChanged = { [weak session] active in session?.setPictureInPictureActive(active) }
            playerWindow.onTransport = { [weak session] playing in session?.setSystemPlayback(playing) }
            playerWindow.onFailure = { [weak session] message in session?.message = message }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { isSeeking = false; session.clearPreview() }
        }
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            // Let AVKit/Aether finish their foreground callbacks before sampling
            // the stable transport; never turn transient buffering into a pause.
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard !Task.isCancelled else { return }
            session.synchronizeSystemTransport()
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["LUCENT_PLAYBACK_AUDIT"] == "1" {
                await session.runPlaybackAudit()
            }
        }
        #endif
    }

    private var playerContent: some View {
        ZStack {
            ZStack(alignment: .bottom) {
                // Keep surface identities and parentage stable across handovers.
                // Moving an AVKit controller between conditional branches tears
                // it down; moving the MPV view detaches its Metal layer.
                standardPlayerSurface
                    .opacity(!session.useAether && !session.useMPV ? 1 : 0)
                    .allowsHitTesting(false)
                if let engine = session.aetherEngine {
                    aetherSurface(engine)
                        .id(ObjectIdentifier(engine))
                        .opacity(!session.useAether ? 0 :
                            session.useMPV && !session.switchingToAether ? 1 - session.mpvTransitionOpacity : 1)
                        .zIndex(session.switchingToAether ? 1 : 2)
                        .allowsHitTesting(false)
                }
                if let engine = session.mpvEngine {
                    MPVPlayerSurface(engine: engine)
                        .id(ObjectIdentifier(engine))
                        .opacity(!session.useMPV ? 0 :
                            session.switchingToAether ? 1 - session.aetherTransitionOpacity :
                            1)
                        .zIndex(session.switchingToAether ? 2 : 1)
                        .allowsHitTesting(false)
                }
                PlayerWindowSurface(controller: playerWindow, player: nativeWindowPlayer,
                                    gravity: videoScaleMode.videoGravity)
                    .opacity(nativeWindowPlayer == nil ? 0 : 1)
                    .allowsHitTesting(false)
                    .zIndex(2.5)
                if session.aetherInitialLoadPending {
                    Color.black.zIndex(3).allowsHitTesting(false)
                }
                if danmakuEnabled, !danmaku.comments.isEmpty {
                    DanmakuOverlay(comments: danmaku.comments, time: session.currentTime,
                        playing: playbackIsActive && !session.isPreparing && !session.isBuffering && !session.isSeekingPlayback && scenePhase == .active,
                        rate: Double(session.playbackRate))
                        .id(danmaku.revision)
                }
                if !session.subtitleText.isEmpty {
                    Text(session.subtitleText)
                        .font(.system(size: PlayerControlStyle.scaled(22) * subtitleFontScale, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 5)
                        .padding(12)
                        .background(.black.opacity(subtitleBackgroundOpacity), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 32)
                        .zIndex(4)
                        .allowsHitTesting(false)
                }
                if let bitmap = session.subtitleBitmap {
                    GeometryReader { geometry in
                        Image(decorative: bitmap, scale: 1)
                            .resizable()
                            .frame(width: geometry.size.width * session.subtitleBitmapPosition.width,
                                   height: geometry.size.height * session.subtitleBitmapPosition.height)
                            .position(x: geometry.size.width * session.subtitleBitmapPosition.midX,
                                      y: geometry.size.height * session.subtitleBitmapPosition.midY)
                    }
                    .zIndex(4)
                    .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            // The video uses the complete viewport. Only chrome retains the
            // horizontal safe area around the Dynamic Island / rounded corners.
            .ignoresSafeArea(.container)
            #if DEBUG
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { size in
                EngineLog.emit("[Lucent] video viewport=\(size.width)x\(size.height)")
            }
            #endif
            #if os(iOS)
            playbackGestureSurface
            PlaybackSystemVolume(control: gestureVolume)
                .frame(width: 120, height: 20).offset(x: -10000).allowsHitTesting(false)
            if let gestureHUD {
                VStack(spacing: 10) {
                    if gestureActive && seekPreviewEnabled && gesturePreviewing { seekPreviewCard(at: gestureTarget) }
                    Text(gestureHUD).font(.system(size: PlayerControlStyle.scaled(20), weight: .semibold, design: .rounded))
                        .monospacedDigit().padding(.horizontal, 24).padding(.vertical, 16)
                        .background(.ultraThinMaterial, in: Capsule())
                }.allowsHitTesting(false)
            }
            #elseif os(tvOS)
            if !controlsVisible && secondaryPanel == nil && !showEpisodeList {
                Button {
                    controlsVisible = true; lastControlInteraction = Date()
                } label: { Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity) }
                .buttonStyle(.plain).focusEffectDisabled()
                .accessibilityLabel("显示播放控制")
            }
            #else
            Color.clear.contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) {
                        controlsVisible.toggle()
                    }
                    lastControlInteraction = Date()
                }
                .accessibilityLabel("显示或隐藏播放控制")
                .ignoresSafeArea(.container)
            #endif
            VStack(spacing: 0) {
                if !controlsLocked && primaryControlsVisible { playbackHeader }
                Spacer(minLength: 0)
                #if !os(tvOS)
                if primaryControlsVisible {
                    HStack {
                        roundControl("锁定或解锁控制", systemImage: controlsLocked ? "lock.fill" : "lock.open") {
                            controlsLocked.toggle()
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 28)
                }
                #endif
                Spacer(minLength: 0)
                if !controlsLocked && primaryControlsVisible { playbackFooter }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            #if os(tvOS)
            .focusSection()
            #endif
            .simultaneousGesture(TapGesture().onEnded { lastControlInteraction = Date() })
            if !controlsVisible, !controlsLocked, secondaryPanel == nil, !showEpisodeList,
               !session.autoSkipSegments, let segment = session.activeSkipSegment {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        skipButton("跳过\(segment.title)") { session.skipSegment(segment) }
                    }.padding(.horizontal, 28)
                }.padding(.bottom, session.completionReached && nextEpisodePrompt && !nextPromptDismissed && nextItem != nil ? 140 : 28)
            }
            if session.completionReached, nextEpisodePrompt, !nextPromptDismissed,
               let nextItem, !controlsLocked, secondaryPanel == nil, !showEpisodeList {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        HStack(spacing: 14) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("已看完，可播放下一集").font(.caption).foregroundStyle(.white.opacity(0.7))
                                Text(nextItem.title).font(.subheadline.weight(.semibold)).lineLimit(1)
                            }
                            Button("下一集") { onContinue?() }.buttonStyle(.bordered)
                            Button { nextPromptDismissed = true } label: { Image(systemName: "xmark").frame(width: 30, height: 36) }
                                .lucentPlayerButtonStyle().accessibilityLabel("关闭下一集提示")
                        }
                        .padding(14).frame(maxWidth: 390)
                        .lucentVideoGlass()
                    }.padding(.horizontal, 28)
                }
                .padding(.bottom, primaryControlsVisible ? 165 : 28)
                .transition(.opacity)
            }
            if let secondaryPanel { controlPanel(secondaryPanel) }
            if showEpisodeList { episodeCarousel }
            if session.isPreparing || session.isBuffering || session.isSeekingPlayback, session.message == nil,
               secondaryPanel == nil, !showEpisodeList {
                loadingOverlay
                    .transition(.opacity)
                    .zIndex(10)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: session.isPreparing || session.isBuffering || session.isSeekingPlayback)
        .ignoresSafeArea(edges: .vertical)
        .background(.black)
        #if !os(tvOS)
        .foregroundStyle(.white)
        .tint(.white)
        #endif
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showSkipSettings) {
            PlaybackSkipSettingsView(item: item, duration: session.duration, currentTime: session.currentTime) { intro, credits in
                session.setManualSkipTimes(intro: intro, credits: credits)
            }.environmentObject(library)
        }
        .sheet(isPresented: $showSubtitleSearch) {
            SubtitleSearchView(item: library.items.first { $0.id == item.id } ?? item) { data, filename in
                session.installExternalSubtitle(data, filename: filename)
            }.environmentObject(library)
        }
        .task(id: item.id) { await danmaku.restore(for: item.id) }
        .task {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                if primaryControlsVisible, playbackIsActive, !isSeeking, !gestureIsActive,
                   session.engineSwitchTarget == nil,
                   !session.isPreparing, !session.isBuffering, !session.isSeekingPlayback, session.message == nil,
                   controlsAutoHideDelay > 0,
                   Date().timeIntervalSince(lastControlInteraction) >= controlsAutoHideDelay {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { controlsVisible = false }
                }
            }
        }
        .onChange(of: videoScaleModeRaw) { _, _ in
            session.setVideoScaleMode(videoScaleMode)
        }
        .onChange(of: isSeeking) { _, _ in lastControlInteraction = Date() }
        .onChange(of: playbackIsActive) { _, playing in
            #if !os(iOS)
            nativeActivity.update(playing: playing)
            #endif
            lastControlInteraction = Date()
            if !playing { controlsVisible = true }
        }
        .onChange(of: showEpisodeList) { _, _ in lastControlInteraction = Date() }
        .onChange(of: session.engineSwitchTarget) { _, _ in
            isSeeking = false
            session.clearPreview()
            controlsVisible = true
            lastControlInteraction = Date()
        }
        .onChange(of: session.message) { _, message in
            if message != nil { closePanel() }
        }
        .task(id: item.id) { await loadEpisodeChoices() }
        .onDisappear {
            #if !os(iOS)
            nativeActivity.update(playing: false)
            #endif
            #if os(iOS)
            finishGestureHold()
            hudTask?.cancel()
            if UserDefaults.standard.object(forKey: "lucent.gestures.restoreBrightness") as? Bool ?? true,
               let originalBrightness { UIScreen.main.brightness = originalBrightness }
            #endif
            playerWindow.stop()
            session.close()
            #if os(iOS)
            if let previousIdleTimerDisabled {
                UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
            }
            // The landscape player must leave the hierarchy before portrait is requested.
            LucentOrientationDelegate.setPlaybackPresented(false)
            #endif
        }
        #if os(tvOS)
        .focusScope(playerFocusScope)
        .onMoveCommand { _ in
            lastControlInteraction = Date()
            if !controlsVisible && secondaryPanel == nil && !showEpisodeList { controlsVisible = true }
        }
        .onPlayPauseCommand {
            lastControlInteraction = Date()
            if isSeeking { session.seek(to: seekPosition); session.clearPreview(); isSeeking = false }
            else { session.togglePlayback() }
        }
        .onExitCommand {
            if isSeeking { session.clearPreview(); isSeeking = false }
            else if secondaryPanel != nil { closePanel() }
            else if showEpisodeList { showEpisodeList = false }
            else if controlsVisible { controlsVisible = false }
            else { dismiss() }
        }
        #endif
        #if os(macOS)
        .onKeyPress(.escape) { if secondaryPanel != nil { closePanel() } else { dismiss() }; return .handled }
        .onKeyPress(.space) { session.togglePlayback(); return .handled }
        .onKeyPress(.leftArrow) { session.skip(by: -seekInterval); return .handled }
        .onKeyPress(.rightArrow) { session.skip(by: seekInterval); return .handled }
        #endif
        .onChange(of: session.didFinish) { _, finished in
            if finished, nextItem != nil { onContinue?() }
        }
    }

    #if os(iOS)
    private var playbackUsesNetwork: Bool {
        item.requiresRemotePlayback(hasDownload: !forceRemotePlayback && library.downloadedURL(for: item) != nil)
    }
    private func startWithNetworkConsent() async {
        guard !networkSuspended, !showCellularConfirmation else { return }
        let route = await NetworkUsagePolicy.shared.readyRoute()
        guard !Task.isCancelled else { return }
        if playbackUsesNetwork && !cellularApproved && (route == .cellular || route == .unknown) {
            showCellularConfirmation = true; return
        }
        session.start(library: library); playbackStarted = true
    }
    private func handlePlaybackNetworkChange() {
        let route = NetworkUsagePolicy.shared.route
        guard playbackStarted, !showCellularConfirmation, !networkSuspended,
              NetworkUsagePolicy.playbackNeedsConfirmation(on: route, remote: playbackUsesNetwork, approved: cellularApproved) else { return }
        resumePlayingAfterNetworkConsent = session.suspendForCellularConfirmation()
        networkSuspended = true; showCellularConfirmation = true; controlsVisible = true
    }
    #endif

    private var nativeWindowPlayer: AVPlayer? {
        // Warm handover layers must stay independent until the new owner commits.
        guard session.engineSwitchTarget == nil, !session.useMPV else { return nil }
        if session.useAether {
            return session.aetherUsesSoftwareSurface || session.aetherInitialLoadPending ? nil : session.aetherAVPlayer
        }
        return session.isPreparing ? nil : session.player
    }

    @ViewBuilder
    private var standardPlayerSurface: some View {
        PlayerSurface(player: session.player, detachForPictureInPicture: playerWindow.active,
                      videoGravity: videoScaleMode.videoGravity)
    }

    @ViewBuilder
    private func aetherSurface(_ engine: AetherEngine) -> some View {
        if session.aetherUsesSoftwareSurface {
            AetherPlayerSurface(engine: engine)
        } else {
            AetherAVKitSurface(player: session.aetherAVPlayer, detachForPictureInPicture: playerWindow.active, videoGravity: videoScaleMode.videoGravity) {
                session.aetherSurfaceReady = $0
            }
        }
    }

    private var loadingOverlay: some View {
        LucentLoadingView()
            .progressViewStyle(.circular)
            .controlSize(.large)
            .tint(.white)
            .frame(width: 80, height: 80)
            .accessibilityLabel(session.isPreparing ? "正在加载影片" : "正在缓冲")
            .allowsHitTesting(false)
    }

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
                            .font(.system(size: PlayerControlStyle.scaled(16), weight: .semibold))
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
                            .font(.system(size: PlayerControlStyle.scaled(13), weight: .medium))
                            .foregroundStyle(.white.opacity(0.82))
                            .padding(.horizontal, 12).frame(minHeight: 40)
                            .lucentVideoGlass()
                        }
                        Spacer()
                        if episodeLoading { LucentLoadingView().tint(.white) }
                        Text("\(filteredEpisodeChoices.count) 集")
                            .font(.caption).foregroundStyle(.white.opacity(0.65))
                        Button("关闭选集", systemImage: "xmark") { showEpisodeList = false }
                            .labelStyle(.iconOnly)
                            .font(.system(size: PlayerControlStyle.scaled(14), weight: .semibold))
                            .frame(width: 44, height: 44)
                            .lucentVideoGlass()
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
                                                                      ? Color.white : .clear, lineWidth: 2)
                                                }
                                                .overlay(alignment: .bottomTrailing) {
                                                    if choice.id == currentEpisodeID || choice.item?.id == item.id {
                                                        Image(systemName: "waveform")
                                                            .font(.system(size: PlayerControlStyle.scaled(13), weight: .semibold))
                                                            .padding(8)
                                                            .background(.black.opacity(0.68), in: Circle())
                                                            .padding(5)
                                                    }
                                                }
                                                .overlay(alignment: .topTrailing) {
                                                    if choice.watched {
                                                        Image(systemName: "checkmark.circle.fill")
                                                            .font(.system(size: PlayerControlStyle.scaled(14), weight: .semibold))
                                                            .foregroundStyle(.white)
                                                            .padding(6).shadow(radius: 2)
                                                    }
                                                }
                                                .overlay(alignment: .bottomLeading) {
                                                    if let rating = choice.rating {
                                                        Text(rating.formatted(.number.precision(.fractionLength(1))))
                                                            .font(.caption.bold()).foregroundStyle(.white)
                                                            .padding(.horizontal, 6).padding(.vertical, 3)
                                                            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 5))
                                                            .padding(5)
                                                    }
                                                }
                                            Text("E\(String(format: "%02d", choice.number)) · \(choice.title)")
                                                .font(.system(size: PlayerControlStyle.scaled(13), weight: .medium))
                                                .lineLimit(2)
                                                .frame(height: 34, alignment: .topLeading)
                                                .frame(width: 190, alignment: .leading)
                                            if let summary = choice.summary, !summary.isEmpty {
                                                Text(summary).font(.system(size: PlayerControlStyle.scaled(11)))
                                                    .foregroundStyle(.white.opacity(0.62))
                                                    .lineLimit(2).frame(width: 190, alignment: .leading)
                                            }
                                            if let ticks = choice.detail?.runTimeTicks, ticks > 0 {
                                                Text("\(Int(ticks / 600_000_000)) 分钟")
                                                    .font(.system(size: PlayerControlStyle.scaled(11))).foregroundStyle(.white.opacity(0.62))
                                            }
                                        }
                                    }
                                    .lucentPlayerButtonStyle()
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
                    .frame(height: 216)
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
        let current = library.localLibraryItems.first { $0.id == item.id } ?? item
        let allowedLocalIDs = Set(library.localLibraryItems.map(\.id))
        let local = library.visibleItems.filter { candidate in
            guard sameEpisodeSource(candidate.location, item.location), candidate.missingSince == nil else { return false }
            switch item.location {
            case .embyItem, .jellyfinItem, .plexItem:
                return candidate.identity?.seriesName == series
            default:
                return allowedLocalIDs.contains(candidate.id) &&
                    (candidate.catalogGroupID == current.catalogGroupID ||
                     (candidate.metadata == nil && candidate.identity?.seriesName == current.identity?.seriesName))
            }
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
            VStack(spacing: 4) {
                Text(item.identity?.seriesName ?? item.title)
                    .font(.system(size: PlayerControlStyle.scaled(16), weight: .semibold))
                    .lineLimit(1)
                if case .episode(_, let season, let episode, _) = item.identity {
                    Text("第 \(season) 季 · 第 \(episode) 集")
                        .font(.system(size: PlayerControlStyle.scaled(12), weight: .medium))
                        .foregroundStyle(PlayerControlStyle.secondary)
                }
            }
            .padding(.horizontal, 116)
            HStack(spacing: 10) {
                roundControl("关闭播放器", systemImage: "xmark") {
                    #if os(iOS)
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { dismiss() }
                    #else
                    dismiss()
                    #endif
                }
                Spacer()
                if !session.useMPV {
                    AudioRoutePicker(player: nativeWindowPlayer)
                        .frame(width: PlayerControlStyle.controlSize, height: PlayerControlStyle.controlSize)
                        .lucentVideoGlass()
                        .accessibilityLabel("音频输出设备")
                }
                if nativeWindowPlayer != nil {
                    roundControl("小窗播放", systemImage: "pip.enter") { playerWindow.start() }
                        .disabled(!playerWindow.possible || session.engineSwitchTarget != nil)
                }
            }
        }
        .lucentPlaybackHorizontalPadding().padding(.top, 14).padding(.bottom, 24)
        .background(.linearGradient(colors: [.black.opacity(0.62), .clear],
                                    startPoint: .top, endPoint: .bottom))
    }

    private var playbackFooter: some View {
        VStack(spacing: 8) {
            playbackPrompts
            if let message = session.message {
                HStack(spacing: 14) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(.red.opacity(0.9))
                    Text(LocalizedStringKey(message)).font(.system(size: PlayerControlStyle.scaled(12)))
                        .foregroundStyle(.white.opacity(0.9))
                        .frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
                    Button("重试") { session.retryPlayback() }
                        .font(.system(size: PlayerControlStyle.scaled(13), weight: .semibold))
                        .padding(.horizontal, 15).frame(minHeight: 36)
                        .background(.white.opacity(0.14), in: Capsule())
                        .disabled(session.engineSwitchTarget != nil)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
            }
            if let target = session.engineSwitchTarget {
                HStack(spacing: 8) {
                    LucentLoadingView().tint(.white).controlSize(.small)
                    Text("正在切换至 \(target.title)…")
                }
                .font(.system(size: PlayerControlStyle.scaled(12), weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            } else if let notice = session.engineSwitchNotice {
                Text(notice).font(.system(size: PlayerControlStyle.scaled(12)))
                    .foregroundStyle(PlayerControlStyle.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack(spacing: 14) {
                Text(Self.timeLabel(isSeeking ? seekPosition : session.currentTime))
                    .frame(minWidth: 52, alignment: .leading)
                seekTrack
                Text(showRemainingTime
                     ? "−" + Self.timeLabel(max(0, session.duration - (isSeeking ? seekPosition : session.currentTime)))
                     : Self.timeLabel(session.duration))
                    .frame(minWidth: 52, alignment: .trailing)
                    .onTapGesture { showRemainingTime.toggle() }
                    .accessibilityLabel(showRemainingTime ? "剩余时长" : "总时长")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { showRemainingTime.toggle() }
            }
            .font(.system(size: PlayerControlStyle.scaled(12), weight: .medium, design: .monospaced))
            .foregroundStyle(.white.opacity(0.86))

            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    if item.identity?.seriesName != nil {
                        toolButton("选集", symbol: "list.bullet") {
                            showEpisodeList = true
                            lastControlInteraction = Date()
                        }
                    } else if session.playlistEntries.count > 1 {
                        toolButton("播放列表", symbol: "list.bullet") { openPanel(.playlist) }
                    }
                    Button { openPanel(.rate) } label: {
                        Text("\(Double(session.playbackRate).formatted(.number.locale(LocalizationPreferences.current.displayLocale)))×")
                            .font(.system(size: PlayerControlStyle.scaled(14), weight: .semibold))
                            .monospacedDigit()
                            .frame(width: PlayerControlStyle.scaled(48), height: PlayerControlStyle.controlSize)
                    }
                    .accessibilityLabel("播放速度 \(Double(session.playbackRate).formatted(.number.locale(LocalizationPreferences.current.displayLocale))) 倍")
                }
                .padding(.horizontal, 4)
                .lucentVideoGlass()
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 14) {
                    toolButton("后退 \(Int(seekInterval)) 秒", symbol: "gobackward.\(Int(seekInterval))") {
                        session.skip(by: -seekInterval)
                    }
                    Button { session.togglePlayback() } label: {
                        Image(systemName: session.currentEngineHasFailed ? "arrow.clockwise" : playbackIsActive ? "pause.fill" : "play.fill")
                            .font(.system(size: PlayerControlStyle.scaled(24), weight: .semibold))
                            .frame(width: PlayerControlStyle.scaled(68), height: PlayerControlStyle.controlSize)
                            .contentShape(Capsule())
                    }
                    #if os(tvOS)
                    .prefersDefaultFocus(true, in: playerFocusScope)
                    #endif
                    .accessibilityLabel(session.currentEngineHasFailed ? "重试播放" : playbackIsActive ? "暂停" : "播放")
                    .lucentVideoGlass()
                    toolButton("前进 \(Int(seekInterval)) 秒", symbol: "goforward.\(Int(seekInterval))") {
                        session.skip(by: seekInterval)
                    }
                }

                HStack(spacing: 0) {
                    toolButton("音轨，\(audioSummary)", symbol: "waveform") { openPanel(.audio) }
                    toolButton("字幕，\(subtitleSummary)", symbol: "captions.bubble") { openPanel(.subtitles) }
                    #if os(iOS)
                    toolButton("弹幕", symbol: danmakuEnabled ? "bubble.left.and.bubble.right.fill" : "bubble.left.and.bubble.right") { openPanel(.danmaku) }
                    #endif
                    toolButton("更多设置", symbol: "slider.horizontal.3") { openPanel(.settings) }
                }
                .padding(.horizontal, 4)
                .lucentVideoGlass()
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .lucentPlayerButtonStyle()
            .frame(height: PlayerControlStyle.controlSize + 8)
        }
        .lucentPlaybackHorizontalPadding().padding(.top, 12).padding(.bottom, 18)
        .background(.linearGradient(colors: [.clear, .black.opacity(0.48), .black.opacity(0.78)],
                                    startPoint: .top, endPoint: .bottom))
    }

    @ViewBuilder private var playbackPrompts: some View {
        let activeSegment = session.autoSkipSegments ? nil : session.activeSkipSegment
        if activeSegment != nil || nextItem != nil {
            HStack(spacing: 8) {
                if let segment = activeSegment {
                    skipButton("跳过\(segment.title)") { session.skipSegment(segment) }
                }
                Spacer(minLength: 8)
                if let nextItem {
                    skipButton("下一集") { onContinue?() }
                        .accessibilityLabel("下一集，\(nextItem.title)")
                }
            }
            .frame(minHeight: 36)
        }
    }

    private func toolButton(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: PlayerControlStyle.scaled(20), weight: .regular))
                .frame(width: PlayerControlStyle.controlSize, height: PlayerControlStyle.controlSize)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
    }

    private var audioSummary: String {
        guard let index = session.selectedAudioIndex, session.audioOptions.indices.contains(index) else {
            return session.isPreparing ? "正在读取" : "自动选择"
        }
        return session.audioOptions[index]
    }

    private var subtitleSummary: String {
        guard session.subtitlesEnabled else { return "关闭" }
        if let index = session.selectedSubtitleIndex, session.subtitleOptions.indices.contains(index) {
            return SubtitleLanguageDisplay.title(session.subtitleOptions[index])
        }
        return session.hasSidecarSubtitle && session.subtitlesEnabled ? "外挂字幕" : "关闭"
    }

    private func openPanel(_ panel: ControlPanel) {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.24)) {
            secondaryPanel = panel
            showEpisodeList = false
        }
        lastControlInteraction = Date()
    }

    private func closePanel() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.22)) {
            secondaryPanel = nil
            controlsVisible = true
        }
        lastControlInteraction = Date()
    }

    private func controlPanel(_ panel: ControlPanel) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .trailing) {
                Color.clear.contentShape(Rectangle()).onTapGesture { closePanel() }
                    .accessibilityLabel("关闭播放面板")
                    .accessibilityAddTraits(.isButton)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(panel.rawValue).font(.system(size: PlayerControlStyle.scaled(20), weight: .semibold))
                            Text(panelSubtitle(panel))
                                .font(.system(size: PlayerControlStyle.scaled(12))).foregroundStyle(PlayerControlStyle.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        Button { closePanel() } label: {
                            Image(systemName: "xmark").font(.system(size: PlayerControlStyle.scaled(14), weight: .semibold))
                                .frame(width: PlayerControlStyle.controlSize, height: PlayerControlStyle.controlSize)
                                .background(.white.opacity(0.09), in: Circle())
                                .contentShape(Circle())
                        }
                        .accessibilityLabel("关闭面板")
                    }
                    .padding(20)
                    Rectangle().fill(PlayerControlStyle.divider).frame(height: 0.5)
                    if panel == .danmaku {
                        DanmakuSettingsView(model: danmaku, item: item, close: closePanel)
                    } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            switch panel {
                            case .danmaku: EmptyView()
                            case .audio: trackControls(audio: true)
                            case .subtitles: trackControls(audio: false)
                            case .rate: rateControls
                            case .playlist:
                                panelSection("共 \(session.playlistEntries.count) 项") {
                                    ForEach(session.playlistEntries) { entry in
                                        Button { session.selectPlaylistEntry(entry); closePanel() } label: {
                                            PlayerOptionRow(title: entry.title,
                                                            selected: session.currentPlaylistIndex == entry.index)
                                        }
                                    }
                                }
                            case .diagnostics:
                                PlaybackDiagnosticsPanel(report: session.diagnostics, buffering: session.isBuffering,
                                                         stalls: session.stallCount, failure: session.message)
                            case .settings:
                                advancedControls
                            }
                        }
                        .padding(PlayerControlStyle.panelInset)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.hidden)
                    }
                }
                .frame(width: PlayerControlStyle.panelWidth(geometry.size.width),
                       height: max(180, geometry.size.height - PlayerControlStyle.outerInset * 2))
                .lucentVideoGlass(radius: PlayerControlStyle.panelRadius)
                .padding(.trailing, PlayerControlStyle.outerInset).padding(.vertical, PlayerControlStyle.outerInset)
                .lucentPlayerButtonStyle()
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .id(panel)
                #if os(tvOS)
                .focusSection()
                #endif
                .accessibilityElement(children: .contain)
                .accessibilityAction(.escape) { closePanel() }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func panelSubtitle(_ panel: ControlPanel) -> String {
        switch panel {
        case .danmaku: return danmaku.source
        case .audio: return audioSummary
        case .subtitles: return subtitleSummary
        case .rate: return "当前 \(Double(session.playbackRate).formatted(.number.locale(LocalizationPreferences.current.displayLocale))) 倍速"
        case .settings: return "当前使用 \(session.activeEngineTitle)"
        case .playlist: return "选择接下来播放的内容"
        case .diagnostics: return "当前使用 \(session.activeEngineTitle)"
        }
    }

    private func panelSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringKey(title)).font(.system(size: PlayerControlStyle.scaled(12), weight: .semibold))
                .foregroundStyle(PlayerControlStyle.secondary)
                .padding(.horizontal, 12)
            LazyVStack(alignment: .leading, spacing: 4, content: content)
        }
    }

    private var rateControls: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(Double(session.playbackRate).formatted(.number.locale(LocalizationPreferences.current.displayLocale)))×")
                    .font(.system(size: PlayerControlStyle.scaled(38), weight: .medium, design: .rounded)).monospacedDigit()
                Text(LocalizedStringKey(session.playbackRate == 1 ? "标准速度" : "选择适合你的观看节奏"))
                    .font(.system(size: PlayerControlStyle.scaled(13))).foregroundStyle(PlayerControlStyle.secondary)
            }
            .padding(.horizontal, 12)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                    let selected = abs(Double(session.playbackRate) - rate) < 0.01
                    Button {
                        session.setPlaybackRate(Float(rate))
                        closePanel()
                    } label: {
                        Text("\(rate.formatted(.number.locale(LocalizationPreferences.current.displayLocale)))×")
                            .font(.system(size: PlayerControlStyle.scaled(17), weight: selected ? .semibold : .medium))
                            .monospacedDigit()
                            .frame(maxWidth: .infinity, minHeight: 54)
                            #if !os(tvOS)
                            .foregroundStyle(selected ? .black : .white)
                            .background(selected ? .white : PlayerControlStyle.rowFill,
                                        in: RoundedRectangle(cornerRadius: 14))
                            #endif
                    }
                    .accessibilityLabel("\(rate.formatted(.number.locale(LocalizationPreferences.current.displayLocale))) 倍速")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }

    private var gestureIsActive: Bool {
        #if os(iOS)
        gestureActive || heldRate != nil
        #else
        false
        #endif
    }

    #if os(iOS)
    private func gestureOption(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: "lucent.gestures." + key) as? Bool ?? true
    }
    private func showGestureHUD(_ text: String, persistent: Bool = false) {
        hudTask?.cancel()
        gestureHUD = text
        if !persistent {
            hudTask = Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                gestureHUD = nil
            }
        }
        lastControlInteraction = Date()
    }
    private func finishGestureHold() {
        if let heldRate { session.setPlaybackRate(heldRate); self.heldRate = nil }
        gestureHUD = nil
        lastControlInteraction = Date()
    }
    private var playbackGestureSurface: some View {
        PlaybackGestureSurface(
            enabled: !controlsLocked && secondaryPanel == nil && !showEpisodeList && !showSubtitleSearch && !showSkipSettings &&
                scenePhase == .active && session.engineSwitchTarget == nil && !session.isPreparing &&
                !session.isSeekingPlayback && !session.currentEngineHasFailed && playbackStarted && !networkSuspended,
            singleTap: {
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { controlsVisible.toggle() }
                lastControlInteraction = Date()
            },
            doubleTap: { x in
                let mode = UserDefaults.standard.string(forKey: "lucent.gestures.doubleTap") ?? "regional"
                guard mode != "off" else { return }
                if mode == "playPause" || (x >= 0.33 && x <= 0.67) {
                    session.togglePlayback()
                    showGestureHUD((session.playbackRequested ? "播放" : "暂停").lucentLocalized)
                } else if session.duration > 0 {
                    let delta = x < 0.33 ? -seekInterval : seekInterval
                    session.skip(by: delta)
                    showGestureHUD("\((delta > 0 ? "快进" : "快退").lucentLocalized) \(Int(abs(delta))) s")
                }
            },
            pan: { value, horizontal, state in
                if state == .began {
                    gestureActive = horizontal ? gestureOption("seek") && session.duration > 0 : gestureOption(value.x > 0.5 ? "volume" : "brightness")
                    gesturePreviewing = horizontal
                    gestureStartTime = session.currentTime
                    gestureTarget = gestureStartTime
                    gestureRightSide = value.x > 0.5
                    gestureStartLevel = gestureRightSide ? CGFloat(gestureVolume.value) : UIScreen.main.brightness
                    return
                }
                guard gestureActive else { return }
                if state == .changed {
                    if horizontal {
                        let span = UserDefaults.standard.object(forKey: "lucent.gestures.seekSpan") as? Double ?? 120
                        gestureTarget = max(0, min(max(0, session.duration - 0.5), gestureStartTime + Double(value.x) * span))
                        session.preview(at: gestureTarget)
                        showGestureHUD("\(Int(gestureTarget) / 60):\(String(format: "%02d", Int(gestureTarget) % 60))  \(Int(gestureTarget - gestureStartTime)) 秒", persistent: true)
                    } else {
                        let level = max(0, min(1, gestureStartLevel - value.y * 1.5))
                        if gestureRightSide { gestureVolume.set(Float(level)) }
                        else {
                            if originalBrightness == nil { originalBrightness = UIScreen.main.brightness }
                            UIScreen.main.brightness = level
                        }
                        showGestureHUD("\((gestureRightSide ? "音量" : "亮度").lucentLocalized) \(Int(level * 100))%", persistent: true)
                    }
                } else if [.ended, .cancelled, .failed].contains(state) {
                    if horizontal && state == .ended && abs(gestureTarget - gestureStartTime) > 0.5 { session.seek(to: gestureTarget) }
                    session.clearPreview()
                    gestureActive = false
                    gestureHUD = nil
                    lastControlInteraction = Date()
                }
            },
            hold: { active in
                if active {
                    guard gestureOption("hold"), session.playbackRequested, heldRate == nil else { return }
                    heldRate = session.playbackRate
                    let rate = UserDefaults.standard.object(forKey: "lucent.gestures.holdRate") as? Double ?? 2
                    session.setPlaybackRate(Float(rate))
                    showGestureHUD("\(rate.formatted(.number.locale(LocalizationPreferences.current.displayLocale)))× 倍速播放", persistent: true)
                } else { finishGestureHold() }
            },
            pinch: { scale in
                guard gestureOption("pinch"), abs(scale - 1) > 0.1 else { return }
                videoScaleModeRaw = scale > 1 ? "fill" : "fit"
                showGestureHUD((scale > 1 ? "铺满屏幕" : "等比适应").lucentLocalized)
            })
        .ignoresSafeArea(.container)
    }
    #endif

    private var playbackIsActive: Bool {
        session.playbackRequested && !session.didFinish
    }

    private var videoScaleMode: VideoScaleMode { VideoScaleMode(rawValue: videoScaleModeRaw) ?? .fit }

    private func seekPreviewCard(at target: Double) -> some View {
        VStack(spacing: 5) {
            if seekPreviewEnabled {
                ZStack {
                    RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.65))
                    if let image = session.seekPreview {
                        Image(decorative: image, scale: 1).resizable().scaledToFit()
                    }
                    if session.seekPreviewLoading { LucentLoadingView().tint(.white) }
                    else if session.seekPreviewUnavailable {
                        Image(systemName: "photo").font(.title3).foregroundStyle(.white.opacity(0.6))
                    }
                }.frame(width: 160, height: 90)
                .overlay(alignment: .bottomTrailing) {
                    if session.seekPreview != nil, let time = session.seekPreviewTime {
                        Text("≈ " + Self.timeLabel(time)).font(.system(size: PlayerControlStyle.scaled(10), design: .monospaced))
                            .padding(4).background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4)).padding(4)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
            Text(Self.timeLabel(target)).font(.system(size: PlayerControlStyle.scaled(13), weight: .semibold, design: .monospaced))
                .padding(.horizontal, 10).padding(.vertical, 4).background(.black.opacity(0.65), in: Capsule())
        }.frame(width: 160).accessibilityHidden(true)
    }

    private var seekTrack: some View {
        GeometryReader { geometry in
            let width = max(1, geometry.size.width)
            let rawFraction = session.duration.isFinite && session.duration > 0
                ? (isSeeking ? seekPosition : session.currentTime) / session.duration : 0
            let fraction = rawFraction.isFinite ? min(1, max(0, rawFraction)) : 0
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2)).frame(height: isSeeking ? 6 : 4)
                Capsule().fill(.white).frame(width: max(0, width * fraction), height: isSeeking ? 6 : 4)
                Circle().fill(.white).frame(width: isSeeking ? 16 : 11, height: isSeeking ? 16 : 11)
                    .offset(x: min(max(0, width - (isSeeking ? 16 : 11)),
                                   max(0, width * fraction - (isSeeking ? 8 : 5.5))))
            }
            .overlay(alignment: .topLeading) {
                if isSeeking {
                    seekPreviewCard(at: seekPosition)
                        .offset(x: min(max(0, width * fraction - 80), max(0, width - 160)), y: seekPreviewEnabled ? -132 : -42)
                        .allowsHitTesting(false)
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isSeeking)
            .opacity(session.duration > 0 ? 1 : 0.4)
            .frame(height: 42)
            .contentShape(Rectangle())
            #if !os(tvOS)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard session.duration.isFinite, session.duration > 0 else { return }
                    isSeeking = true
                    seekPosition = min(1, max(0, value.location.x / width)) * session.duration
                    session.preview(at: seekPosition)
                }
                .onEnded { _ in
                    guard isSeeking else { return }
                    session.seek(to: seekPosition)
                    session.clearPreview()
                    isSeeking = false
                })
            #else
            .focusable().focused($seekTrackFocused)
            .onMoveCommand { direction in
                guard session.duration > 0, direction == .left || direction == .right else { return }
                if !isSeeking { seekPosition = session.currentTime; isSeeking = true }
                seekPosition = min(session.duration, max(0, seekPosition + (direction == .left ? -seekInterval : seekInterval)))
                session.preview(at: seekPosition); controlsVisible = true
            }
            .onTapGesture {
                guard isSeeking else { return }
                session.seek(to: seekPosition); session.clearPreview(); isSeeking = false
            }
            .onChange(of: seekTrackFocused) { _, focused in
                if !focused { session.clearPreview(); isSeeking = false }
            }
            .overlay(Capsule().stroke(.white.opacity(seekTrackFocused ? 0.65 : 0), lineWidth: 2))
            #endif
        }
        .frame(height: 42)
        .accessibilityLabel("播放进度")
        .accessibilityValue("\(Self.timeLabel(session.currentTime))，共 \(Self.timeLabel(session.duration))")
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: session.skip(by: seekInterval)
            case .decrement: session.skip(by: -seekInterval)
            @unknown default: break
            }
        }
    }

    private func roundControl(_ title: String, systemImage: String,
                              action: @escaping () -> Void) -> some View {
        Button(title, systemImage: systemImage, action: action)
            .labelStyle(.iconOnly).lucentPlayerButtonStyle()
            .font(.system(size: PlayerControlStyle.scaled(19), weight: .medium))
            .frame(width: PlayerControlStyle.controlSize, height: PlayerControlStyle.controlSize)
            .contentShape(Circle())
            .lucentVideoGlass()
    }

    private func skipButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(LocalizedStringKey(title)).font(.system(size: PlayerControlStyle.scaled(12), weight: .semibold)).lineLimit(1)
                Image(systemName: "forward.end.fill").font(.system(size: PlayerControlStyle.scaled(10)))
            }
            .padding(.horizontal, 15).frame(minHeight: 36)
            .lucentVideoGlass()
            .frame(minHeight: 44)
        }
        .lucentPlayerButtonStyle()
    }

    private func audioChoice(_ title: String, index: Int) -> some View {
        let selected = session.selectedAudioIndex == index
        return Button { session.selectAudio(index) } label: {
            PlayerOptionRow(title: title, detail: selected ? "当前使用" : "音轨 \(index + 1)", selected: selected)
        }
        .accessibilityValue(selected ? "当前已选" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func subtitleChoice(_ title: String, index: Int?) -> some View {
        let selected = index == nil
            ? !session.subtitlesEnabled || (session.selectedSubtitleIndex == nil && !session.hasSidecarSubtitle)
            : session.subtitlesEnabled && session.selectedSubtitleIndex == index
        return Button {
            session.selectEmbeddedSubtitle(index)
        } label: {
            PlayerOptionRow(title: title,
                            detail: selected ? "当前使用" : index.map { "字幕 \($0 + 1)" },
                            selected: selected,
                            pending: index != nil && session.pendingSubtitleIndex == index)
        }
        .accessibilityValue(selected ? "当前已选" : "未选中")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private func trackControls(audio: Bool) -> some View {
        if audio {
            if !session.audioOptions.isEmpty {
                panelSection("可用音轨 · \(session.audioOptions.count)") {
                    ForEach(session.audioOptions.indices, id: \.self) { index in
                        audioChoice(session.audioOptions[index], index: index)
                    }
                }
            }
            if transcodeBitrate != nil, !session.serverTracks.audio.isEmpty {
                panelSection("服务器音轨") {
                    ForEach(session.serverTracks.audio) { track in
                        Button {
                            closePanel()
                            session.switchServerAudio(track.id)
                        } label: {
                            PlayerOptionRow(title: track.title, selected: session.selectedServerAudioID == track.id)
                        }
                    }
                }
            }
            if session.audioOptions.isEmpty && session.serverTracks.audio.isEmpty {
                emptyTrackState("waveform", title: session.isPreparing ? "正在读取音轨" : "没有可切换的音轨",
                                detail: session.isPreparing ? "片源准备就绪后将在这里显示。" : "影片将使用当前的音频输出。")
            }
        } else {
            Button { closePanel(); showSubtitleSearch = true } label: {
                panelRow("搜索或添加字幕", symbol: "magnifyingglass")
            }.disabled(session.engineSwitchTarget != nil)
            if !session.subtitleOptions.isEmpty {
                panelSection("可用字幕 · \(session.subtitleOptions.count)") {
                    subtitleChoice("关闭字幕", index: nil)
                    ForEach(session.subtitleOptions.indices, id: \.self) { index in
                        subtitleChoice(SubtitleLanguageDisplay.title(session.subtitleOptions[index]), index: index)
                    }
                }
            }
            if let notice = session.subtitleNotice {
                Label(notice, systemImage: session.pendingSubtitleIndex == nil ? "info.circle" : "arrow.triangle.2.circlepath")
                    .font(.system(size: PlayerControlStyle.scaled(12))).foregroundStyle(PlayerControlStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 12)
            }
            if session.hasSidecarSubtitle {
                panelSection("外挂字幕") {
                    Toggle("显示外挂字幕", isOn: Binding(
                        get: { session.subtitlesEnabled },
                        set: { enabled in
                            if session.subtitlesEnabled != enabled { session.toggleSidecarSubtitle() }
                        }))
                        .font(.system(size: PlayerControlStyle.scaled(15)))
                        .tint(.gray).padding(14)
                        .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 15))
                }
            }
            if transcodeBitrate != nil, !session.serverTracks.subtitles.isEmpty {
                panelSection("服务器字幕") {
                    Button { closePanel(); session.switchServerSubtitle(0) } label: {
                        PlayerOptionRow(title: "关闭字幕", selected: session.selectedServerSubtitleID == 0)
                    }
                    ForEach(session.serverTracks.subtitles) { track in
                        Button { closePanel(); session.switchServerSubtitle(track.id) } label: {
                            PlayerOptionRow(title: SubtitleLanguageDisplay.title(track.title), selected: session.selectedServerSubtitleID == track.id)
                        }
                    }
                }
            }
            if session.subtitleOptions.isEmpty && !session.hasSidecarSubtitle && session.serverTracks.subtitles.isEmpty {
                emptyTrackState("captions.bubble", title: session.isPreparing ? "正在读取字幕" : "没有可用字幕",
                                detail: session.isPreparing ? "片源准备就绪后将在这里显示。" : "此片源尚未提供可选择的字幕轨道。")
            }
            if !session.subtitleOptions.isEmpty || session.hasSidecarSubtitle {
                subtitleTimingControls
            }
            if session.hasSidecarSubtitle { subtitleAppearanceControls }
        }
    }

    private func emptyTrackState(_ icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: PlayerControlStyle.scaled(30), weight: .light))
                .foregroundStyle(PlayerControlStyle.secondary)
            Text(LocalizedStringKey(title)).font(.system(size: PlayerControlStyle.scaled(16), weight: .medium))
            Text(detail).font(.system(size: PlayerControlStyle.scaled(13)))
                .foregroundStyle(PlayerControlStyle.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 28).padding(.horizontal, 12)
    }

    private var subtitleTimingControls: some View {
        panelSection("字幕同步") {
            HStack(spacing: 12) {
                Button { session.adjustSubtitleDelay(by: -0.5) } label: {
                    Image(systemName: "minus").frame(width: 44, height: 44)
                        .background(PlayerControlStyle.rowFill, in: Circle())
                }
                .accessibilityLabel("字幕提前半秒")
                VStack(spacing: 3) {
                    Text("\(session.subtitleDelay.formatted(.number.precision(.fractionLength(1)))) 秒")
                        .font(.system(size: PlayerControlStyle.scaled(18), weight: .medium, design: .rounded)).monospacedDigit()
                    Text(LocalizedStringKey(session.subtitleDelay == 0 ? "与画面同步" : session.subtitleDelay > 0 ? "延后显示" : "提前显示"))
                        .font(.system(size: PlayerControlStyle.scaled(11))).foregroundStyle(PlayerControlStyle.secondary)
                }
                .frame(maxWidth: .infinity)
                Button { session.adjustSubtitleDelay(by: 0.5) } label: {
                    Image(systemName: "plus").frame(width: 44, height: 44)
                        .background(PlayerControlStyle.rowFill, in: Circle())
                }
                .accessibilityLabel("字幕延后半秒")
            }
            .padding(12)
            Button("重置同步") { session.adjustSubtitleDelay(by: -session.subtitleDelay) }
                .font(.system(size: PlayerControlStyle.scaled(13), weight: .medium))
                .foregroundStyle(PlayerControlStyle.secondary)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
    }

    private var subtitleAppearanceControls: some View {
        panelSection("文本字幕外观") {
            Text("这是字幕显示预览")
                .font(.system(size: PlayerControlStyle.scaled(19) * subtitleFontScale, weight: .semibold))
                .padding(8)
                .background(.black.opacity(subtitleBackgroundOpacity), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: .infinity, minHeight: 76)
                .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 15))
            HStack {
                Text("字号").font(.system(size: PlayerControlStyle.scaled(14)))
                LucentValueSlider(value: $subtitleFontScale, range: 0.75...1.5, step: 0.05).tint(.white)
                    .accessibilityLabel("字幕字号")
                Text("\(Int((subtitleFontScale * 100).rounded()))%")
                    .font(.system(size: PlayerControlStyle.scaled(12))).monospacedDigit().frame(width: 42)
            }
            .padding(.horizontal, 12)
            HStack {
                Text("底色").font(.system(size: PlayerControlStyle.scaled(14)))
                LucentValueSlider(value: $subtitleBackgroundOpacity, range: 0...0.85, step: 0.05).tint(.white)
                    .accessibilityLabel("字幕底色不透明度")
                Text("\(Int((subtitleBackgroundOpacity * 100).rounded()))%")
                    .font(.system(size: PlayerControlStyle.scaled(12))).monospacedDigit().frame(width: 42)
            }
            .padding(.horizontal, 12)
            Text("外观用于 Lucent 显示的文本字幕，特效字幕保留片源样式。")
                .font(.system(size: PlayerControlStyle.scaled(11))).foregroundStyle(PlayerControlStyle.secondary)
                .padding(.horizontal, 12).padding(.top, 5)
        }
    }

    private func panelRow(_ title: String, symbol: String, value: String? = nil) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: PlayerControlStyle.scaled(17)))
                .foregroundStyle(PlayerControlStyle.secondary).frame(width: 22)
            Text(LocalizedStringKey(title)).font(.system(size: PlayerControlStyle.scaled(14), weight: .medium))
            Spacer(minLength: 12)
            if let value {
                Text(value).font(.system(size: PlayerControlStyle.scaled(12)))
                    .foregroundStyle(PlayerControlStyle.secondary).lineLimit(1)
            }
            Image(systemName: "chevron.right").font(.system(size: PlayerControlStyle.scaled(10), weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .frame(maxWidth: .infinity, minHeight: 48)
        .padding(.horizontal, 14)
        .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 14))
        .contentShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var advancedControls: some View {
        panelSection("画面大小") {
            Picker("画面大小", selection: $videoScaleModeRaw) {
                ForEach(VideoScaleMode.allCases, id: \.rawValue) { mode in
                    Text(LocalizedStringKey(mode.title)).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text(LocalizedStringKey(videoScaleMode.explanation))
                .font(.system(size: PlayerControlStyle.scaled(11))).foregroundStyle(PlayerControlStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.vertical, 6)
        }
        panelSection("片头片尾") {
            Button { closePanel(); showSkipSettings = true } label: {
                panelRow("片头片尾", symbol: "forward.end", value: "设置跳过时间")
            }
            Toggle(isOn: $session.autoSkipSegments) {
                Label("自动跳过片头片尾", systemImage: "forward.end")
                    .font(.system(size: PlayerControlStyle.scaled(14), weight: .medium))
            }
            .tint(.gray).padding(14)
            .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 14))
        }
        Button { openPanel(.diagnostics) } label: {
            panelRow("播放信息", symbol: "info.circle")
        }
    }

    private struct PlaybackDiagnosticsPanel: View {
        let report: PlaybackDiagnostics
        let buffering: Bool
        let stalls: Int
        let failure: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 14) {
                    Image(systemName: "play.rectangle")
                        .font(.system(size: PlayerControlStyle.scaled(26), weight: .light))
                        .frame(width: PlayerControlStyle.scaled(48), height: PlayerControlStyle.controlSize)
                        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                    VStack(alignment: .leading, spacing: 5) {
                        Text(report.engine.rawValue).font(.system(size: PlayerControlStyle.scaled(20), weight: .semibold))
                        Text(report.routeReason).font(.system(size: PlayerControlStyle.scaled(12)))
                            .foregroundStyle(PlayerControlStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 20))

                VStack(spacing: 0) {
                    detail("播放方式", report.delivery)
                    Divider().overlay(PlayerControlStyle.divider)
                    detail("封装格式", report.container)
                    Divider().overlay(PlayerControlStyle.divider)
                    detail("视频编码", report.videoCodec)
                    Divider().overlay(PlayerControlStyle.divider)
                    detail("音频编码", report.audioCodec)
                    Divider().overlay(PlayerControlStyle.divider)
                    detail("分辨率", report.resolution)
                    Divider().overlay(PlayerControlStyle.divider)
                    detail("动态范围", report.dynamicRange)
                }
                .padding(.horizontal, 16)
                .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 20))
                if let explanation = report.dolbyVisionExplanation {
                    Label(explanation, systemImage: "info.circle")
                        .font(.system(size: PlayerControlStyle.scaled(12))).foregroundStyle(PlayerControlStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 0) {
                    detail("缓冲状态", failure != nil ? "播放异常" : buffering ? "正在缓冲" : "正常")
                    Divider().overlay(PlayerControlStyle.divider)
                    detail("中断次数", String(stalls))
                }
                .padding(.horizontal, 16)
                .background(PlayerControlStyle.rowFill, in: RoundedRectangle(cornerRadius: 20))
                if let failure {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.system(size: PlayerControlStyle.scaled(13))).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }

        private func detail(_ title: String, _ value: String) -> some View {
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                Text(LocalizedStringKey(title)).foregroundStyle(PlayerControlStyle.secondary)
                Spacer(minLength: 12)
                #if os(tvOS)
                Text(report.displayValue(value)).multilineTextAlignment(.trailing).foregroundStyle(.white)
                #else
                Text(report.displayValue(value)).multilineTextAlignment(.trailing).foregroundStyle(.white).textSelection(.enabled)
                #endif
            }
            .font(.system(size: PlayerControlStyle.scaled(13)))
            .padding(.vertical, 14)
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
