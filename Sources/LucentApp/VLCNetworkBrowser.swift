import Foundation
import VLCKit

@MainActor
enum VLCNetworkBrowser {
    struct Video: Sendable {
        let url: URL
        let title: String
    }

    static func browse(root: URL, username: String = "", password: String? = nil) async throws -> [Video] {
        guard ["ftp", "ftps", "sftp", "nfs"].contains(root.scheme?.lowercased() ?? ""),
              root.host != nil, root.user == nil, root.password == nil else {
            throw BrowserError.invalidAddress
        }
        var pending = [root]
        var visited = Set<URL>()
        var videos: [Video] = []
        let allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm",
                                    "ts", "m2ts", "mts", "vob", "mpg", "mpeg", "iso"]
        let parser = VLCMediaParser.shared()
        while let url = pending.popLast() {
            try Task.checkCancellation()
            guard visited.insert(url).inserted else { continue }
            guard let media = VLCMedia(url: authenticated(url, username: username, password: password)) else {
                continue
            }
            let options = VLCMediaParsingOptions(rawValue: 0x01 | 0x04)
            guard parser.queue(media, options: options) == 0 else { continue }
            var completed = false
            for _ in 0..<120 {
                try await Task.sleep(for: .milliseconds(100))
                let status = media.parsedStatus.rawValue
                if status == 6 { completed = true; break }
                if status == 2 || status == 3 || status == 4 || status == 5 { break }
            }
            guard completed else { continue }
            if let children = media.subitems, children.count > 0 {
                children.lock()
                let entries: [VLCMedia] = (0..<Int(children.count)).compactMap { index in
                    children.media(at: UInt(index))
                }
                children.unlock()
                for entry in entries {
                    guard let entryURL = entry.url, entryURL.host == root.host,
                          entryURL.scheme == root.scheme,
                          var components = URLComponents(url: entryURL, resolvingAgainstBaseURL: false) else {
                        continue
                    }
                    components.user = nil
                    components.password = nil
                    guard let childURL = components.url else { continue }
                    if entry.mediaType.rawValue == 2 {
                        pending.append(childURL)
                    } else if allowed.contains(childURL.pathExtension.lowercased()) {
                        videos.append(Video(url: childURL, title: childURL.deletingPathExtension().lastPathComponent))
                    }
                }
            } else if allowed.contains(url.pathExtension.lowercased()) {
                videos.append(Video(url: url, title: url.deletingPathExtension().lastPathComponent))
            }
            if visited.count + pending.count > 50_000 || videos.count > 50_000 {
                throw BrowserError.tooManyFiles
            }
        }
        return videos
    }

    static func authenticated(_ url: URL, username: String, password: String?) -> URL {
        guard !username.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url
        }
        components.user = username
        components.password = password
        return components.url ?? url
    }
}

private enum BrowserError: LocalizedError {
    case invalidAddress, tooManyFiles
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "请输入无内嵌密码的 FTP、FTPS、SFTP 或 NFS 目录地址。"
        case .tooManyFiles: "远程目录超过扫描上限。"
        }
    }
}
