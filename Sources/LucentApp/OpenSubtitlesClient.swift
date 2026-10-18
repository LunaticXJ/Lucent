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
    }

    private struct DownloadResponse: Decodable {
        let link: URL
        let fileName: String
        enum CodingKeys: String, CodingKey { case link, fileName = "file_name" }
    }

    static func search(item: MediaItem, language: String, apiKey: String) async throws -> [Result] {
        var components = URLComponents(string: "https://api.opensubtitles.com/api/v1/subtitles")!
        var parameters = [URLQueryItem(name: "languages", value: language),
                          URLQueryItem(name: "order_by", value: "download_count"),
                          URLQueryItem(name: "order_direction", value: "desc")]
        if case .some(.episode(let series, let season, let number, _)) = item.identity {
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
        request.setValue("Lucent/1.0", forHTTPHeaderField: "User-Agent")
        let data = try await responseData(request, maximumBytes: 2_000_000)
        return try JSONDecoder().decode(SearchResponse.self, from: data).data.compactMap { entry in
            guard let file = entry.attributes.files.first else { return nil }
            return Result(id: file.fileID, language: entry.attributes.language,
                          release: entry.attributes.release ?? file.fileName,
                          downloads: entry.attributes.downloadCount ?? 0,
                          hearingImpaired: entry.attributes.hearingImpaired ?? false,
                          filename: file.fileName)
        }
    }

    static func download(fileID: Int, apiKey: String) async throws -> (Data, String) {
        var request = URLRequest(url: URL(string: "https://api.opensubtitles.com/api/v1/download")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "Api-Key")
        request.setValue("Lucent/1.0", forHTTPHeaderField: "User-Agent")
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
        guard let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode), data.count <= maximumBytes else {
            throw SubtitleServiceError.requestFailed
        }
        return data
    }
}

private enum SubtitleServiceError: LocalizedError {
    case requestFailed, invalidDownload, invalidFormat
    var errorDescription: String? {
        switch self {
        case .requestFailed: "在线字幕请求失败，请检查 API 密钥或下载额度。"
        case .invalidDownload: "字幕下载链接无效。"
        case .invalidFormat: "在线字幕格式暂不支持。"
        }
    }
}
