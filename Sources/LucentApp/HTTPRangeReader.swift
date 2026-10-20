import Foundation

enum HTTPRangeReader {
    private static let compatibleOrigins = CompatibleOriginCache()
    private static let signedRedirects = SignedRedirectCache()

    static func read(url: URL, headers: [String: String], offset: UInt64,
                     length: Int) throws -> SMBScanner.RangeResult {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        return try read(request: request, offset: offset, length: length)
    }

    static func read(request original: URLRequest, offset: UInt64,
                     length: Int) throws -> SMBScanner.RangeResult {
        guard length > 0, length <= 1_048_576,
              offset <= UInt64.max - UInt64(length), let url = original.url else {
            throw HTTPRangeError.invalidRange
        }
        var request = original
        request.timeoutInterval = 25
        let range = "bytes=\(offset)-\(offset + UInt64(length) - 1)"
        request.setValue(range, forHTTPHeaderField: "Range")
        // 115 signs its CDN redirects for the client's User-Agent. Keep a stable
        // value on the Emby request and every redirected range request.
        let userAgent = request.value(forHTTPHeaderField: "User-Agent") ?? "Python-urllib/3.9"
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let origin = "\(url.scheme?.lowercased() ?? "")://\(url.host?.lowercased() ?? ""):\(url.port ?? 0)"
        let redirectKey = url.absoluteString + "|" +
            (request.value(forHTTPHeaderField: "X-Emby-Token") ?? "")
        if let cachedURL = signedRedirects.url(for: redirectKey) {
            var cachedRequest = URLRequest(url: cachedURL)
            cachedRequest.timeoutInterval = request.timeoutInterval
            cachedRequest.setValue(range, forHTTPHeaderField: "Range")
            cachedRequest.setValue(userAgent, forHTTPHeaderField: "User-Agent")
            let cachedDelegate = LimitedRangeDelegate(maximumBytes: length, originalURL: cachedURL,
                                                      range: range, userAgent: userAgent)
            if let result = try? perform(request: cachedRequest, offset: offset, length: length,
                                         delegate: cachedDelegate, bypassProxy: true, tls12: false) {
                return result
            }
            signedRedirects.remove(redirectKey)
        }
        if compatibleOrigins.contains(origin) {
            let compatible = LimitedRangeDelegate(maximumBytes: length, originalURL: url,
                                                  range: range, userAgent: userAgent)
            do {
                let result = try perform(request: request, offset: offset, length: length,
                                         delegate: compatible, bypassProxy: true, tls12: false)
                if let redirect = compatible.signedRedirectURL {
                    signedRedirects.insert(redirect, for: redirectKey)
                }
                return result
            } catch {
                compatibleOrigins.remove(origin)
            }
        }
        let delegate = LimitedRangeDelegate(maximumBytes: length, originalURL: url,
                                            range: range, userAgent: userAgent)
        do {
            let result = try perform(request: request, offset: offset, length: length,
                                     delegate: delegate, bypassProxy: false, tls12: false)
            if let redirect = delegate.signedRedirectURL {
                signedRedirects.insert(redirect, for: redirectKey)
            }
            return result
        } catch {
            guard delegate.redirectedTo115 else { throw error }
            let retry = LimitedRangeDelegate(maximumBytes: length, originalURL: url,
                                             range: range, userAgent: userAgent)
            do {
                let result = try perform(request: request, offset: offset, length: length,
                                         delegate: retry, bypassProxy: true, tls12: false)
                compatibleOrigins.insert(origin)
                if let redirect = retry.signedRedirectURL {
                    signedRedirects.insert(redirect, for: redirectKey)
                }
                return result
            } catch {
                // A few CDN edges also reject TLS 1.3. Refresh the signed URL
                // once more and retry without the system proxy over TLS 1.2.
                let legacy = LimitedRangeDelegate(maximumBytes: length, originalURL: url,
                                                  range: range, userAgent: userAgent)
                let result = try perform(request: request, offset: offset, length: length,
                                         delegate: legacy, bypassProxy: true, tls12: true)
                if let redirect = legacy.signedRedirectURL {
                    signedRedirects.insert(redirect, for: redirectKey)
                }
                return result
            }
        }
    }

    private static func perform(request: URLRequest, offset: UInt64, length: Int,
                                delegate: LimitedRangeDelegate, bypassProxy: Bool,
                                tls12: Bool) throws -> SMBScanner.RangeResult {
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        if bypassProxy { configuration.connectionProxyDictionary = [:] }
        if tls12 { configuration.tlsMaximumSupportedProtocolVersion = .TLSv12 }
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: queue)
        let task = session.dataTask(with: request)
        task.resume()
        guard delegate.semaphore.wait(timeout: .now() + 30) == .success else {
            task.cancel()
            session.invalidateAndCancel()
            throw HTTPRangeError.timeout
        }
        session.invalidateAndCancel()
        let (data, response, error) = delegate.result
        if let error { throw error }
        guard let response = response as? HTTPURLResponse,
              response.statusCode == 206,
              let range = response.value(forHTTPHeaderField: "Content-Range"),
              let data, !data.isEmpty, data.count <= length,
              let parsed = parseContentRange(range),
              parsed.start == offset,
              parsed.end >= parsed.start,
              parsed.end - parsed.start + 1 == UInt64(data.count),
              parsed.total > parsed.end else { throw HTTPRangeError.unsupported }
        return SMBScanner.RangeResult(data: data, totalSize: parsed.total)
    }

    private static func parseContentRange(_ header: String) -> (start: UInt64, end: UInt64, total: UInt64)? {
        let text = header.trimmingCharacters(in: .whitespaces)
        guard text.lowercased().hasPrefix("bytes ") else { return nil }
        let values = text.dropFirst(6).split(separator: "/", omittingEmptySubsequences: false)
        guard values.count == 2, let total = UInt64(values[1]) else { return nil }
        let bounds = values[0].split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2, let start = UInt64(bounds[0]), let end = UInt64(bounds[1]) else { return nil }
        return (start, end, total)
    }
}

private final class CompatibleOriginCache: @unchecked Sendable {
    private let lock = NSLock()
    private var origins = Set<String>()

    func contains(_ origin: String) -> Bool { lock.withLock { origins.contains(origin) } }
    func insert(_ origin: String) { lock.withLock { _ = origins.insert(origin) } }
    func remove(_ origin: String) { lock.withLock { _ = origins.remove(origin) } }
}

private final class SignedRedirectCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (URL, Date)] = [:]

    func url(for key: String) -> URL? {
        lock.withLock {
            guard let entry = entries[key], entry.1 > Date() else {
                entries.removeValue(forKey: key)
                return nil
            }
            return entry.0
        }
    }

    func insert(_ url: URL, for key: String) {
        lock.withLock { entries[key] = (url, Date().addingTimeInterval(30)) }
    }

    func remove(_ key: String) { lock.withLock { entries.removeValue(forKey: key) } }
}

private final class LimitedRangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let maximumBytes: Int
    private let originalURL: URL
    private let range: String
    private let userAgent: String
    private var redirectCount = 0
    private(set) var redirectedTo115 = false
    private(set) var signedRedirectURL: URL?
    private var bytes = Data()
    private var response: URLResponse?
    private var error: Error?

    init(maximumBytes: Int, originalURL: URL, range: String, userAgent: String) {
        self.maximumBytes = maximumBytes
        self.originalURL = originalURL
        self.range = range
        self.userAgent = userAgent
    }

    var result: (Data?, URLResponse?, Error?) { (bytes, response, error) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        guard let http = response as? HTTPURLResponse else {
            error = HTTPRangeError.unsupported
            completionHandler(.cancel)
            return
        }
        guard http.statusCode == 206 else {
            error = HTTPRangeError.httpStatus(http.statusCode)
            completionHandler(.cancel)
            return
        }
        guard response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumBytes) else {
            error = HTTPRangeError.unsupported
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= maximumBytes else {
            dataTask.cancel()
            return
        }
        bytes.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = self.error ?? error
        semaphore.signal()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let destination = request.url,
              let scheme = destination.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              redirectCount < 5 else {
            completionHandler(nil)
            return
        }
        redirectCount += 1
        if destination.host?.lowercased().hasSuffix(".115cdn.net") == true {
            redirectedTo115 = true
            signedRedirectURL = destination
        }
        let sameOrigin = destination.scheme?.caseInsensitiveCompare(originalURL.scheme ?? "") == .orderedSame &&
            destination.host?.caseInsensitiveCompare(originalURL.host ?? "") == .orderedSame &&
            destination.port == originalURL.port
        // Remote media servers may redirect static streams to a CDN. Keep the
        // byte range, but never forward the server's authorization to that host.
        guard sameOrigin || scheme == "https" else {
            completionHandler(nil)
            return
        }
        var redirected = request
        if !sameOrigin {
            for name in ["Authorization", "Proxy-Authorization", "Cookie", "X-Emby-Token",
                         "X-Emby-Authorization", "X-Jellyfin-Token", "X-Plex-Token"] {
                redirected.setValue(nil, forHTTPHeaderField: name)
            }
        }
        redirected.setValue(range, forHTTPHeaderField: "Range")
        redirected.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        completionHandler(redirected)
    }
}

private enum HTTPRangeError: LocalizedError {
    case invalidRange, timeout, unsupported, httpStatus(Int)
    var errorDescription: String? {
        switch self {
        case .invalidRange: "无效的视频读取范围。"
        case .timeout: "视频服务器响应超时。"
        case .unsupported: "服务器未正确支持视频范围读取。"
        case .httpStatus(let code): "视频源返回 HTTP \(code)。"
        }
    }
}
