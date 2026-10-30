import AVKit
import SwiftUI

enum VideoScaleMode: String, CaseIterable {
    case fit, fill

    var title: String { self == .fit ? "等比适应" : "铺满屏幕" }
    var explanation: String {
        self == .fit ? "显示完整画面，保留片源比例。" : "等比放大填满屏幕，裁剪超出屏幕的边缘。"
    }
    var videoGravity: AVLayerVideoGravity { self == .fit ? .resizeAspect : .resizeAspectFill }
}

/// Reads the asset already opened by AVPlayer. No second URL probe/demuxer is
/// started for the information panel, and audio/video failures are independent.
@MainActor
enum NativePlaybackMediaInfo {
    static func read(asset: AVAsset, selectedAudioSubtype: UInt32?) async -> PlaybackMediaFeatures {
        var result = PlaybackMediaFeatures.unknown
        if let track = try? await asset.loadTracks(withMediaType: .video).first,
           let descriptions = try? await track.load(.formatDescriptions),
           let description = descriptions.first {
            let tag = fourCC(CMFormatDescriptionGetMediaSubType(description))
            result.videoCodecTag = tag
            result.videoCodec = ["hev1", "hvc1", "dvhe", "dvh1"].contains(tag ?? "") ? "hevc" : tag
            let dimensions = CMVideoFormatDescriptionGetDimensions(description)
            if dimensions.width > 0, dimensions.height > 0 {
                result.resolution = "\(dimensions.width)×\(dimensions.height)"
            }
            if descriptions.contains(where: DolbyVisionSupport.formatHasDolbyVision) {
                result.dynamicRange = "Dolby Vision"
            } else {
                let transfer = CMFormatDescriptionGetExtension(description,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
                result.dynamicRange = MediaInfoLabels.dynamicRange(transfer: transfer)
            }
        }
        if let selectedAudioSubtype { result.audioCodec = fourCC(selectedAudioSubtype) }
        else if let track = try? await asset.loadTracks(withMediaType: .audio).first,
                let description = try? await track.load(.formatDescriptions).first {
            result.audioCodec = fourCC(CMFormatDescriptionGetMediaSubType(description))
        }
        return result
    }

    static func streamData(asset: AVAsset) async -> Data? {
        var rows: [[String:Any]] = []
        for (type, name) in [(AVMediaType.video,"Video"),(.audio,"Audio"),(.subtitle,"Subtitle"),(.text,"Subtitle")] {
            for track in (try? await asset.loadTracks(withMediaType:type)) ?? [] {
                guard !Task.isCancelled else { return nil }
                var row: [String:Any] = ["Type":name,"Index":Int(track.trackID),"IsExternal":false]
                if let description = try? await track.load(.formatDescriptions).first {
                    let tag = fourCC(CMFormatDescriptionGetMediaSubType(description))
                    row["Codec"] = tag; if type == .video { row["CodecTag"] = tag }
                }
                row["Language"] = try? await track.load(.languageCode)
                rows.append(row)
            }
        }
        return try? JSONSerialization.data(withJSONObject:rows)
    }

    private static func fourCC(_ code: UInt32) -> String? {
        let bytes = [UInt8((code >> 24) & 0xff), UInt8((code >> 16) & 0xff),
                     UInt8((code >> 8) & 0xff), UInt8(code & 0xff)]
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return nil }
        return String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }
}

#if DEBUG && os(iOS)
import ObjectiveC

// Opt-in transport tracing for the real-device regression. This never runs on
// a normal launch and observes calls without changing their behavior.
extension AVPlayer {
    private nonisolated static let lucentTransportAudit: Void = {
        for (original, replacement) in [
            (#selector(AVPlayer.pause), #selector(AVPlayer.lucentAuditPause)),
            (#selector(setter: AVPlayer.rate), #selector(AVPlayer.lucentAuditSetRate(_:)))
        ] {
            if let lhs = class_getInstanceMethod(AVPlayer.self, original),
               let rhs = class_getInstanceMethod(AVPlayer.self, replacement) {
                method_exchangeImplementations(lhs, rhs)
            }
        }
    }()

    nonisolated static func enableLucentTransportAudit() { _ = lucentTransportAudit }

    @objc private nonisolated func lucentAuditPause() {
        NSLog("Lucent transport pause player=%@ stack=%@", String(describing: ObjectIdentifier(self)),
              Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
        lucentAuditPause()
    }

    @objc private nonisolated func lucentAuditSetRate(_ value: Float) {
        if value == 0 {
            NSLog("Lucent transport rate=0 player=%@ stack=%@", String(describing: ObjectIdentifier(self)),
                  Thread.callStackSymbols.prefix(14).joined(separator: "\n"))
        }
        lucentAuditSetRate(value)
    }
}
#endif

#if os(iOS) || os(tvOS)
/// Sodalite's native route presents AetherEngine's AVPlayer through AVKit;
/// AetherPlayerView is reserved for its software display layer.
struct AetherAVKitSurface: UIViewControllerRepresentable {
    let player: AVPlayer?
    var detachForPictureInPicture = false
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var onReady: @MainActor @Sendable (Bool) -> Void = { _ in }
    final class Coordinator {
        var observation: NSKeyValueObservation?
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = detachForPictureInPicture ? nil : player
        player?.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        controller.videoGravity = videoGravity
        controller.showsPlaybackControls = false
        controller.allowsPictureInPicturePlayback = false
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        let callback = onReady
        context.coordinator.observation = controller.observe(\.isReadyForDisplay, options: [.initial, .new]) { controller, _ in
            let ready = controller.isReadyForDisplay
            Task { @MainActor in callback(ready) }
        }
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let boundPlayer = detachForPictureInPicture ? nil : player
        if controller.player !== boundPlayer { controller.player = boundPlayer }
        // AVKit resets gravity on a player rebind. Set the visible controller,
        // not only Aether's separate, unmounted native AVPlayerLayer.
        if controller.videoGravity != videoGravity { controller.videoGravity = videoGravity }
    }
}

struct PlayerSurface: UIViewControllerRepresentable {
    let player: AVPlayer
    var detachForPictureInPicture = false
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = detachForPictureInPicture ? nil : player
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        controller.videoGravity = videoGravity
        controller.allowsPictureInPicturePlayback = false
        #if os(iOS)
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        #endif
        // PlaybackView owns the controls and the shared loading indicator.
        controller.showsPlaybackControls = false
        return controller
    }

    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        let boundPlayer = detachForPictureInPicture ? nil : player
        if controller.player !== boundPlayer { controller.player = boundPlayer }
        if controller.videoGravity != videoGravity { controller.videoGravity = videoGravity }
    }
}
#elseif os(macOS)
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        view.videoGravity = videoGravity
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
        if view.videoGravity != videoGravity { view.videoGravity = videoGravity }
    }
}
#else
struct PlayerSurface: View {
    let player: AVPlayer
    var videoGravity: AVLayerVideoGravity = .resizeAspect
    var body: some View { VideoPlayer(player: player) }
}
#endif

#if os(iOS)
/// Explicit PiP for custom chrome. A companion layer shares the current AVPlayer
/// (no second decoder), following the host-owned approach used by Sodalite.
@MainActor
final class PlayerWindowController: NSObject, ObservableObject, @preconcurrency AVPictureInPictureControllerDelegate {
    @Published private(set) var possible = false
    @Published private(set) var active = false
    let sourceView = PlayerWindowSourceView()
    private var pip: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private var transportObservation: NSKeyValueObservation?
    private var restoring = false
    var onTransport: ((Bool) -> Void)?
    var onClose: (() -> Void)?
    var onActiveChanged: ((Bool) -> Void)?
    var onFailure: ((String) -> Void)?

    func bind(_ player: AVPlayer?, gravity: AVLayerVideoGravity) {
        sourceView.playerLayer.videoGravity = gravity
        guard sourceView.playerLayer.player !== player else { return }
        stop()
        sourceView.playerLayer.player = player
        guard let player, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
        let controller = AVPictureInPictureController(playerLayer: sourceView.playerLayer)
        controller?.delegate = self
        controller?.canStartPictureInPictureAutomaticallyFromInline = false
        pip = controller
        possibleObservation = controller?.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] controller, _ in
            let possible = controller.isPictureInPicturePossible
            Task { @MainActor [weak self] in self?.possible = possible }
        }
        transportObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            Task { @MainActor [weak self] in
                guard let self, self.active, self.sourceView.playerLayer.player === player else { return }
                let status = player.timeControlStatus
                // Waiting for data is not a user pause.
                if status == .playing { self.onTransport?(true) }
                else if status == .paused { self.onTransport?(false) }
            }
        }
    }

    func start() {
        guard possible else { return }
        restoring = false
        pip?.startPictureInPicture()
    }
    func stop() {
        // Disconnect callbacks before stopping during engine/surface teardown.
        if active { onActiveChanged?(false) }
        pip?.delegate = nil
        pip?.stopPictureInPicture()
        pip = nil
        possibleObservation = nil
        transportObservation = nil
        possible = false
        active = false
    }
    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        active = true
        onActiveChanged?(true)
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error) {
        active = false
        onActiveChanged?(false)
        onFailure?("小窗启动失败：\(error.localizedDescription)")
    }
    func pictureInPictureController(_ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        restoring = true
        // The landscape player stays mounted while the app is in background.
        completionHandler(sourceView.window != nil)
    }
    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        active = false
        // Closing the window means pause; restoring fullscreen preserves transport.
        if !restoring { onClose?() }
        onActiveChanged?(false)
        restoring = false
    }
}

final class PlayerWindowSourceView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

struct PlayerWindowSurface: UIViewRepresentable {
    let controller: PlayerWindowController
    let player: AVPlayer?
    let gravity: AVLayerVideoGravity
    func makeUIView(context: Context) -> PlayerWindowSourceView {
        controller.bind(player, gravity: gravity)
        return controller.sourceView
    }
    func updateUIView(_ view: PlayerWindowSourceView, context: Context) {
        controller.bind(player, gravity: gravity)
    }
}
#endif
