import Foundation

enum WebDAVClient {
    static func scan(source: WebDAVSource, password: String?) async throws -> [String] {
        guard let base = URL(string: source.baseAddress) else { throw WebDAVError.invalidAddress }
        var pending = [base]
        var visited = Set<String>()
        var files: [String] = []
        let allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm",
                                    "m2ts", "mts", "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"]
        while let directory = pending.popLast() {
            guard visited.insert(directory.absoluteString).inserted else { continue }
            var request = authenticatedRequest(url: directory, source: source, password: password)
            request.httpMethod = "PROPFIND"
            request.setValue("1", forHTTPHeaderField: "Depth")
            request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data("<?xml version=\"1.0\"?><d:propfind xmlns:d=\"DAV:\"><d:prop><d:resourcetype/></d:prop></d:propfind>".utf8)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 207 else { throw WebDAVError.requestFailed }
            let parser = DAVResponseParser(data: data)
            let entries = try parser.parse()
            for entry in entries {
                guard let url = URL(string: entry.href, relativeTo: directory)?.absoluteURL,
                      url.scheme == base.scheme, url.host == base.host,
                      let relative = relativePath(url: url, base: base), !relative.isEmpty else { continue }
                if entry.isDirectory {
                    pending.append(url)
                } else if allowed.contains(url.pathExtension.lowercased()) {
                    files.append(relative)
                }
                if files.count > 50_000 || visited.count > 50_000 { throw WebDAVError.tooManyFiles }
            }
        }
        return files
    }

    static func readRange(source: WebDAVSource, password: String?, path: String,
                          offset: UInt64, length: Int) throws -> SMBScanner.RangeResult {
        guard let url = fileURL(source: source, path: path) else { throw WebDAVError.invalidAddress }
        let headers: [String: String]
        if source.username.isEmpty {
            headers = [:]
        } else {
            let credential = "\(source.username):\(password ?? "")"
            headers = ["Authorization": "Basic \(Data(credential.utf8).base64EncodedString())"]
        }
        return try HTTPRangeReader.read(url: url, headers: headers, offset: offset, length: length)
    }

    static func downloadRequest(source: WebDAVSource, password: String?, path: String) -> URLRequest? {
        guard let url = fileURL(source: source, path: path) else { return nil }
        return authenticatedRequest(url: url, source: source, password: password)
    }

    private static func authenticatedRequest(url: URL, source: WebDAVSource, password: String?) -> URLRequest {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if !source.username.isEmpty {
            let credential = "\(source.username):\(password ?? "")"
            request.setValue("Basic \(Data(credential.utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        }
        return request
    }

    private static func fileURL(source: WebDAVSource, path: String) -> URL? {
        guard !path.isEmpty, !path.split(separator: "/").contains(".."),
              let base = URL(string: source.baseAddress) else { return nil }
        return path.split(separator: "/").reduce(base) { $0.appendingPathComponent(String($1)) }
    }

    private static func relativePath(url: URL, base: URL) -> String? {
        let basePath = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard url.path.hasPrefix(basePath) else { return nil }
        return String(url.path.dropFirst(basePath.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}

private final class DAVResponseParser: NSObject, XMLParserDelegate {
    struct Entry { let href: String; let isDirectory: Bool }
    private let parser: XMLParser
    private var entries: [Entry] = []
    private var href = ""
    private var isDirectory = false
    private var capturingHref = false

    init(data: Data) {
        parser = XMLParser(data: data)
        super.init()
        parser.delegate = self
    }

    func parse() throws -> [Entry] {
        guard parser.parse() else { throw parser.parserError ?? WebDAVError.requestFailed }
        return entries
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = elementName.split(separator: ":").last?.lowercased() ?? ""
        if name == "response" { href = ""; isDirectory = false }
        if name == "href" { capturingHref = true }
        if name == "collection" { isDirectory = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if capturingHref { href += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = elementName.split(separator: ":").last?.lowercased() ?? ""
        if name == "href" { capturingHref = false }
        if name == "response", !href.isEmpty { entries.append(Entry(href: href, isDirectory: isDirectory)) }
    }
}

private enum WebDAVError: LocalizedError {
    case invalidAddress, requestFailed, tooManyFiles
    var errorDescription: String? {
        switch self {
        case .invalidAddress: "WebDAV 地址无效。"
        case .requestFailed: "无法读取 WebDAV 目录。"
        case .tooManyFiles: "片源过大，请选择较小的目录。"
        }
    }
}
