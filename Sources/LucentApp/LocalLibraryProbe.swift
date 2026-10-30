import Foundation
import LucentAether

/// Uses the FFmpeg already isolated inside LucentAether. No second FFmpeg ABI,
/// player instance, decoder or full-file download is introduced for indexing.
enum LocalLibraryProbe {
    static func read(url: URL, container: String?) async throws -> LocalMediaTechnicalInfo {
        let cancellation = ProbeCancellation()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            let result = try await Task.detached(priority: .utility) {
                let probe = try AetherEngine.probe(url: url,
                    limits: ProbeLimits(maxInputBytes: 16 * 1024 * 1024, timeBudget: 20), cancellation: cancellation)
                var streams: [[String: Any]] = []
                if let codec = probe.videoCodecName {
                    var video: [String: Any] = ["Type": "Video", "Codec": codec,
                        "Width": Int(probe.videoWidth), "Height": Int(probe.videoHeight)]
                    video["AverageFrameRate"] = probe.videoFrameRate
                    video["Profile"] = probe.videoStreamFormat?.profile
                    video["PixelFormat"] = probe.videoStreamFormat?.pixelFormat
                    video["ColorPrimaries"] = probe.videoStreamFormat?.colorPrimaries
                    video["ColorTransfer"] = probe.videoStreamFormat?.transfer
                    video["ColorSpace"] = probe.videoStreamFormat?.matrix
                    video["VideoRangeType"] = range(probe)
                    streams.append(video)
                }
                for (kind, tracks) in [("Audio", probe.audioTracks), ("Subtitle", probe.subtitleTracks)] {
                    for track in tracks {
                        var fields: [String: Any] = ["Index": track.id, "Type": kind, "Codec": track.codec,
                            "DisplayTitle": track.name, "IsDefault": track.isDefault, "IsExternal": track.isExternal]
                        fields["Language"] = track.language
                        fields["Profile"] = track.profile
                        if track.channels > 0 { fields["Channels"] = track.channels }
                        if track.bitrate > 0 { fields["BitRate"] = track.bitrate }
                        if track.sampleRate > 0 { fields["SampleRate"] = track.sampleRate }
                        fields["ChannelLayout"] = track.channelLayout
                        streams.append(fields)
                    }
                }
                guard probe.videoWidth > 0, probe.videoHeight > 0 else { throw CocoaError(.fileReadCorruptFile) }
                return LocalMediaTechnicalInfo(probedAt: Date(), duration: probe.durationSeconds,
                    container: container?.isEmpty == false ? container : nil,
                    width: Int(probe.videoWidth), height: Int(probe.videoHeight), videoCodec: probe.videoCodecName,
                    dynamicRange: range(probe), streamData: try JSONSerialization.data(withJSONObject: streams))
            }.value
            try Task.checkCancellation()
            return result
        } onCancel: { cancellation.cancel() }
    }

    private static func range(_ probe: SourceProbe) -> String {
        switch probe.videoFormat {
        case .dolbyVision: return probe.dvProfile.map { "Dolby Vision P\($0)" } ?? "Dolby Vision"
        case .hdr10: return "HDR10"
        case .hdr10Plus: return "HDR10+"
        case .hlg: return "HLG"
        case .sdr: return "SDR"
        }
    }
}
