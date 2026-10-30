import Foundation

enum PlaybackDiagnosticPrivacy {
    private static let mediaURL = try! NSRegularExpression(pattern: "(?i)\\b(?:https?|ftp|smb|file)://[^\\s\\\"'<>]+")

    static func removingMediaURLs(from line: String) -> String {
        var result = line
        for match in mediaURL.matches(in: line, range: NSRange(line.startIndex..., in: line)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: "<media-url>")
        }
        return result
    }
}

/// Keep a requested resume point separate from a decoder's provisional clock.
/// A load/seek clock of zero is not a new playback checkpoint.
struct PlaybackProgressTracker {
    enum Owner { case system, aether, mpv }
    static func owner(useAether: Bool, useMPV: Bool, switchingToAether: Bool) -> Owner {
        if useMPV && (!useAether || switchingToAether) { return .mpv }
        return useAether ? .aether : .system
    }

    private let initialPosition: Double
    private(set) var resumeTarget: Double?
    private(set) var confirmedPosition: Double?
    var recoveryPosition: Double { resumeTarget ?? confirmedPosition ?? initialPosition }

    init(initialPosition: Double) {
        self.initialPosition = initialPosition.isFinite ? max(0, initialPosition) : 0
    }

    mutating func beginLoad(at position: Double) {
        resumeTarget = position.isFinite ? max(0, position) : recoveryPosition
        confirmedPosition = nil
    }

    @discardableResult
    mutating func observe(_ position: Double, ready: Bool) -> Bool {
        guard ready, position.isFinite, position >= 0 else { return false }
        if let target = resumeTarget, position + 0.75 < target { return false }
        resumeTarget = nil
        confirmedPosition = position
        return true
    }
}

enum PlaybackLogHistory {
    /// Retain ten prior sessions, bounded to 1 MiB per file. The source logs
    /// already contain engine-redacted text; no new media URLs are recorded.
    static func archiveLatest() {
        let fm = FileManager.default
        guard let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let history = documents.appendingPathComponent("PlaybackHistory", isDirectory: true)
        do {
            try fm.createDirectory(at: history, withIntermediateDirectories: true)
            let stamp = "\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
            for name in ["PlaybackAudit.log", "AetherRouting.log"] {
                let url = documents.appendingPathComponent(name)
                if let data = try? Data(contentsOf: url) {
                    try Data(data.suffix(1_048_576)).write(to: history.appendingPathComponent("\(stamp)-\(name)"), options: .atomic)
                }
            }
            let files = try fm.contentsOfDirectory(at: history, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "log" }
                .sorted {
                    ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) >
                    ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
                }
            for file in files.dropFirst(20) { try? fm.removeItem(at: file) }
        } catch { NSLog("Lucent: playback log archive failed (%ld)", (error as NSError).code) }
    }
}

struct PlaybackMediaFeatures: Sendable, Equatable {
    var container: String?
    var videoCodec: String?
    var videoCodecTag: String? = nil
    var videoProfile: String? = nil
    var videoPixelFormat: String? = nil
    var styledSubtitleStreamIndices: [Int] = []
    var defaultStyledSubtitle: Bool = false
    var audioCodec: String?
    var dynamicRange: String?
    var resolution: String?

    static let unknown = PlaybackMediaFeatures()

    mutating func merge(_ other: Self) {
        container = MediaInfoLabels.known(other.container) ?? container
        videoCodec = MediaInfoLabels.known(other.videoCodec) ?? videoCodec
        videoCodecTag = MediaInfoLabels.known(other.videoCodecTag) ?? videoCodecTag
        videoProfile = MediaInfoLabels.known(other.videoProfile) ?? videoProfile
        videoPixelFormat = MediaInfoLabels.known(other.videoPixelFormat) ?? videoPixelFormat
        audioCodec = MediaInfoLabels.known(other.audioCodec) ?? audioCodec
        dynamicRange = MediaInfoLabels.known(other.dynamicRange) ?? dynamicRange
        resolution = MediaInfoLabels.known(other.resolution) ?? resolution
        styledSubtitleStreamIndices = other.styledSubtitleStreamIndices
        defaultStyledSubtitle = other.defaultStyledSubtitle
    }
}

enum MediaInfoLabels {
    static func known(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, !["unknown", "none", "n/a", "待识别"].contains(value.lowercased()) else { return nil }
        return value
    }

    static func codec(_ value: String?) -> String? {
        guard let value = known(value) else { return nil }
        switch value.lowercased() {
        case "h264", "avc", "avc1", "avc3": return "H.264"
        case "hevc", "h265", "hvc1", "hev1", "dvhe", "dvh1": return "HEVC"
        case "eac3", "ec-3": return "E-AC-3"
        case "ac3", "ac-3": return "AC-3"
        case "aac", "mp4a": return "AAC"
        case "truehd", "mlp": return "TrueHD"
        case "dca", "dts": return "DTS"
        case "alac": return "ALAC"
        case "av01", "av1": return "AV1"
        default: return value.uppercased()
        }
    }

    static func container(_ value: String?, filename: String? = nil) -> String? {
        guard let value = known(value), !["bin", "strm", "stream", "original", "lavf"].contains(value.lowercased()) else { return nil }
        if value.lowercased().contains("matroska") { return "Matroska / WebM" }
        if value.lowercased().contains("mov,mp4") {
            let ext = filename.map { ($0 as NSString).pathExtension.lowercased() } ?? ""
            if ["mov", "mp4", "m4a", "m4v", "3gp", "3g2", "mj2"].contains(ext) { return ext.uppercased() }
            return "MP4 / MOV"
        }
        switch value.lowercased() {
        case "hls", "m3u8": return "HLS"
        case "mpegts": return "MPEG-TS"
        default: return value.uppercased()
        }
    }

    static func dynamicRange(transfer: String?, matrix: String? = nil) -> String? {
        if matrix?.lowercased().contains("dolby") == true { return "Dolby Vision" }
        guard let transfer = known(transfer)?.lowercased() else { return nil }
        if transfer == "pq" || transfer.contains("2084") { return "HDR · PQ" }
        if transfer.contains("hlg") || transfer == "arib-std-b67" { return "HLG" }
        if ["bt.1886", "bt.709", "bt709", "srgb", "gamma2.2", "gamma2.8"].contains(transfer) ||
            transfer.contains("709") || transfer.contains("srgb") { return "SDR" }
        return nil
    }
}

struct PlaybackDiagnostics: Sendable, Equatable {
    enum Engine: String, Sendable {
        case preparing = "准备中"
        case native = "系统播放器"
        case aether = "AetherEngine"
        case mpv = "MPV"
    }

    var engine: Engine = .preparing
    var delivery = "直连"
    var container = "待识别"
    var videoCodec = "待识别"
    var audioCodec = "待识别"
    var dynamicRange = "待识别"
    var resolution = "待识别"
    var routeReason = "正在准备媒体"
    var requestedDolbyVision = false
    var detectedDolbyVision = false
    var nativeVideoOutput = false
    var hasReadStreamInfo = false

    mutating func apply(_ features: PlaybackMediaFeatures, observed: Bool = false,
                        preserveSpecificHDR: Bool = false) {
        if let value = MediaInfoLabels.container(features.container) { container = value }
        if let value = MediaInfoLabels.codec(features.videoCodec) { videoCodec = value }
        if let value = MediaInfoLabels.codec(features.audioCodec) { audioCodec = value }
        if let value = MediaInfoLabels.known(features.resolution) { resolution = value }
        if let value = MediaInfoLabels.known(features.dynamicRange) {
            // MPV can expose just the base layer's PQ transfer. That does not
            // disprove a source's more specific DV/HDR10+ metadata.
            let specific = dynamicRange.lowercased().contains("dolby") || dynamicRange.contains("HDR10+")
            if !(preserveSpecificHDR && specific && value == "HDR · PQ") { dynamicRange = value }
        }
        if observed { hasReadStreamInfo = true }
    }

    func displayValue(_ value: String) -> String {
        MediaInfoLabels.known(value) ?? (hasReadStreamInfo ? "暂不可用" : "读取中")
    }

    var dolbyVisionExplanation: String? {
        guard requestedDolbyVision || detectedDolbyVision else { return nil }
        if detectedDolbyVision && (engine == .native || nativeVideoOutput) {
            return "当前流包含杜比视界描述，正由系统播放器解码；显示设备是否进入杜比视界模式仍需在设备上确认。"
        }
        if engine == .mpv {
            return "当前使用扩展播放内核；不能确认杜比视界动态元数据已输出。"
        }
        if detectedDolbyVision && engine == .aether {
            return "当前识别到杜比视界，但画面未走 AVPlayer 原生路径；不能确认杜比视界色彩已正确呈现。"
        }
        return "服务器标记为杜比视界，但当前流尚未检测到杜比视界描述。"
    }
}

/// Routes using server MediaInfo and the effective URL. Unknown metadata keeps
/// the existing container-based behavior; it is not evidence of native support.
/// Native networking owns authenticated redirects for static Emby files.
/// Engine routing must not accidentally reintroduce libmpv's remote TLS stack.
enum PlaybackTransportPolicy {
    static func mpvURL(for original: URL, embyFileProxy: URL?, isTranscoding: Bool) -> URL {
        guard !original.isFileURL, !isTranscoding, original.pathExtension.lowercased() != "m3u8",
              let proxy = embyFileProxy, proxy.scheme == "http", proxy.host == "127.0.0.1" else { return original }
        return proxy
    }
}

enum PlaybackNativeInspection {
    static func requiresInspection(url: URL, features: PlaybackMediaFeatures) -> Bool {
        let ext = url.pathExtension.lowercased()
        let container = features.container?.lowercased() ?? ext
        return ["mp4", "m4v", "mov"].contains(container) && MediaInfoLabels.known(features.videoCodecTag) == nil
    }
}

struct PlaybackRouteDecision: Sendable {
    let useMPV: Bool
    let reason: String
    let useAether: Bool

    init(useMPV: Bool, reason: String, useAether: Bool = false) {
        self.useMPV = useMPV
        self.reason = reason
        self.useAether = useAether
    }

    static func choose(preference: PlaybackEnginePreference, url: URL,
                       features: PlaybackMediaFeatures, hasStyledSubtitle: Bool,
                       hasExternalAudio: Bool, serverDolbyVision: Bool) -> Self {
        if preference == .mpv { return .init(useMPV: true, reason: "用户选择 MPV") }
        if preference == .system {
            return .init(useMPV: false, reason: "用户选择 AVPlayer",
                         useAether: features.videoCodecTag?.lowercased() == "hev1")
        }

        let name = url.lastPathComponent.uppercased()
        let urlExtension = url.pathExtension.lowercased()
        let ext = ["", "stream", "original"].contains(urlExtension) ?
            (features.container?.lowercased() ?? urlExtension) : urlExtension
        if ["VIDEO_TS", "BDMV"].contains(name) || (url.isFileURL && ext == "m3u8") ||
            ["ftp", "ftps", "sftp", "nfs"].contains(url.scheme?.lowercased() ?? "") ||
            ["bin", "mkv", "avi", "wmv", "flv", "webm", "ts", "m2ts", "mts",
             "vob", "mpg", "mpeg", "ogv", "iso"].contains(ext) {
            return .init(useMPV: true, reason: "容器或协议需由 MPV 处理")
        }
        let codec = features.videoCodec?.lowercased() ?? ""
        let profile = features.videoProfile?.lowercased() ?? ""
        let pixelFormat = features.videoPixelFormat?.lowercased() ?? ""
        if ["vc1", "vc-1", "mpeg2video", "mpeg2", "mpeg-2"].contains(codec) ||
            ((codec == "h264" || codec == "avc") &&
             (profile.contains("high 10") || profile.contains("high10") ||
              pixelFormat.contains("10le") || pixelFormat.contains("10be"))) {
            return .init(useMPV: true, reason: "视频编码不适合 AVPlayer 硬解")
        }
        if hasStyledSubtitle { return .init(useMPV: true, reason: "ASS/SSA/位图字幕保留原生样式") }
        if hasExternalAudio { return .init(useMPV: true, reason: "外挂音轨需由 MPV 处理") }
        if (features.videoCodecTag?.lowercased() == "hev1") {
            return .init(useMPV: false, reason: "HEVC hev1 优先重封装后使用原生视频路径", useAether: true)
        }
        let audio = features.audioCodec?.lowercased() ?? ""
        if ["truehd", "mlp", "dts", "dts-hd", "dca"].contains(audio) {
            return .init(useMPV: true, reason: "无损音轨不能通过当前 AVPlayer 路径直通")
        }
        if serverDolbyVision {
            return .init(useMPV: false, reason: "兼容容器优先使用系统杜比视界路径")
        }
        return .init(useMPV: false, reason: "容器与流信息适合系统播放器")
    }
}
