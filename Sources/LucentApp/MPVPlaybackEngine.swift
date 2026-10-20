import Foundation
import Libmpv
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
    private var loadedURL: URL?
    private var pendingURL: URL?
    private(set) var ended = false
    private(set) var playbackError: String?
    #if !os(macOS)
    let metalLayer = MPVMetalLayer()
    private var metalSurfaceAttached = false
    #endif

    init?() {
        guard let handle = mpv_create() else { return nil }
        self.handle = handle
        mpv_set_option_string(handle, "config", "no")
        #if os(macOS)
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
    }

    func load(_ url: URL) {
        loadedURL = url
        ended = false
        playbackError = nil
        #if os(macOS)
        let surfaceReady = renderContext != nil
        #else
        let surfaceReady = metalSurfaceAttached
        #endif
        if !surfaceReady {
            pendingURL = url
        } else {
            command("loadfile", [url.absoluteString, "replace"])
        }
    }

    #if !os(macOS)
    func attachMetalSurface() {
        metalSurfaceAttached = true
        if let pendingURL {
            self.pendingURL = nil
            command("loadfile", [pendingURL.absoluteString, "replace"])
        }
    }
    #endif

    func pollEvents() {
        guard let handle else { return }
        while let event = mpv_wait_event(handle, 0), event.pointee.event_id != MPV_EVENT_NONE {
            switch event.pointee.event_id {
            case MPV_EVENT_END_FILE:
                if let data = event.pointee.data?.assumingMemoryBound(to: mpv_event_end_file.self) {
                    switch data.pointee.reason {
                    case MPV_END_FILE_REASON_EOF:
                        ended = true
                    case MPV_END_FILE_REASON_ERROR:
                        playbackError = "MPV 播放失败（\(data.pointee.error)）。"
                    default: break
                    }
                }
            default:
                break
            }
        }
    }

    func stop() {
        command("stop")
        loadedURL = nil
        pendingURL = nil
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
    var isSeekable: Bool { (flagProperty("seekable") ?? 0) != 0 }
    var hasVideoOutput: Bool { (intProperty("video-params/w") ?? 0) > 0 }

    func setPaused(_ paused: Bool) { set("pause", paused ? "yes" : "no") }
    func setRate(_ rate: Float) { set("speed", String(rate)) }
    func seek(to seconds: Double) { command("seek", [String(seconds), "absolute", "exact"]) }
    func setAudioTrack(_ index: Int) {
        guard let id = trackIDs(type: "audio").indices.contains(index) ? trackIDs(type: "audio")[index] : nil else { return }
        set("aid", String(id))
    }
    func setSubtitleTrack(_ index: Int?) {
        guard let index else { set("sid", "no"); return }
        let ids = trackIDs(type: "sub")
        guard ids.indices.contains(index) else { return }
        set("sid", String(ids[index]))
    }
    func setSubtitleDelay(_ seconds: Double) { set("sub-delay", String(seconds)) }
    func setAspectRatio(_ ratio: String?) { set("video-aspect-override", ratio ?? "no") }
    func addSubtitle(_ url: URL) { command("sub-add", [url.absoluteString, "select"]) }
    func addAudio(_ url: URL) { command("audio-add", [url.absoluteString, "select"]) }

    func trackNames(type: String) -> [String] {
        let count = max(0, min(128, Int(intProperty("track-list/count") ?? 0)))
        return (0..<count).compactMap { index in
            guard stringProperty("track-list/\(index)/type") == type else { return nil }
            let title = stringProperty("track-list/\(index)/title")
                ?? stringProperty("track-list/\(index)/lang")
            return title?.isEmpty == false ? title : "\(type == "audio" ? "音轨" : "字幕") \(index + 1)"
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
        let status = mpv_command(handle, &pointers)
        if status < 0 { NSLog("Lucent MPV: command %@ failed (%d)", name, status) }
    }

    private func set(_ property: String, _ value: String) {
        guard let handle else { return }
        let status = mpv_set_property_string(handle, property, value)
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
            command("loadfile", [pendingURL.absoluteString, "replace"])
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

    func detachRenderer() {
        guard let renderContext else { return }
        mpv_render_context_set_update_callback(renderContext, nil, nil)
        mpv_render_context_free(renderContext)
        self.renderContext = nil
    }
}

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
#else
struct MPVPlayerSurface: UIViewRepresentable {
    let engine: MPVPlaybackEngine

    func makeUIView(context: Context) -> MPVMetalView {
        let view = MPVMetalView(layer: engine.metalLayer)
        engine.attachMetalSurface()
        return view
    }

    func updateUIView(_ view: MPVMetalView, context: Context) {}
}

final class MPVMetalView: UIView {
    private let mpvLayer: MPVMetalLayer

    init(layer: MPVMetalLayer) {
        mpvLayer = layer
        super.init(frame: .zero)
        backgroundColor = .black
        layer.contentsScale = UIScreen.main.scale
        layer.framebufferOnly = true
        self.layer.addSublayer(layer)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        mpvLayer.frame = bounds
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
