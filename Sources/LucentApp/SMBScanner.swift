import Foundation
import SwiftSMB

enum SMBScanner {
    struct RangeResult: Sendable {
        let data: Data
        let totalSize: UInt64
    }

    static func scan(source: SMBSource, password: String?) throws -> [String] {
        let credentials = SMB.Credentials(
            user: source.username.isEmpty ? nil : source.username,
            password: password
        )
        let connection = try SMB.connect(
            server: SMB.Server(host: source.host),
            credentials: credentials,
            share: source.share,
            configuration: SMB.Configuration(timeout: 20)
        )
        defer { try? connection.disconnect() }
        let allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm",
                                    "m2ts", "mts", "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"]
        var pending = [""]
        var videos: [String] = []
        while let path = pending.popLast() {
            let entries = try connection.listDirectory(at: path)
            for entry in entries where entry.name != "." && entry.name != ".." {
                let child = path.isEmpty ? entry.name : "\(path)/\(entry.name)"
                switch entry.stat.type {
                case .directory:
                    pending.append(child)
                case .file:
                    if allowed.contains((entry.name as NSString).pathExtension.lowercased()) {
                        videos.append(child)
                    }
                default:
                    break
                }
                if videos.count > 50_000 { throw SMBScanError.tooManyFiles }
            }
        }
        return videos
    }

    static func readRange(source: SMBSource, password: String?, path: String,
                          offset: UInt64, length: Int) throws -> RangeResult {
        guard length > 0, length <= 1_048_576, offset <= UInt64(Int64.max) else {
            throw SMBScanError.invalidRange
        }
        let credentials = SMB.Credentials(user: source.username.isEmpty ? nil : source.username,
                                          password: password)
        let connection = try SMB.connect(server: SMB.Server(host: source.host),
                                         credentials: credentials, share: source.share,
                                         configuration: SMB.Configuration(timeout: 20))
        defer { try? connection.disconnect() }
        let file = try connection.openFile(at: path)
        defer { try? file.close() }
        let info = try file.stat()
        guard offset < info.size else { return RangeResult(data: Data(), totalSize: info.size) }
        try file.seek(offset: Int64(offset), from: .start)
        let data = try file.read(upTo: Int64(min(UInt64(length), info.size - offset)))
        return RangeResult(data: data, totalSize: info.size)
    }
}

private enum SMBScanError: LocalizedError {
    case tooManyFiles
    case invalidRange
    var errorDescription: String? {
        switch self {
        case .tooManyFiles: "片源超过 50,000 个视频文件，请选择较小的共享目录。"
        case .invalidRange: "无效的文件读取范围。"
        }
    }
}
