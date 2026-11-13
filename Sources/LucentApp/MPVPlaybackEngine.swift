import Foundation
import CoreText
import Libmpv
import LucentAether
import SwiftUI

typealias MPVGLProcAddress = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?) -> UnsafeMutableRawPointer?

#if os(macOS)
import AppKit
import OpenGL.GL3
#else
import UIKit
import Metal
import QuartzCore
#endif

/// Owns one libmpv instance. All commands and render-context changes run on the main actor.
@MainActor
final class MPVPlaybackEngine {
    private(set) var handle: OpaquePointer?
    private var renderContext: OpaquePointer?
    #if targetEnvironment(simulator)
    private(set) var softwareRenderer: MPVSoftwareRenderer?
    #endif
    private var loadedURL: URL?
    private var pendingURL: URL?
    private var pendingStart: Double = 0
    private var pendingPaused = false
    private(set) var isParked = false
    private(set) var ended = false
    private(set) var playbackError: String?
    private(set) var awaitingPlaybackRestart = false
    private(set) var firstPresentedTime: Double?
    private var endFileSerial: UInt64 = 0
    #if !os(macOS) && !targetEnvironment(simulator)
    let metalLayer = MPVMetalLayer()
    private var metalSurfaceAttached = false
    #endif

    init?() {
        guard let handle = mpv_create() else { return nil }
        self.handle = handle
        mpv_set_option_string(handle, "config", "no")
        let languages = LocalizationPreferences.current
        mpv_set_option_string(handle, "slang", languages.subtitleTrackLanguages.joined(separator: ","))
        if !languages.audioTrackLanguages.isEmpty {
            mpv_set_option_string(handle, "alang", languages.audioTrackLanguages.joined(separator: ","))
        }
        #if os(iOS) || os(tvOS)
        // On Apple's mobile AO this only selects non-mixing AVAudioSession
        // options (not desktop device hog mode). Match AVKit's playback policy
        // at AO creation instead of changing category options during handover.
        mpv_set_option_string(handle, "audio-exclusive", "yes")
        #endif
        // Keep ASS positioning and typesetting for styled subtitles. libass
        // renders the script; stripping overrides removes animation/placement.
        for (name, value) in [
            ("sub-ass-override", "no"),
            ("secondary-sid", "no")
        ] {
            let result = mpv_set_option_string(handle, name, value)
            if result < 0 { NSLog("Lucent MPV: subtitle option %@ failed (%d)", name, result) }
        }
        if let font = Bundle.main.url(forResource: "NotoSansCJKsc-Regular", withExtension: "otf", subdirectory: "SubtitleFonts") {
            // libass can resolve both bundled fonts and CoreText fallback fonts.
            // Use a static CJK face; ASS scripts otherwise retain unavailable font names.
            CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
            for (name, value) in [
                ("sub-fonts-dir", font.deletingLastPathComponent().path),
                ("sub-font-provider", "auto"),
                ("sub-font", "Noto Sans CJK SC")
            ] {
                let result = mpv_set_option_string(handle, name, value)
                if result < 0 { NSLog("Lucent MPV: subtitle option %@ failed (%d)", name, result) }
            }
        } else {
            NSLog("Lucent MPV: bundled CJK subtitle font missing")
        }
        #if os(macOS) || targetEnvironment(simulator)
        mpv_set_option_string(handle, "vo", "libmpv")
        #else
        var windowID = Int64(bitPattern: UInt64(UInt(bitPattern: Unmanaged.passUnretained(metalLayer).toOpaque())))
        mpv_set_option(handle, "wid", MPV_FORMAT_INT64, &windowID)
        mpv_set_option_string(handle, "vo", "gpu-next")
        mpv_set_option_string(handle, "gpu-api", "vulkan")
        mpv_set_option_string(handle, "gpu-context", "moltenvk")
        #endif
        #if targetEnvironment(simulator)
        mpv_set_option_string(handle, "hwdec", "no")
        #else
        mpv_set_option_string(handle, "hwdec", "videotoolbox")
        #endif
        guard mpv_initialize(handle) >= 0 else {
            mpv_terminate_destroy(handle)
            self.handle = nil
            return nil
        }
        // END_FILE only gives a generic loading/decoding error. Subscribe to
        // warnings too, so the transport/demuxer's actual cause is retained.
        mpv_request_log_messages(handle, "warn")
    }

    func load(_ url: URL, startPosition: Double = 0, paused: Bool = false) {
        pollEvents()
        let reuseParkedFile = isParked && loadedURL == url && playbackError == nil && !ended && hasVideoOutput
        isParked = false
        awaitingPlaybackRestart = true
        loadedURL = url
        pendingStart = max(0, startPosition.isFinite ? startPosition : 0)
        pendingPaused = paused
        ended = false
        playbackError = nil
        firstPresentedTime = nil
        log("load start=\(pendingStart) paused=\(paused) parkedReuse=\(reuseParkedFile)")
        if reuseParkedFile {
            // Resume the same demuxer/AO rather than re-opening a paused file.
            // Replacing/stopping it releases iOS's process-wide audio session.
            setPaused(paused)
            seek(to: pendingStart)
            return
        }
        #if os(macOS) || targetEnvironment(simulator)
        let surfaceReady = renderContext != nil
        #else
        let surfaceReady = metalSurfaceAttached
        #endif
        if !surfaceReady {
            pendingURL = url
        } else {
            loadFile(url)
        }
    }

    #if !os(macOS) && !targetEnvironment(simulator)
    func attachMetalSurface() {
        guard !metalSurfaceAttached else { return }
        metalSurfaceAttached = true
        if let pendingURL {
            self.pendingURL = nil
            loadFile(pendingURL)
        }
    }
    #endif

    private func loadFile(_ url: URL) {
        // mpv >= 0.38: the per-file options follow the insertion index. Set
        // start before decoding, rather than rendering frame zero then seeking.
        command("loadfile", [url.absoluteString, "replace", "-1",
                            "start=\(pendingStart),pause=\(pendingPaused ? "yes" : "no")"])
    }

    var isIdle: Bool { (flagProperty("idle-active") ?? 0) != 0 }

    func stopAndWait() async throws {
        // idle-active only tests stop_play == PT_STOP. It becomes true before
        // unload/AO teardown; END_FILE is emitted after uninit_audio_out.
        // Await that event so a retiring iOS AO cannot deactivate the new
        // native player's shared AVAudioSession after we have resumed it.
        pollEvents()
        let needsEndFile = loadedURL != nil && hasVideoOutput
        let previousEnd = endFileSerial
        stop()
        for _ in 0..<500 {
            try Task.checkCancellation()
            pollEvents()
            if (!needsEndFile || endFileSerial != previousEnd), isIdle,
               stringProperty("current-ao") == nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw NSError(domain: "MPV", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "MPV 音频输出未能完成释放"])
    }

    func pollEvents() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_LOG_MESSAGE:
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_log_message.self) {
                    // Event-owned pointers expire at the next mpv_wait_event.
                    let prefix = data.pointee.prefix.map { String(cString: $0) } ?? "mpv"
                    let level = data.pointee.level.map { String(cString: $0) } ?? "warn"
                    let message = data.pointee.text.map { String(cString: $0) } ?? ""
                    log("\(prefix) \(level): \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            case MPV_EVENT_PLAYBACK_RESTART:
                awaitingPlaybackRestart = false
                if firstPresentedTime == nil { firstPresentedTime = time }
            case MPV_EVENT_SEEK:
                awaitingPlaybackRestart = true
            case MPV_EVENT_COMMAND_REPLY:
                if event.pointee.reply_userdata == 3, event.pointee.error < 0 {
                    awaitingPlaybackRestart = false
                    playbackError = "MPV 跳转失败（\(event.pointee.error)）。"
                }
            case MPV_EVENT_END_FILE:
                endFileSerial &+= 1
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                    let description = String(cString: mpv_error_string(data.pointee.error))
                    log("end file reason=\(data.pointee.reason.rawValue) error=\(data.pointee.error) \(description)")
                    switch data.pointee.reason {
                    case MPV_END_FILE_REASON_EOF:
                        awaitingPlaybackRestart = false
                        ended = true
                    case MPV_END_FILE_REASON_ERROR:
                        awaitingPlaybackRestart = false
                        playbackError = data.pointee.error == MPV_ERROR_LOADING_FAILED.rawValue
                            ? "无法打开视频源（MPV -13），可重试或切换内核。"
                            : "MPV 播放失败（\(data.pointee.error)）。"
                    default: break
                    }
                }
            default:
                break
            }
        }
    }

    private func log(_ message: String) {
        // CDN credentials need not use named token parameters. Strip entire
        // media paths/queries before sending third-party messages to any sink.
        EngineLog.emit("[MPV] \(PlaybackDiagnosticPrivacy.removingMediaURLs(from: message))")
    }

    func stop() {
        isParked = false
        awaitingPlaybackRestart = false
        command("stop")
        loadedURL = nil
        pendingURL = nil
    }

    /// Keep one paused decoder and its AO for this playback session. Pause stops
    /// RemoteIO; unlike stop/AO uninit it does not deactivate AVAudioSession.
    /// The next handover seeks this same file; close/replacement releases it.
    func parkForHandover() {
        setVolume(0)
        setPaused(true)
        isParked = true
    }

    func destroy() {
        detachRenderer()
        if let handle { mpv_terminate_destroy(handle) }
        handle = nil
    }

    var time: Double { doubleProperty("time-pos") ?? 0 }
    var duration: Double { doubleProperty("duration") ?? 0 }
    var isPaused: Bool { (flagProperty("pause") ?? 0) != 0 }
    var isPlaying: Bool { loadedURL != nil && !ended && !isPaused && duration > 0 }
    var isBuffering: Bool { (flagProperty("paused-for-cache") ?? 0) != 0 }
    /// Seconds demuxed ahead of the playhead, for the seek bar's buffered range.
    var bufferedAhead: Double { max(0, doubleProperty("demuxer-cache-time") ?? 0) }
    var isSeeking: Bool { awaitingPlaybackRestart || (flagProperty("seeking") ?? 0) != 0 }
    var isSeekable: Bool { (flagProperty("seekable") ?? 0) != 0 }
    var hasVideoOutput: Bool { (intProperty("video-params/w") ?? 0) > 0 }
    var mediaInfo: PlaybackMediaFeatures {
        // Use decoder/input properties, not audio/video output formats after
        // PCM conversion or HDR tone mapping. No new file/network access.
        let width = intProperty("video-params/w") ?? 0
        let height = intProperty("video-params/h") ?? 0
        let transfer = stringProperty("video-dec-params/gamma") ?? stringProperty("video-params/gamma")
        let matrix = stringProperty("video-dec-params/colormatrix") ?? stringProperty("video-params/colormatrix")
        return PlaybackMediaFeatures(container: stringProperty("file-format"),
                                     videoCodec: stringProperty("video-format"),
                                     audioCodec: stringProperty("audio-codec-name"),
                                     dynamicRange: MediaInfoLabels.dynamicRange(transfer: transfer, matrix: matrix),
                                     resolution: width > 0 && height > 0 ? "\(width)×\(height)" : nil)
    }
    var persistentStreams: Data? {
        var rows: [[String:Any]] = []
        for i in 0..<max(0,min(128,Int(intProperty("track-list/count") ?? 0))) {
            guard let type = stringProperty("track-list/\(i)/type"), ["video","audio","sub"].contains(type) else { continue }
            var row: [String:Any] = ["Type": type == "sub" ? "Subtitle" : type.capitalized,
                "Index":Int(intProperty("track-list/\(i)/ff-index") ?? Int64(i))]
            row["Codec"] = stringProperty("track-list/\(i)/codec")
            row["Language"] = stringProperty("track-list/\(i)/lang")
            row["DisplayTitle"] = stringProperty("track-list/\(i)/title")
            row["IsDefault"] = flagProperty("track-list/\(i)/default") == 1
            row["IsExternal"] = flagProperty("track-list/\(i)/external") == 1
            rows.append(row)
        }
        return try? JSONSerialization.data(withJSONObject:rows)
    }
    var chapters: [PlaybackChapter] {
        (0..<max(0, min(1000, Int(intProperty("chapter-list/count") ?? 0)))).compactMap { index in
            guard let time = doubleProperty("chapter-list/\(index)/time"), time.isFinite else { return nil }
            return PlaybackChapter(index: index, title: stringProperty("chapter-list/\(index)/title") ?? "Chapter \(index + 1)", start: time)
        }
    }
    var diagnosticState: String {
        "time=\(time) duration=\(duration) paused=\(isPaused) parked=\(isParked) seeking=\(isSeeking) buffering=\(isBuffering) volume=\(doubleProperty("volume") ?? -1) mute=\(flagProperty("mute") ?? -1) ao=\(stringProperty("current-ao") ?? "none") video=\(hasVideoOutput) error=\(playbackError ?? "none")"
    }

    func setPaused(_ paused: Bool) {
        if !paused { isParked = false }
        set("pause", paused ? "yes" : "no")
    }
    func setRate(_ rate: Float) { set("speed", String(rate)) }
    func setVolume(_ percent: Double) { set("volume", String(min(100, max(0, percent)))) }
    func seek(to seconds: Double) {
        pollEvents()
        awaitingPlaybackRestart = true
        command("seek", [String(seconds), "absolute", "exact"])
    }
    func setAudioTrack(_ index: Int) {
        guard let id = trackIDs(type: "audio").indices.contains(index) ? trackIDs(type: "audio")[index] : nil else { return }
        set("aid", String(id))
    }
    var selectedAudioIndex: Int? {
        guard let id = intProperty("aid"), id > 0 else { return nil }
        return trackIDs(type: "audio").firstIndex(of: Int(id))
    }
    func setSubtitleTrack(_ index: Int?) {
        // Keep the demuxer subscribed when hiding subtitles. Re-selecting a
        // disabled embedded track can trigger MPV's shared-demuxer refresh seek.
        guard let index else { set("sub-visibility", "no"); return }
        let ids = trackIDs(type: "sub")
        guard ids.indices.contains(index) else { return }
        if intProperty("sid") != Int64(ids[index]) {
            set("sid", String(ids[index]))
        }
        set("sub-visibility", "yes")
    }
    func selectSubtitleStreamIndex(_ streamIndex: Int) {
        let count = max(0, min(128, Int(intProperty("track-list/count") ?? 0)))
        for track in 0..<count where stringProperty("track-list/\(track)/type") == "sub" {
            guard intProperty("track-list/\(track)/ff-index") == Int64(streamIndex),
                  let id = intProperty("track-list/\(track)/id") else { continue }
            set("sid", String(id))
            set("sub-visibility", "yes")
            return
        }
    }
    var selectedSubtitleIndex: Int? {
        guard let id = intProperty("sid"), id > 0,
              (flagProperty("sub-visibility") ?? 1) != 0 else { return nil }
        return trackIDs(type: "sub").firstIndex(of: Int(id))
    }

    /// Container stream index, not MPV's per-type track id or menu ordinal.
    func subtitleStreamIndex(_ index: Int) -> Int? {
        let count = max(0, min(128, Int(intProperty("track-list/count") ?? 0)))
        let tracks = (0..<count).filter { stringProperty("track-list/\($0)/type") == "sub" }
        guard tracks.indices.contains(index),
              stringProperty("track-list/\(tracks[index])/external") != "yes",
              let value = intProperty("track-list/\(tracks[index])/ff-index"), value >= 0 else { return nil }
        return Int(value)
    }

    func setSubtitleDelay(_ seconds: Double) { set("sub-delay", String(seconds)) }
    func setAspectRatio(_ ratio: String?) { set("video-aspect-override", ratio ?? "no") }
    func setVideoScaleMode(_ mode: VideoScaleMode) {
        // Use renderer scaling, without changing the source aspect metadata.
        set("keepaspect", mode == .stretch ? "no" : "yes")
        set("video-unscaled", "no")
        set("panscan", mode == .fill ? "1" : "0")
    }
    func addSubtitle(_ url: URL) { command("sub-add", [url.absoluteString, "select"]) }
    func addAudio(_ url: URL) { command("audio-add", [url.absoluteString, "select"]) }

    func trackNames(type: String) -> [String] {
        let count = max(0, min(128, Int(intProperty("track-list/count") ?? 0)))
        return (0..<count).compactMap { index in
            guard stringProperty("track-list/\(index)/type") == type else { return nil }
            let language = stringProperty("track-list/\(index)/lang")
            let title = stringProperty("track-list/\(index)/title")
                ?? stringProperty("track-list/\(index)/external-filename")
                ?? language
            let name = title?.isEmpty == false ? title! : "\(type == "audio" ? "音轨" : "字幕") \(index + 1)"
            return type == "sub" ? SubtitleLanguageDisplay.title(name, language: language) : name
        }
    }

    private func trackIDs(type: String) -> [Int] {
        let count = max(0, min(128, Int(intProperty("track-list/count") ?? 0)))
        return (0..<count).compactMap { index in
            guard stringProperty("track-list/\(index)/type") == type else { return nil }
            return Int(stringProperty("track-list/\(index)/id") ?? "")
        }
    }

    private func command(_ name: String, _ arguments: [String] = []) {
        guard let handle else { return }
        let values = [name] + arguments
        var pointers: [UnsafePointer<CChar>?] = values.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        defer { pointers.compactMap { $0 }.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        // Seeking can wait for the demuxer/network. Never make UIKit wait for it.
        let status = ["seek", "sub-add", "audio-add"].contains(name)
            ? mpv_command_async(handle, name == "seek" ? 3 : 1, &pointers)
            : mpv_command(handle, &pointers)
        if status < 0 {
            if name == "seek" || name == "loadfile" {
                awaitingPlaybackRestart = false
                playbackError = name == "seek" ? "MPV 跳转失败（\(status)）。" : "MPV 加载命令失败（\(status)）。"
            }
            log("command \(name) failed (\(status)): \(String(cString: mpv_error_string(status)))")
            NSLog("Lucent MPV: command %@ failed (%d)", name, status)
        }
    }

    private func set(_ property: String, _ value: String) {
        guard let handle else { return }
        // Track selection can initialize libass or access the demuxer. Queue it
        // without blocking UIKit or the thread that services playback events.
        let values = ["set", property, value]
        var pointers: [UnsafePointer<CChar>?] = values.map { UnsafePointer(strdup($0)) }
        pointers.append(nil)
        defer { pointers.compactMap { $0 }.forEach { free(UnsafeMutablePointer(mutating: $0)) } }
        let status = mpv_command_async(handle, 2, &pointers)
        if status < 0 { NSLog("Lucent MPV: setting %@ failed (%d)", property, status) }
    }

    private func doubleProperty(_ name: String) -> Double? {
        guard let handle else { return nil }
        var result: Double = 0
        return mpv_get_property(handle, name, MPV_FORMAT_DOUBLE, &result) >= 0 ? result : nil
    }

    private func intProperty(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var result: Int64 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_INT64, &result) >= 0 ? result : nil
    }

    private func flagProperty(_ name: String) -> Int64? {
        guard let handle else { return nil }
        var result: Int32 = 0
        return mpv_get_property(handle, name, MPV_FORMAT_FLAG, &result) >= 0 ? Int64(result) : nil
    }

    private func stringProperty(_ name: String) -> String? {
        guard let handle, let value = mpv_get_property_string(handle, name) else { return nil }
        defer { mpv_free(value) }
        return String(cString: value)
    }

    func attachRenderer(getProcAddress: MPVGLProcAddress,
                        update: @escaping mpv_render_update_fn,
                        updateContext: UnsafeMutableRawPointer) -> Bool {
        guard let handle else { return false }
        detachRenderer()
        var initParams = mpv_opengl_init_params(get_proc_address: getProcAddress,
                                                get_proc_address_ctx: nil)
        var api = Array("opengl".utf8CString)
        let status = api.withUnsafeMutableBufferPointer { apiBuffer in
            withUnsafeMutablePointer(to: &initParams) { initPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: apiBuffer.baseAddress),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: initPointer),
                    mpv_render_param()
                ]
                return mpv_render_context_create(&renderContext, handle, &params)
            }
        }
        guard status >= 0, let renderContext else {
            NSLog("Lucent MPV: renderer initialization failed (%d)", status)
            return false
        }
        mpv_render_context_set_update_callback(renderContext, update, updateContext)
        if let pendingURL {
            self.pendingURL = nil
            loadFile(pendingURL)
        }
        return true
    }

    func render(fbo: Int32, width: Int32, height: Int32, flipY: Bool) {
        guard let renderContext else { return }
        var framebuffer = mpv_opengl_fbo(fbo: fbo, w: width, h: height, internal_format: 0)
        var flip: CInt = flipY ? 1 : 0
        withUnsafeMutablePointer(to: &framebuffer) { framebufferPointer in
            withUnsafeMutablePointer(to: &flip) { flipPointer in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: framebufferPointer),
                    mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPointer),
                    mpv_render_param()
                ]
                let status = mpv_render_context_render(renderContext, &params)
                if status < 0 { NSLog("Lucent MPV: frame render failed (%d)", status) }
            }
        }
    }

    #if targetEnvironment(simulator)
    // Simulator graphics support differs from devices. Use libmpv's software
    // render API here; keep the device's Metal pipeline independent.
    func attachSoftwareRenderer() -> Bool {
        if renderContext != nil { return true }
        guard let handle else { return false }
        let status = "sw".withCString { api in
            var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                          data: UnsafeMutableRawPointer(mutating: api)),
                          mpv_render_param()]
            return mpv_render_context_create(&renderContext, handle, &params)
        }
        guard status >= 0 else {
            playbackError = "模拟器渲染初始化失败（\(status)）。"
            return false
        }
        softwareRenderer = MPVSoftwareRenderer(context: renderContext!)
        if let pendingURL {
            self.pendingURL = nil
            loadFile(pendingURL)
        }
        return true
    }

    #endif

    func detachRenderer() {
        #if targetEnvironment(simulator)
        if let softwareRenderer {
            softwareRenderer.close()
            self.softwareRenderer = nil
            renderContext = nil
            return
        }
        #endif
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
    }
}

#if targetEnvironment(simulator)
/// All software render calls and destruction are serialized off the UI thread.
final class MPVSoftwareRenderer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lucent.mpv.software-render", qos: .userInitiated)
    private var context: OpaquePointer?
    init(context: OpaquePointer) { self.context = context }
    func frame(width: Int, height: Int, completion: @escaping @Sendable (CGImage?) -> Void) {
        queue.async { completion(self.softwareFrame(width: width, height: height)) }
    }
    func close() {
        queue.sync {
            if let context { mpv_render_context_free(context) }
            context = nil
        }
    }
    private func softwareFrame(width: Int, height: Int) -> CGImage? {
        guard let renderContext = context, width > 0, height > 0,
              mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return nil }
        var dimensions = [Int32(width), Int32(height)]
        var stride = width * 4
        var pixels = Data(count: stride * height)
        let status = pixels.withUnsafeMutableBytes { bytes in
            dimensions.withUnsafeMutableBufferPointer { size in
                withUnsafeMutablePointer(to: &stride) { rowBytes in
                    "rgb0".withCString { format in
                        var params = [
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: size.baseAddress),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: format)),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: rowBytes),
                            mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: bytes.baseAddress),
                            mpv_render_param()]
                        return mpv_render_context_render(renderContext, &params)
                    }
                }
            }
        }
        guard status >= 0, let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
 }
#endif

#if os(macOS)
struct MPVPlayerSurface: NSViewRepresentable {
    let engine: MPVPlaybackEngine

    func makeNSView(context: Context) -> MPVMacView { MPVMacView(engine: engine)! }
    func updateNSView(_ view: MPVMacView, context: Context) {}
    static func dismantleNSView(_ view: MPVMacView, coordinator: ()) { view.detach() }
}

final class MPVMacView: NSOpenGLView {
    private let engine: MPVPlaybackEngine

    init?(engine: MPVPlaybackEngine) {
        self.engine = engine
        let attributes: [NSOpenGLPixelFormatAttribute] = [
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAAccelerated),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFADoubleBuffer),
            NSOpenGLPixelFormatAttribute(NSOpenGLPFAOpenGLProfile),
            NSOpenGLPixelFormatAttribute(NSOpenGLProfileVersion3_2Core),
            NSOpenGLPixelFormatAttribute(0)
        ]
        super.init(frame: .zero, pixelFormat: NSOpenGLPixelFormat(attributes: attributes))
        wantsBestResolutionOpenGLSurface = true
        openGLContext?.makeCurrentContext()
        _ = engine.attachRenderer(getProcAddress: Self.getProcAddress,
                                  update: Self.renderUpdate,
                                  updateContext: Unmanaged.passUnretained(self).toOpaque())
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        openGLContext?.makeCurrentContext()
        var fbo: GLint = 0
        glGetIntegerv(GLenum(GL_FRAMEBUFFER_BINDING), &fbo)
        let size = convertToBacking(bounds).size
        engine.render(fbo: fbo, width: Int32(size.width), height: Int32(size.height), flipY: true)
        openGLContext?.flushBuffer()
    }

    func detach() { engine.detachRenderer() }

    private static let getProcAddress: MPVGLProcAddress = { _, name in
        guard let name else { return nil }
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }
    private static let renderUpdate: mpv_render_update_fn = { context in
        guard let context else { return }
        let view = Unmanaged<MPVMacView>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { view.needsDisplay = true }
    }
}
#elseif targetEnvironment(simulator)
struct MPVPlayerSurface: UIViewRepresentable {
    let engine: MPVPlaybackEngine
    func makeUIView(context: Context) -> MPVSoftwareView { MPVSoftwareView(engine: engine) }
    func updateUIView(_ view: MPVSoftwareView, context: Context) {}
    static func dismantleUIView(_ view: MPVSoftwareView, coordinator: ()) { view.stopRendering() }
}

final class MPVSoftwareView: UIView {
    private let engine: MPVPlaybackEngine
    private var timer: Timer?
    private var rendering = false
    private var generation = 0

    init(engine: MPVPlaybackEngine) {
        self.engine = engine
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard window != nil, bounds.width > 1, bounds.height > 1,
              timer == nil, engine.attachSoftwareRenderer() else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.renderFrame() }
        }
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { timer?.invalidate(); timer = nil }
        else { setNeedsLayout() }
    }
    private func renderFrame() {
        guard window != nil, bounds.width > 1, bounds.height > 1 else { return }
        let scale = min(1, 960 / bounds.width)
        guard !rendering, let renderer = engine.softwareRenderer else { return }
        rendering = true
        let currentGeneration = generation
        renderer.frame(width: Int(bounds.width * scale), height: Int(bounds.height * scale)) { [weak self] frame in
            Task { @MainActor [weak self] in
                guard let self, self.generation == currentGeneration else { return }
                self.rendering = false
                if let frame { self.layer.contents = frame }
            }
        }
    }
    func stopRendering() {
        generation += 1
        rendering = false
        timer?.invalidate()
        timer = nil
        engine.detachRenderer()
        layer.contents = nil
    }
}
#else
struct MPVPlayerSurface: UIViewRepresentable {
    let engine: MPVPlaybackEngine

    func makeUIView(context: Context) -> MPVMetalView {
        let view = MPVMetalView(layer: engine.metalLayer) { engine.attachMetalSurface() }
        return view
    }

    func updateUIView(_ view: MPVMetalView, context: Context) {}
}

final class MPVMetalView: UIView {
    private let mpvLayer: MPVMetalLayer
    private let surfaceReady: () -> Void

    init(layer: MPVMetalLayer, surfaceReady: @escaping () -> Void) {
        mpvLayer = layer
        self.surfaceReady = surfaceReady
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsScale = UIScreen.main.scale
        layer.framebufferOnly = true
        self.layer.addSublayer(layer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 1, bounds.height > 1 else { return }
        mpvLayer.frame = bounds
        let scale = window?.screen.scale ?? contentScaleFactor
        mpvLayer.contentsScale = scale
        mpvLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        // Loading at the initial zero-sized SwiftUI layout can create a tiny
        // Vulkan swapchain that never presents a usable video frame.
        surfaceReady()
    }
}

final class MPVMetalLayer: CAMetalLayer {
    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if newValue.width > 1, newValue.height > 1 { super.drawableSize = newValue }
        }
    }
}
#endif
