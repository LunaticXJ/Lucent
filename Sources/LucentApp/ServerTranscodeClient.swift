import Foundation

/// Builds server-managed HLS streams at an explicit bitrate. The server selects
/// a compatible codec and reports failures through its HLS response.
enum ServerTranscodeClient {
    static func jellyfin(baseAddress: String, itemID: String, token: String,
                         mediaSourceID: String?, bitrate: Int,
                         audioIndex: Int? = nil, subtitleIndex: Int? = nil) -> URL? {
        mediaBrowserURL(baseAddress: baseAddress, itemID: itemID, token: token,
                        mediaSourceID: mediaSourceID, bitrate: bitrate,
                        audioIndex: audioIndex, subtitleIndex: subtitleIndex)
    }

    static func emby(baseAddress: String, itemID: String, token: String,
                     mediaSourceID: String?, bitrate: Int,
                     audioIndex: Int? = nil, subtitleIndex: Int? = nil) -> URL? {
        mediaBrowserURL(baseAddress: baseAddress, itemID: itemID, token: token,
                        mediaSourceID: mediaSourceID, bitrate: bitrate,
                        audioIndex: audioIndex, subtitleIndex: subtitleIndex)
    }

    private static func mediaBrowserURL(baseAddress: String, itemID: String, token: String,
                                        mediaSourceID: String?, bitrate: Int,
                                        audioIndex: Int?, subtitleIndex: Int?) -> URL? {
        guard let base = URL(string: baseAddress), bitrate > 0, !token.isEmpty else { return nil }
        let url = base.appendingPathComponent("Videos").appendingPathComponent(itemID)
            .appendingPathComponent("master.m3u8")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: token),
            URLQueryItem(name: "DeviceId", value: deviceID()),
            URLQueryItem(name: "MaxStreamingBitrate", value: String(bitrate)),
            URLQueryItem(name: "VideoCodec", value: "h264"),
            URLQueryItem(name: "AudioCodec", value: "aac"),
            URLQueryItem(name: "TranscodingContainer", value: "ts"),
            URLQueryItem(name: "TranscodingProtocol", value: "hls"),
            URLQueryItem(name: "SegmentContainer", value: "ts")
        ]
        if let mediaSourceID {
            components?.queryItems?.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID))
        }
        if let audioIndex {
            components?.queryItems?.append(URLQueryItem(name: "AudioStreamIndex", value: String(audioIndex)))
        }
        if let subtitleIndex {
            components?.queryItems?.append(URLQueryItem(name: "SubtitleStreamIndex", value: String(subtitleIndex)))
        }
        return components?.url
    }

    private static func deviceID() -> String {
        let key = "lucent.mediaBrowser.deviceID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }

    static func plex(baseAddress: String, ratingKey: String, token: String,
                     bitrate: Int, sessionID: UUID, mediaIndex: Int = 0) -> URL? {
        guard let base = URL(string: baseAddress), bitrate > 0, !token.isEmpty else { return nil }
        let url = base.appendingPathComponent("video/:/transcode/universal/start.m3u8")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "path", value: "/library/metadata/\(ratingKey)"),
            URLQueryItem(name: "mediaIndex", value: String(mediaIndex)),
            URLQueryItem(name: "protocol", value: "hls"),
            URLQueryItem(name: "directPlay", value: "0"),
            URLQueryItem(name: "directStream", value: "0"),
            URLQueryItem(name: "videoBitrate", value: String(bitrate / 1000)),
            URLQueryItem(name: "session", value: sessionID.uuidString),
            URLQueryItem(name: "X-Plex-Token", value: token),
            URLQueryItem(name: "X-Plex-Client-Identifier", value: plexClientID())
        ]
        return components?.url
    }

    static func stopPlex(baseAddress: String, token: String, sessionID: UUID) async {
        guard let base = URL(string: baseAddress) else { return }
        let url = base.appendingPathComponent("video/:/transcode/universal/stop")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "session", value: sessionID.uuidString),
                                  URLQueryItem(name: "X-Plex-Token", value: token)]
        guard let finalURL = components?.url else { return }
        _ = try? await URLSession.shared.data(from: finalURL)
    }

    private static func plexClientID() -> String {
        let key = "lucent.plex.clientIdentifier"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
