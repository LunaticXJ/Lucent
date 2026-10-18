import Foundation

enum CloudDriveClient {
    struct FileEntry: Sendable {
        let identifier: String
        let filename: String
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "ts", "webm", "m2ts", "mts",
        "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"
    ]

    static func scan(source: CloudSource, token: String) async throws -> [FileEntry] {
        switch source.provider {
        case .dropbox: return try await scanDropbox(token: token)
        case .googleDrive: return try await scanGoogleDrive(token: token)
        case .pan115, .pan123, .baiduPan, .guangyaPan:
            return try await ChineseCloudClient.scan(provider: source.provider, token: token)
                .map { FileEntry(identifier: $0.id, filename: $0.name) }
        }
    }

    static func readRange(source: CloudSource, token: String, identifier: String,
                          offset: UInt64, length: Int) throws -> SMBScanner.RangeResult {
        guard let request = downloadRequest(source: source, token: token, identifier: identifier) else {
            throw CloudDriveError.invalidFile
        }
        return try HTTPRangeReader.read(request: request, offset: offset, length: length)
    }

    static func readRangeAsync(source: CloudSource, token: String, identifier: String,
                               offset: UInt64, length: Int) async throws -> SMBScanner.RangeResult {
        if source.provider != .dropbox && source.provider != .googleDrive {
            let request = try await ChineseCloudClient.downloadRequest(
                provider: source.provider, token: token, identifier: identifier)
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try HTTPRangeReader.read(
                            request: request, offset: offset, length: length))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try readRange(source: source, token: token,
                                                                  identifier: identifier,
                                                                  offset: offset, length: length))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func downloadRequest(source: CloudSource, token: String, identifier: String) -> URLRequest? {
        guard !identifier.isEmpty, !token.isEmpty else { return nil }
        let url: URL
        switch source.provider {
        case .dropbox:
            guard let value = URL(string: "https://content.dropboxapi.com/2/files/download"),
                  let argument = try? JSONSerialization.data(withJSONObject: ["path": identifier]),
                  let header = String(data: argument, encoding: .utf8) else { return nil }
            url = value
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(header, forHTTPHeaderField: "Dropbox-API-Arg")
            return request
        case .googleDrive:
            guard let escaped = identifier.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
                  let value = URL(string: "https://www.googleapis.com/drive/v3/files/\(escaped)?alt=media") else {
                return nil
            }
            url = value
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            return request
        case .pan115, .pan123, .baiduPan, .guangyaPan:
            return nil
        }
    }

    static func downloadRequestAsync(source: CloudSource, token: String,
                                     identifier: String) async throws -> URLRequest {
        if let request = downloadRequest(source: source, token: token, identifier: identifier) {
            return request
        }
        return try await ChineseCloudClient.downloadRequest(
            provider: source.provider, token: token, identifier: identifier)
    }

    private struct DropboxPage: Decodable {
        struct Entry: Decodable {
            let tag: String
            let id: String?
            let name: String
            enum CodingKeys: String, CodingKey { case tag = ".tag", id, name }
        }
        let entries: [Entry]
        let cursor: String
        let hasMore: Bool
        enum CodingKeys: String, CodingKey { case entries, cursor, hasMore = "has_more" }
    }

    private static func scanDropbox(token: String) async throws -> [FileEntry] {
        var url = URL(string: "https://api.dropboxapi.com/2/files/list_folder")!
        var body: [String: Any] = ["path": "", "recursive": true,
                                   "include_deleted": false, "limit": 2000]
        var result: [FileEntry] = []
        while true {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.timeoutInterval = 40
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data = try await responseData(for: request)
            let page = try JSONDecoder().decode(DropboxPage.self, from: data)
            for entry in page.entries where entry.tag == "file" {
                guard let id = entry.id, videoExtensions.contains((entry.name as NSString).pathExtension.lowercased()) else {
                    continue
                }
                result.append(FileEntry(identifier: id, filename: entry.name))
            }
            if result.count > 50_000 { throw CloudDriveError.tooManyFiles }
            guard page.hasMore else { return result }
            url = URL(string: "https://api.dropboxapi.com/2/files/list_folder/continue")!
            body = ["cursor": page.cursor]
        }
    }

    private struct GooglePage: Decodable {
        struct Entry: Decodable {
            struct Capabilities: Decodable { let canDownload: Bool? }
            let id: String
            let name: String
            let mimeType: String?
            let capabilities: Capabilities?
        }
        let files: [Entry]
        let nextPageToken: String?
    }

    private static func scanGoogleDrive(token: String) async throws -> [FileEntry] {
        var pageToken: String?
        var result: [FileEntry] = []
        repeat {
            var url = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
            url.queryItems = [URLQueryItem(name: "q", value: "trashed = false"),
                              URLQueryItem(name: "fields", value: "nextPageToken,files(id,name,mimeType,capabilities(canDownload))"),
                              URLQueryItem(name: "pageSize", value: "1000")]
            if let pageToken { url.queryItems?.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            var request = URLRequest(url: url.url!)
            request.timeoutInterval = 40
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let data = try await responseData(for: request)
            let page = try JSONDecoder().decode(GooglePage.self, from: data)
            for entry in page.files where entry.capabilities?.canDownload != false {
                guard entry.mimeType != "application/vnd.google-apps.folder",
                      !((entry.mimeType ?? "").hasPrefix("application/vnd.google-apps.")),
                      videoExtensions.contains((entry.name as NSString).pathExtension.lowercased()) else { continue }
                result.append(FileEntry(identifier: entry.id, filename: entry.name))
            }
            if result.count > 50_000 { throw CloudDriveError.tooManyFiles }
            pageToken = page.nextPageToken
        } while pageToken != nil
        return result
    }

    private static func responseData(for request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), data.count <= 10_000_000 else {
            throw CloudDriveError.requestFailed
        }
        return data
    }
}

private enum CloudDriveError: LocalizedError {
    case requestFailed, invalidFile, tooManyFiles
    var errorDescription: String? {
        switch self {
        case .requestFailed: "云盘请求失败，请检查授权或网络连接。"
        case .invalidFile: "云盘文件已失效。"
        case .tooManyFiles: "云盘中的视频超过 50,000 个，请缩小扫描范围。"
        }
    }
}
