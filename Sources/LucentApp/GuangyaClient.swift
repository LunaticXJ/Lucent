import Foundation

/// Guangya endpoints follow the guangyaclient project's documented request shape.
/// The response schema can change; reject unknown shapes instead of silently emptying a library.
enum GuangyaClient {
    struct Entry: Sendable { let id: String; let name: String }
    enum ClientError: LocalizedError {
        case invalidResponse, invalidDownloadURL, tooManyFiles
        var errorDescription: String? {
            switch self {
            case .invalidResponse: "光鸭返回了无法识别的文件列表或授权已失效。"
            case .invalidDownloadURL: "光鸭没有返回有效的 HTTPS 下载地址。"
            case .tooManyFiles: "光鸭文件超过 50,000 个，请缩小扫描范围。"
            }
        }
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "mkv", "avi", "ts", "webm", "m2ts", "mts",
        "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"
    ]

    static func scan(token: String) async throws -> [Entry] {
        var pending = [""]
        var seen = Set<String>()
        var entries: [Entry] = []
        while !pending.isEmpty {
            let parent = pending.removeFirst()
            guard seen.insert(parent).inserted else { continue }
            var page = 0
            while true {
                let body: [String: Any] = ["parentId": parent, "page": page,
                                           "pageSize": 100, "orderBy": 0, "sortType": 0]
                let json = try await request("https://api.guangyapan.com/userres/v1/file/get_file_list",
                                             token: token, body: body)
                guard let files = fileList(in: json) else { throw ClientError.invalidResponse }
                for file in files {
                    guard let id = string(file["fileId"] ?? file["id"] ?? file["resId"]),
                          let name = string(file["fileName"] ?? file["name"]) else { continue }
                    let isDirectory = (file["isDir"] as? Bool) == true
                        || (file["isDirectory"] as? Bool) == true
                        || (file["resType"] as? NSNumber)?.intValue == 2
                        || string(file["fileType"] ?? file["type"])?.lowercased() == "folder"
                        || string(file["fileType"] ?? file["type"])?.lowercased() == "directory"
                    if isDirectory {
                        pending.append(id)
                    } else if videoExtensions.contains((name as NSString).pathExtension.lowercased()) {
                        entries.append(Entry(id: id, name: name))
                    }
                }
                guard entries.count <= 50_000, pending.count <= 50_000 else {
                    throw ClientError.tooManyFiles
                }
                if files.count < 100 { break }
                page += 1
            }
        }
        return entries
    }

    static func downloadRequest(token: String, identifier: String) async throws -> URLRequest {
        let json = try await request("https://api.guangyapan.com/nd.bizuserres.s/v1/get_res_download_url",
                                     token: token, body: ["fileId": identifier])
        let data = json["data"] as? [String: Any]
        let raw = string(json["downloadUrl"] ?? json["url"] ?? data?["signedURL"]
                         ?? data?["downloadUrl"] ?? data?["url"])
            ?? string((data?["data"] as? [String: Any])?["url"])
        guard let raw, let url = URL(string: raw), url.scheme?.lowercased() == "https",
              url.host != nil else { throw ClientError.invalidDownloadURL }
        var result = URLRequest(url: url)
        result.timeoutInterval = 60
        return result
    }

    private static func request(_ address: String, token: String,
                                body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: address)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(deviceID(), forHTTPHeaderField: "did")
        request.setValue("4", forHTTPHeaderField: "dt")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), data.count <= 10_000_000,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ClientError.invalidResponse
        }
        return json
    }

    private static func fileList(in json: [String: Any]) -> [[String: Any]]? {
        if let list = json["list"] as? [[String: Any]] { return list }
        if let list = json["files"] as? [[String: Any]] { return list }
        guard let data = json["data"] as? [String: Any] else { return nil }
        return data["list"] as? [[String: Any]]
            ?? data["files"] as? [[String: Any]]
            ?? data["fileList"] as? [[String: Any]]
            ?? data["records"] as? [[String: Any]]
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String, !text.isEmpty { return text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func deviceID() -> String {
        let key = "lucent.guangya.deviceID"
        if let value = UserDefaults.standard.string(forKey: key) { return value }
        let value = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(value, forKey: key)
        return value
    }
}
