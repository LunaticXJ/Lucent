import Foundation

/// Official cloud file APIs. Tokens are supplied by the caller and never persisted here.
enum ChineseCloudClient {
    struct Entry: Sendable {
        let id: String
        let name: String
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "ts", "webm", "m2ts", "mts",
        "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"
    ]

    static func scan(provider: CloudProvider, token: String) async throws -> [Entry] {
        switch provider {
        case .pan115: return try await scan115(token: token)
        case .pan123: return try await scan123(token: token)
        case .baiduPan: return try await scanBaidu(token: token)
        case .guangyaPan:
            return try await GuangyaClient.scan(token: token).map { Entry(id: $0.id, name: $0.name) }
        default: throw Error.apiUnavailable
        }
    }

    static func downloadRequest(provider: CloudProvider, token: String,
                                identifier: String) async throws -> URLRequest {
        let url: URL
        switch provider {
        case .pan115:
            var request = URLRequest(url: URL(string: "https://proapi.115.com/open/ufile/downurl")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("Lucent/0.1", forHTTPHeaderField: "User-Agent")
            request.httpBody = form(["pick_code": identifier])
            let json = try await object(request)
            guard let data = json["data"] as? [String: Any] else { throw Error.invalidResponse }
            let item = data.values.compactMap { $0 as? [String: Any] }.first
            let urlString = (item?["url"] as? [String: Any])?["url"] as? String
                ?? item?["url"] as? String
            guard let urlString, let parsed = URL(string: urlString), parsed.scheme == "https" else {
                throw Error.invalidResponse
            }
            url = parsed
        case .pan123:
            var components = URLComponents(string: "https://open-api.123pan.com/api/v1/file/download_info")!
            components.queryItems = [URLQueryItem(name: "fileId", value: identifier)]
            var request = URLRequest(url: components.url!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("open_platform", forHTTPHeaderField: "Platform")
            let json = try await object(request)
            guard let data = json["data"] as? [String: Any],
                  let urlString = data["downloadUrl"] as? String,
                  let parsed = URL(string: urlString), parsed.scheme == "https" else {
                throw Error.invalidResponse
            }
            url = parsed
        case .baiduPan:
            var components = URLComponents(string: "https://pan.baidu.com/rest/2.0/xpan/multimedia")!
            components.queryItems = [URLQueryItem(name: "method", value: "filemetas"),
                                     URLQueryItem(name: "openapi", value: "xpansdk"),
                                     URLQueryItem(name: "fsids", value: "[\(identifier)]"),
                                     URLQueryItem(name: "dlink", value: "1"),
                                     URLQueryItem(name: "access_token", value: token)]
            let json = try await object(URLRequest(url: components.url!))
            guard let data = json["list"] as? [[String: Any]],
                  let urlString = data.first?["dlink"] as? String,
                  var parsed = URLComponents(string: urlString), parsed.scheme == "https" else {
                throw Error.invalidResponse
            }
            if !(parsed.queryItems ?? []).contains(where: { $0.name == "access_token" }) {
                parsed.queryItems = (parsed.queryItems ?? []) + [URLQueryItem(name: "access_token", value: token)]
            }
            guard let final = parsed.url else { throw Error.invalidResponse }
            url = final
        case .guangyaPan:
            return try await GuangyaClient.downloadRequest(token: token, identifier: identifier)
        case .dropbox, .googleDrive:
            throw Error.apiUnavailable
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        if provider == .pan115 { request.setValue("Lucent/0.1", forHTTPHeaderField: "User-Agent") }
        if provider == .baiduPan { request.setValue("pan.baidu.com", forHTTPHeaderField: "User-Agent") }
        return request
    }

    private static func scan115(token: String) async throws -> [Entry] {
        var folders = ["0"]
        var seen = Set<String>()
        var result: [Entry] = []
        while !folders.isEmpty {
            let folder = folders.removeFirst()
            guard seen.insert(folder).inserted else { continue }
            var offset = 0
            while true {
                var components = URLComponents(string: "https://proapi.115.com/open/ufile/files")!
                components.queryItems = [URLQueryItem(name: "cid", value: folder),
                                         URLQueryItem(name: "limit", value: "1000"),
                                         URLQueryItem(name: "offset", value: String(offset)),
                                         URLQueryItem(name: "show_dir", value: "1")]
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let json = try await object(request)
                guard let data = json["data"] as? [String: Any],
                      let files = data["data"] as? [[String: Any]] else { throw Error.invalidResponse }
                for file in files {
                    guard let name = file["fn"] as? String else { continue }
                    let category = String(describing: file["fc"] ?? "")
                    if category == "0" {
                        if let id = file["fid"] { folders.append(String(describing: id)) }
                    } else if video(name), let pickCode = file["pc"] as? String {
                        result.append(Entry(id: pickCode, name: name))
                    }
                }
                try checkLimit(result.count, folders.count)
                offset += files.count
                let total = (data["count"] as? NSNumber)?.intValue ?? offset
                if files.isEmpty || offset >= total { break }
            }
        }
        return result
    }

    private static func scan123(token: String) async throws -> [Entry] {
        var folders = ["0"]
        var seen = Set<String>()
        var result: [Entry] = []
        while !folders.isEmpty {
            let folder = folders.removeFirst()
            guard seen.insert(folder).inserted else { continue }
            var lastFileID: String?
            repeat {
                var components = URLComponents(string: "https://open-api.123pan.com/api/v2/file/list")!
                components.queryItems = [URLQueryItem(name: "parentFileId", value: folder),
                                         URLQueryItem(name: "limit", value: "100")]
                if let lastFileID {
                    components.queryItems?.append(URLQueryItem(name: "lastFileId", value: lastFileID))
                }
                var request = URLRequest(url: components.url!)
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("open_platform", forHTTPHeaderField: "Platform")
                let json = try await object(request)
                guard (json["code"] as? NSNumber)?.intValue == 0,
                      let data = json["data"] as? [String: Any],
                      let files = data["fileList"] as? [[String: Any]] else { throw Error.invalidResponse }
                for file in files {
                    guard let id = file["fileId"], let name = file["filename"] as? String else { continue }
                    if (file["type"] as? NSNumber)?.intValue == 1 {
                        folders.append(String(describing: id))
                    } else if video(name) {
                        result.append(Entry(id: String(describing: id), name: name))
                    }
                }
                try checkLimit(result.count, folders.count)
                let cursor = String(describing: data["lastFileId"] ?? "-1")
                lastFileID = cursor == "-1" || files.isEmpty ? nil : cursor
            } while lastFileID != nil
        }
        return result
    }

    private static func scanBaidu(token: String) async throws -> [Entry] {
        var folders = ["/"]
        var seen = Set<String>()
        var result: [Entry] = []
        while !folders.isEmpty {
            let folder = folders.removeFirst()
            guard seen.insert(folder).inserted else { continue }
            var start = 0
            while true {
                var components = URLComponents(string: "https://pan.baidu.com/rest/2.0/xpan/file")!
                components.queryItems = [URLQueryItem(name: "method", value: "list"),
                                         URLQueryItem(name: "dir", value: folder),
                                         URLQueryItem(name: "start", value: String(start)),
                                         URLQueryItem(name: "limit", value: "1000"),
                                         URLQueryItem(name: "access_token", value: token)]
                let json = try await object(URLRequest(url: components.url!))
                guard (json["errno"] as? NSNumber)?.intValue == 0,
                      let files = json["list"] as? [[String: Any]] else { throw Error.invalidResponse }
                for file in files {
                    guard let name = file["server_filename"] as? String else { continue }
                    if (file["isdir"] as? NSNumber)?.intValue == 1 {
                        if let path = file["path"] as? String { folders.append(path) }
                    } else if video(name), let id = file["fs_id"] {
                        result.append(Entry(id: String(describing: id), name: name))
                    }
                }
                try checkLimit(result.count, folders.count)
                if files.count < 1000 { break }
                start += files.count
            }
        }
        return result
    }

    private static func video(_ name: String) -> Bool {
        videoExtensions.contains((name as NSString).pathExtension.lowercased())
    }

    private static func checkLimit(_ files: Int, _ folders: Int) throws {
        if files > 50_000 || folders > 50_000 { throw Error.tooManyFiles }
    }

    private static func form(_ values: [String: String]) -> Data {
        var components = URLComponents()
        components.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((components.percentEncodedQuery ?? "").utf8)
    }

    private static func object(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), data.count <= 10_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Error.invalidResponse
        }
        return json
    }

    enum Error: LocalizedError {
        case apiUnavailable, invalidResponse, tooManyFiles
        var errorDescription: String? {
            switch self {
            case .apiUnavailable: "该网盘的正式开放接口尚未取得，暂不能直连。"
            case .invalidResponse: "云盘返回了无法识别的数据或授权已失效。"
            case .tooManyFiles: "云盘文件过多，请缩小扫描范围。"
            }
        }
    }
}
