import Foundation
import CryptoKit
#if canImport(FoundationXML)
import FoundationXML
#endif

struct DanmakuComment: Codable, Equatable, Sendable {
    enum Mode: Int, Codable, Sendable { case scroll = 1, bottom = 4, top = 5 }
    let time: Double
    let text: String
    let color: UInt32
    let mode: Mode
}

enum DanmakuParser {
    static let maximumBytes = 15_000_000
    static func parse(_ data: Data) throws -> [DanmakuComment] {
        guard data.count <= maximumBytes else { throw DanmakuError.invalidFile }
        let data = data.starts(with: [0xEF, 0xBB, 0xBF]) ? Data(data.dropFirst(3)) : data
        let values: [DanmakuComment]
        if data.first(where: { ![9,10,13,32].contains($0) }) == 60 {
            let delegate = CommentXMLParser()
            let parser = XMLParser(data: data); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() else { throw DanmakuError.invalidFile }
            values = delegate.values
        } else {
            struct Entry: Decodable { let p: String; let m: String }
            struct Response: Decodable { let comments: [Entry] }
            let result = try JSONDecoder().decode(Response.self, from: data)
            values = result.comments.prefix(100_000).compactMap { entry in
                let fields = entry.p.split(separator: ",", omittingEmptySubsequences: false)
                guard fields.count >= 3, let time = Double(fields[0]), let mode = Int(fields[1]),
                      let color = UInt32(fields[2]) else { return nil }
                return validated(time: time, text: entry.m, color: color, mode: mode)
            }
        }
        var seen = Set<String>()
        return values.filter { seen.insert("\(Int($0.time * 10))|\($0.mode.rawValue)|\($0.text)").inserted }
            .sorted { $0.time < $1.time }
    }
    static func validated(time: Double, text: String, color: UInt32, mode: Int) -> DanmakuComment? {
        guard time.isFinite, time >= 0, time <= 7 * 24 * 3600,
              let mode = DanmakuComment.Mode(rawValue: mode) else { return nil }
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        guard !clean.isEmpty, clean.count <= 200 else { return nil }
        return .init(time: time, text: clean, color: color & 0xFFFFFF, mode: mode)
    }
    private final class CommentXMLParser: NSObject, XMLParserDelegate {
        var values: [DanmakuComment] = []
        var fields: [Substring] = []
        var text = ""
        var active = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String:String]) {
            if name == "d", values.count < 100_000 { fields = (attributes["p"] ?? "").split(separator: ",", omittingEmptySubsequences: false); text = ""; active = true }
        }
        func parser(_ parser: XMLParser, foundCharacters value: String) { if active, text.count < 1024 { text += value } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard name == "d", active else { return }; active = false
            guard fields.count >= 4, let time = Double(fields[0]), let mode = Int(fields[1]), let color = UInt32(fields[3]),
                  let comment = DanmakuParser.validated(time: time, text: text, color: color, mode: mode) else { return }
            values.append(comment)
        }
    }
}

enum DanmakuError: LocalizedError {
    case credentials, request(Int), invalidFile, noComments
    var errorDescription: String? {
        switch self {
        case .credentials: "请先在设置的字幕与弹幕服务中填写弹弹play App ID 和 Secret。"
        case .request(let code): "弹幕请求失败（\(code)），请检查服务授权或稍后再试。"
        case .invalidFile: "弹幕文件无效或超过 15 MB，支持弹弹play JSON 和 Bilibili XML。"
        case .noComments: "没有可显示的弹幕。"
        }
    }
}

enum DandanplayClient {
    struct Episode: Identifiable, Sendable {
        let id: Int64
        let anime: String
        let title: String
    }
    private struct SearchResponse: Decodable {
        struct Anime: Decodable {
            struct Episode: Decodable { let episodeId: Int64; let episodeTitle: String? }
            let animeTitle: String?; let episodes: [Episode]?
        }
        let animes: [Anime]?
    }
    static func signature(appID: String, secret: String, timestamp: String, path: String) -> String {
        Data(SHA256.hash(data: Data((appID + timestamp + path + secret).utf8))).base64EncodedString()
    }
    static func search(_ query: String, tmdbID: Int? = nil, movie: Bool = false, episode: Int? = nil) async throws -> [Episode] {
        var parameters: [URLQueryItem] = [.init(name: "v2", value: "true")]
        if let tmdbID {
            parameters += [.init(name: "tmdbId", value: String(tmdbID)), .init(name: "tmdbIdType", value: movie ? "1" : "0")]
        } else { parameters.append(.init(name: "anime", value: query)) }
        if let episode, episode > 0 { parameters.append(.init(name: "episode", value: String(episode))) }
        let data = try await fetch(path: "search/episodes", parameters: parameters)
        var seen = Set<Int64>()
        return try JSONDecoder().decode(SearchResponse.self, from: data).animes?.flatMap { anime in
            (anime.episodes ?? []).compactMap { value -> Episode? in
                guard value.episodeId > 0, seen.insert(value.episodeId).inserted else { return nil }
                return Episode(id: value.episodeId, anime: anime.animeTitle ?? query, title: value.episodeTitle ?? "未命名剧集")
            }
        } ?? []
    }
    static func comments(episodeID: Int64) async throws -> Data {
        let cache = cacheURL("episode-\(episodeID).json")
        if let date = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < 24 * 3600, let data = try? Data(contentsOf: cache),
           (try? DanmakuParser.parse(data).isEmpty) == false { return data }
        let data = try await fetch(path: "comment/\(episodeID)", parameters: [.init(name: "withRelated", value: "true")])
        guard !(try DanmakuParser.parse(data)).isEmpty else { throw DanmakuError.noComments }
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: cache, options: .atomic)
        trimCache(keeping: cache)
        return data
    }
    private static func trimCache(keeping current: URL) {
        let files = (try? FileManager.default.contentsOfDirectory(at: current.deletingLastPathComponent(),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: .skipsHiddenFiles)) ?? []
        let entries = files.compactMap { url -> (URL, Int, Date)? in
            guard let info = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, info.fileSize ?? 0, info.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var bytes = entries.reduce(0) { $0 + $1.1 }
        for (url, size, date) in entries where url != current {
            if bytes > 100 * 1024 * 1024 || Date().timeIntervalSince(date) > 24 * 3600 {
                if (try? FileManager.default.removeItem(at: url)) != nil { bytes -= size }
            }
        }
    }
    static func cacheURL(_ name: String) -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Danmaku", isDirectory: true).appendingPathComponent(name)
    }
    private static func fetch(path: String, parameters: [URLQueryItem]) async throws -> Data {
        guard let appID = try KeychainPasswordStore.playbackServiceSecret("dandan-app-id"), !appID.isEmpty,
              let secret = try KeychainPasswordStore.playbackServiceSecret("dandan-secret"), !secret.isEmpty else { throw DanmakuError.credentials }
        var components = URLComponents(string: "https://api.dandanplay.net/api/v2/\(path)")!
        components.queryItems = parameters
        let timestamp = String(Int(Date().timeIntervalSince1970))
        var request = URLRequest(url: components.url!); request.timeoutInterval = 25
        request.setValue(appID, forHTTPHeaderField: "X-AppId")
        request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
        request.setValue(signature(appID: appID, secret: secret, timestamp: timestamp, path: components.path), forHTTPHeaderField: "X-Signature")
        request.setValue("Lucent/1.0", forHTTPHeaderField: "User-Agent")
        // Strip signing headers when the provider redirects comment bodies to its CDN.
        let delegate = DandanRedirectDelegate()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DanmakuError.request(0) }
        guard http.statusCode == 200 else { throw DanmakuError.request(http.statusCode) }
        guard data.count <= DanmakuParser.maximumBytes else { throw DanmakuError.invalidFile }
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any], body["success"] as? Bool == false {
            throw DanmakuError.request(body["errorCode"] as? Int ?? -1)
        }
        return data
    }
}

private final class DandanRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard request.url?.scheme == "https" else { completionHandler(nil); return }
        var safe = request
        if request.url?.host != "api.dandanplay.net" {
            for key in ["X-AppId", "X-AppSecret", "X-Timestamp", "X-Signature", "Authorization"] { safe.setValue(nil, forHTTPHeaderField: key) }
        }
        completionHandler(safe)
    }
}
