import Foundation

enum OpenSubtitlesClient {
    struct Result: Identifiable, Sendable {
        let id: Int
        let language: String
        let release: String
        let downloads: Int
        let hearingImpaired: Bool
        let filename: String
    }

    private struct SearchResponse: Decodable {
        struct Entry: Decodable {
            struct Attributes: Decodable {
                struct File: Decodable {
                    let fileID: Int
                    let fileName: String
                    enum CodingKeys: String, CodingKey {
                        case fileID = "file_id", fileName = "file_name"
                    }
                }
                let language: String
                let release: String?
                let downloadCount: Int?
                let hearingImpaired: Bool?
                let files: [File]
                enum CodingKeys: String, CodingKey {
                    case language, release, files
                    case downloadCount = "download_count"
                    case hearingImpaired = "hearing_impaired"
                }
            }
            let attributes: Attributes
        }
        let data: [Entry]
        let totalPages: Int?
        enum CodingKeys: String, CodingKey { case data; case totalPages = "total_pages" }
    }

    private struct DownloadResponse: Decodable {
        let link: URL
        let fileName: String
        enum CodingKeys: String, CodingKey { case link, fileName = "file_name" }
    }

    static func search(item: MediaItem, language: String, apiKey: String, query: String? = nil, page: Int = 1, session: Login? = nil) async throws -> [Result] {
        var components = URLComponents(url: endpoint("subtitles", session: session), resolvingAgainstBaseURL: false)!
        var parameters = [URLQueryItem(name: "languages", value: language),
                          URLQueryItem(name: "page", value: String(max(1, page))),
                          URLQueryItem(name: "order_by", value: "download_count"),
                          URLQueryItem(name: "order_direction", value: "desc")]
        if let query, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            parameters.append(URLQueryItem(name: "query", value: query))
            if case .episode(_, let season, let number, _) = item.identity {
                parameters.append(URLQueryItem(name: "season_number", value: String(season)))
                parameters.append(URLQueryItem(name: "episode_number", value: String(number)))
                parameters.append(URLQueryItem(name: "type", value: "episode"))
            }
        } else if case .some(.episode(let series, let season, let number, _)) = item.identity {
            parameters.append(URLQueryItem(name: "query", value: series))
            parameters.append(URLQueryItem(name: "season_number", value: String(season)))
            parameters.append(URLQueryItem(name: "episode_number", value: String(number)))
        } else if let tmdb = item.metadata?.providerID {
            parameters.append(URLQueryItem(name: "tmdb_id", value: String(tmdb)))
        } else {
            parameters.append(URLQueryItem(name: "query", value: item.title))
        }
        components.queryItems = parameters
        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        if let session { request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization") }
        request.setValue("Lucent v1.0", forHTTPHeaderField: "User-Agent")
        let data = try await responseData(request, maximumBytes: 2_000_000)
        return try JSONDecoder().decode(SearchResponse.self, from: data).data.flatMap { entry in
            entry.attributes.files.map { file in
                Result(id: file.fileID, language: entry.attributes.language,
                       release: entry.attributes.release ?? file.fileName,
                       downloads: entry.attributes.downloadCount ?? 0,
                       hearingImpaired: entry.attributes.hearingImpaired ?? false,
                       filename: file.fileName)
            }
        }
    }

    struct Login: Codable, Sendable {
        let token: String
        let baseURL: String?
        enum CodingKeys: String, CodingKey { case token; case baseURL = "base_url" }
    }

    static func login(username: String, password: String, apiKey: String) async throws -> Login {
        var request = URLRequest(url: endpoint("login", session: nil))
        request.httpMethod = "POST"; request.timeoutInterval = 20
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Lucent v1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": username, "password": password])
        return try JSONDecoder().decode(Login.self, from: await responseData(request, maximumBytes: 100_000))
    }

    private static func endpoint(_ path: String, session: Login?) -> URL {
        if let raw = session?.baseURL {
            let text = raw.contains("://") ? raw : "https://" + raw
            if let url = URL(string: text), url.scheme == "https",
               let host = url.host?.lowercased(), host.hasSuffix(".opensubtitles.com"),
               url.user == nil, url.password == nil, url.port == nil || url.port == 443 {
                return URL(string: "https://\(host)/api/v1/\(path)")!
            }
        }
        return URL(string: "https://api.opensubtitles.com/api/v1/\(path)")!
    }

    static func download(fileID: Int, apiKey: String, session: Login? = nil) async throws -> (Data, String) {
        var request = URLRequest(url: endpoint("download", session: session))
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        if let session { request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization") }
        request.setValue("Lucent v1.0", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["file_id": fileID])
        let payload = try await responseData(request, maximumBytes: 100_000)
        let response = try JSONDecoder().decode(DownloadResponse.self, from: payload)
        guard response.link.scheme == "https",
              let host = response.link.host?.lowercased(),
              host == "opensubtitles.com" || host.hasSuffix(".opensubtitles.com") else {
            throw SubtitleServiceError.invalidDownload
        }
        let suffix = (response.fileName as NSString).pathExtension.lowercased()
        guard SubtitleParser.supportedExtensions.contains(suffix) else {
            throw SubtitleServiceError.invalidFormat
        }
        var fileRequest = URLRequest(url: response.link)
        fileRequest.timeoutInterval = 30
        let data = try await responseData(fileRequest, maximumBytes: 5_000_000)
        return (data, response.fileName)
    }

    private static func responseData(_ request: URLRequest, maximumBytes: Int) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, data.count <= maximumBytes else { throw SubtitleServiceError.requestFailed }
        if [401, 403, 406].contains(response.statusCode) { throw SubtitleServiceError.authentication }
        if [429, 407].contains(response.statusCode) { throw SubtitleServiceError.quota }
        guard (200..<300).contains(response.statusCode) else { throw SubtitleServiceError.requestFailed }
        return data
    }
}

private enum SubtitleServiceError: LocalizedError {
    case requestFailed, invalidDownload, invalidFormat, authentication, quota
    var errorDescription: String? {
        switch self {
        case .authentication: "OpenSubtitles 授权已失效，请检查 API Key 或重新登录。"
        case .quota: "OpenSubtitles 下载额度已用完或请求过于频繁，请稍后再试。"
        case .requestFailed: "在线字幕请求失败，请检查 API 密钥或下载额度。"
        case .invalidDownload: "字幕下载链接无效。"
        case .invalidFormat: "在线字幕格式暂不支持。"
        }
    }
}
