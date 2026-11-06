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

struct CustomDanmakuServer: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name = ""
    var address = ""
    var enabled = true
    var displayName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    func endpoint() throws -> DandanplayClient.Server {
        guard !displayName.isEmpty else { throw DanmakuError.invalidServer }
        return try .custom(id: id.uuidString, name: displayName, address: address)
    }
}

enum CustomDanmakuServers {
    static let key = "lucent.danmaku.customServers"
    static func decode(_ data: Data) -> [CustomDanmakuServer] {
        (try? JSONDecoder().decode([CustomDanmakuServer].self, from: data)) ?? []
    }
    static func available(_ data: Data) -> [DandanplayClient.Server] {
        decode(data).filter(\.enabled).compactMap { try? $0.endpoint() }
    }
}

enum DanmakuError: LocalizedError {
    case credentials, request(Int), invalidFile, noComments, invalidServer, invalidResponse
    static func message(for error: Error) -> String {
        if let error = error as? URLError {
            if error.code == .appTransportSecurityRequiresSecureConnection {
                return "系统阻止了此 HTTP 连接，请使用 HTTPS 地址。"
            }
            return "连接失败，请检查服务器地址和网络。"
        }
        return error.localizedDescription
    }
    var errorDescription: String? {
        switch self {
        case .credentials: "请先在设置的弹幕服务中填写弹弹play App ID 和 Secret，或选择自定义弹幕 API。"
        case .request(let code): "弹幕请求失败（\(code)），请检查服务授权或稍后再试。"
        case .invalidFile: "弹幕文件无效或超过 15 MB，支持弹弹play JSON 和 Bilibili XML。"
        case .noComments: "没有可显示的弹幕。"
        case .invalidServer: "请输入名称和有效的 HTTP 或 HTTPS API 地址。"
        case .invalidResponse: "服务器未返回兼容弹弹play协议的数据，请检查 API 地址。"
        }
    }
}

enum DandanplayClient {
    struct Server: Identifiable, Hashable, Sendable {
        let id: String
        let name: String
        let baseURL: URL
        var isOfficial: Bool { id == "official" }
        static let official = Server(id: "official", name: "弹弹play", baseURL: URL(string: "https://api.dandanplay.net/api/v2")!)
        static func custom(id: String, name: String, address: String) throws -> Server {
            let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
            guard var components = URLComponents(string: text),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil, components.fragment == nil else { throw DanmakuError.invalidServer }
            components.scheme = components.scheme?.lowercased()
            var path = components.percentEncodedPath
            while path.hasSuffix("/") { path.removeLast() }
            if !path.hasSuffix("/api/v2") { path += "/api/v2" }
            components.percentEncodedPath = path
            guard let url = components.url else { throw DanmakuError.invalidServer }
            return Server(id: "custom:" + id, name: name, baseURL: url)
        }
    }
    struct Episode: Identifiable, Sendable {
        let id: Int64
        let anime: String
        let title: String
        var server: Server = .official
    }
    private struct SearchResponse: Decodable {
        struct Anime: Decodable {
            struct Episode: Decodable { let episodeId: Int64; let episodeTitle: String? }
            let animeTitle: String?; let episodes: [Episode]?
        }
        let animes: [Anime]
    }
    static func signature(appID: String, secret: String, timestamp: String, path: String) -> String {
        Data(SHA256.hash(data: Data((appID + timestamp + path + secret).utf8))).base64EncodedString()
    }
    static func search(_ query: String, tmdbID: Int? = nil, movie: Bool = false, episode: Int? = nil, server: Server = .official) async throws -> [Episode] {
        var parameters: [URLQueryItem] = [.init(name: "v2", value: "true")]
        if let tmdbID, server.isOfficial {
            parameters += [.init(name: "tmdbId", value: String(tmdbID)), .init(name: "tmdbIdType", value: movie ? "1" : "0")]
        } else { parameters.append(.init(name: "anime", value: query)) }
        if let episode, episode > 0 { parameters.append(.init(name: "episode", value: String(episode))) }
        let data = try await fetch(path: "search/episodes", parameters: parameters, server: server)
        return try decodeSearch(data, query: query, server: server)
    }
    static func decodeSearch(_ data: Data, query: String, server: Server) throws -> [Episode] {
        guard let response = try? JSONDecoder().decode(SearchResponse.self, from: data) else { throw DanmakuError.invalidResponse }
        var seen = Set<Int64>()
        return response.animes.flatMap { anime in
            (anime.episodes ?? []).compactMap { value -> Episode? in
                guard value.episodeId > 0, seen.insert(value.episodeId).inserted else { return nil }
                return Episode(id: value.episodeId, anime: anime.animeTitle ?? query, title: value.episodeTitle ?? "未命名剧集", server: server)
            }
        }
    }
    static func comments(episodeID: Int64, server: Server = .official) async throws -> Data {
        let cache = commentsCacheURL(episodeID: episodeID, server: server)
        if let date = try? cache.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(date) < 24 * 3600, let data = try? Data(contentsOf: cache),
           (try? DanmakuParser.parse(data).isEmpty) == false { return data }
        let data = try await fetch(path: "comment/\(episodeID)", parameters: [.init(name: "withRelated", value: "true"), .init(name: "format", value: "json")], server: server)
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
    static func commentsCacheURL(episodeID: Int64, server: Server) -> URL {
        let scope = SHA256.hash(data: Data(server.baseURL.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return cacheURL("\(scope)-episode-\(episodeID).json")
    }
    static func makeRequest(path: String, parameters: [URLQueryItem], server: Server,
                            appID: String? = nil, secret: String? = nil,
                            timestamp: String = String(Int(Date().timeIntervalSince1970))) throws -> URLRequest {
        guard var components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false) else { throw DanmakuError.invalidServer }
        components.percentEncodedPath += "/" + path
        let names = Set(parameters.map(\.name))
        components.queryItems = (components.queryItems ?? []).filter { !names.contains($0.name) } + parameters
        guard let url = components.url else { throw DanmakuError.invalidServer }
        var request = URLRequest(url: url); request.timeoutInterval = 25
        if server.isOfficial {
            guard let appID, !appID.isEmpty, let secret, !secret.isEmpty else { throw DanmakuError.credentials }
            request.setValue(appID, forHTTPHeaderField: "X-AppId")
            request.setValue(timestamp, forHTTPHeaderField: "X-Timestamp")
            request.setValue(signature(appID: appID, secret: secret, timestamp: timestamp, path: components.path), forHTTPHeaderField: "X-Signature")
        }
        return request
    }
    private static func fetch(path: String, parameters: [URLQueryItem], server: Server) async throws -> Data {
        // Never read or forward official credentials to a user-defined endpoint.
        let appID = server.isOfficial ? try KeychainPasswordStore.playbackServiceSecret("dandan-app-id") : nil
        let secret = server.isOfficial ? try KeychainPasswordStore.playbackServiceSecret("dandan-secret") : nil
        var request = try makeRequest(path: path, parameters: parameters, server: server, appID: appID, secret: secret)
        request.setValue("Lucent/1.0", forHTTPHeaderField: "User-Agent")
        // Strip signing headers when the provider redirects comment bodies to its CDN.
        let delegate = DandanRedirectDelegate(origin: server.baseURL)
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

final class DandanRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let origin: URL
    init(origin: URL) { self.origin = origin }
    func redirectedRequest(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, ["http", "https"].contains(url.scheme ?? ""),
              !(origin.scheme == "https" && url.scheme != "https") else { return nil }
        var safe = request
        func port(_ url: URL) -> Int { url.port ?? (url.scheme == "https" ? 443 : 80) }
        if url.host != origin.host || url.scheme != origin.scheme || port(url) != port(origin) {
            for key in ["X-AppId", "X-AppSecret", "X-Timestamp", "X-Signature", "Authorization", "Cookie"] {
                safe.setValue(nil, forHTTPHeaderField: key)
            }
        }
        return safe
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(redirectedRequest(request))
    }
}
