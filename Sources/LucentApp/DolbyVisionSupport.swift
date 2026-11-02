import AVFoundation

enum DolbyVisionSupport {
    static func isDolbyVision(_ stream: JellyfinItem.MediaSource.Stream) -> Bool {
        guard stream.type?.caseInsensitiveCompare("Video") == .orderedSame else { return false }
        return [stream.videoRangeType, stream.profile, stream.displayTitle, stream.codec]
            .compactMap { $0?.lowercased() }
            .contains { $0.contains("dolby vision") || $0.contains("dovi") ||
                $0.contains("dvhe") || $0.contains("dvh1") }
    }

    static func profile(_ stream: JellyfinItem.MediaSource.Stream) -> String? {
        guard isDolbyVision(stream) else { return nil }
        let value = stream.profile ?? stream.displayTitle ?? ""
        if let match = value.range(of: #"(?i)(?:profile|p)[ .-]*(5|8(?:\.4)?|10)"#,
                                   options: .regularExpression) {
            return String(value[match]).replacingOccurrences(of: #"(?i)(?:profile|p)[ .-]*"#,
                with: "", options: .regularExpression)
        }
        return nil
    }

    static func isApplePlaybackContainer(_ container: String?) -> Bool {
        guard let container else { return false }
        return ["mp4", "m4v", "mov", "m3u8"].contains(container.lowercased())
    }

    static func formatHasDolbyVision(_ description: CMFormatDescription) -> Bool {
        let subtype = CMFormatDescriptionGetMediaSubType(description)
        let fourCC = String(bytes: [UInt8((subtype >> 24) & 0xff), UInt8((subtype >> 16) & 0xff),
                                    UInt8((subtype >> 8) & 0xff), UInt8(subtype & 0xff)], encoding: .ascii)
        if fourCC == "dvh1" || fourCC == "dvhe" { return true }
        guard let extensions = CMFormatDescriptionGetExtensions(description) as? [String: Any],
              let atoms = extensions["SampleDescriptionExtensionAtoms"] as? [String: Any] else { return false }
        return atoms["dvcC"] != nil || atoms["dvvC"] != nil
    }
}
