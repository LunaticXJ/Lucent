import Foundation

struct PlaybackMediaFeatures: Sendable {
    var container: String?
    var videoCodec: String?
    var audioCodec: String?
    var dynamicRange: String?
    var resolution: String?

    static let unknown = PlaybackMediaFeatures()
}

struct PlaybackDiagnostics: Sendable {
    enum Engine: String, Sendable {
        case preparing = "准备中"
        case native = "系统播放器"
        case vlc = "VLCKit"
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

    var dolbyVisionExplanation: String? {
        guard requestedDolbyVision || detectedDolbyVision else { return nil }
        if detectedDolbyVision && engine == .native {
            return "当前流包含杜比视界描述，正由系统播放器解码；显示设备是否进入杜比视界模式仍需在设备上确认。"
        }
        if engine == .vlc {
            return "当前使用 VLCKit；不能确认杜比视界动态元数据已输出。"
        }
        return "服务器标记为杜比视界，但当前流尚未检测到杜比视界描述。"
    }
}
