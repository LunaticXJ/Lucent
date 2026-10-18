import Foundation

enum PlaylistResolver {
    struct Entry: Identifiable, Sendable {
        let index: Int
        let title: String
        let url: URL
        var id: Int { index }
    }
    enum Error: LocalizedError {
        case empty
        case unsupportedAddress
        var errorDescription: String? {
            switch self {
            case .empty: "文件中没有可播放的地址。"
            case .unsupportedAddress: "播放地址必须是本地文件或受支持的网络协议。"
            }
        }
    }

    static func firstPlayableURL(in file: URL) async throws -> URL {
        guard let url = try entries(in: file).first?.url else { throw Error.empty }
        return url
    }

    static func entries(in file: URL) throws -> [Entry] {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return try parse(data, source: file)
    }

    static func entries(at url: URL) async throws -> [Entry] {
        guard url.scheme?.lowercased() == "https" || url.scheme?.lowercased() == "http" else {
            throw Error.unsupportedAddress
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Error.empty }
        return try parse(data, source: url)
    }

    private static func parse(_ data: Data, source file: URL) throws -> [Entry] {
        guard data.count <= 4_000_000 else { throw Error.empty }
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .utf16)
            ?? String(decoding: data, as: UTF8.self)
        // A local HLS manifest must be passed to the player intact.
        if file.pathExtension.lowercased() == "m3u8", text.contains("#EXT-X-") {
            return [Entry(index: 0, title: file.deletingPathExtension().lastPathComponent, url: file)]
        }
        var entries: [Entry] = []
        var pendingTitle: String?
        for line in text.components(separatedBy: .newlines)
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) {
            if line.hasPrefix("#EXTINF:") {
                pendingTitle = line.split(separator: ",", maxSplits: 1).last.map(String.init)
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let url = try playableURL(line, relativeTo: file)
            entries.append(Entry(index: entries.count,
                                 title: pendingTitle ?? url.deletingPathExtension().lastPathComponent,
                                 url: url))
            pendingTitle = nil
            guard entries.count <= 5_000 else { throw Error.empty }
        }
        guard !entries.isEmpty else { throw Error.empty }
        return entries
    }

    private static func playableURL(_ line: String, relativeTo file: URL) throws -> URL {
        if let url = URL(string: line), let scheme = url.scheme?.lowercased() {
            guard ["https", "http", "ftp", "ftps", "sftp", "rtsp", "rtmp", "file"].contains(scheme)
            else { throw Error.unsupportedAddress }
            return url
        }
        let candidate: URL
        if file.isFileURL {
            candidate = file.deletingLastPathComponent().appendingPathComponent(line)
        } else {
            guard let relative = URL(string: line, relativeTo: file) else { throw Error.unsupportedAddress }
            candidate = relative.absoluteURL
        }
        let target = candidate.isFileURL ? candidate.standardizedFileURL : candidate
        guard let scheme = target.scheme?.lowercased(),
              ["https", "http", "ftp", "ftps", "sftp", "rtsp", "rtmp", "file"].contains(scheme)
        else { throw Error.unsupportedAddress }
        if target.isFileURL, !FileManager.default.fileExists(atPath: target.path) { throw Error.empty }
        return target
    }
}
