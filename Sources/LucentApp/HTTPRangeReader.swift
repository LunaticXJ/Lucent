import Foundation

enum HTTPRangeReader {
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
        let delegate = LimitedRangeDelegate(maximumBytes: length, originalURL: url,
                                            range: range)
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: queue)
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

private final class LimitedRangeDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
    private let maximumBytes: Int
    private let originalURL: URL
    private let range: String
    private var redirectCount = 0
    private var bytes = Data()
    private var response: URLResponse?
    private var error: Error?

    init(maximumBytes: Int, originalURL: URL, range: String) {
        self.maximumBytes = maximumBytes
        self.originalURL = originalURL
        self.range = range
    }

    var result: (Data?, URLResponse?, Error?) { (bytes, response, error) }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        self.response = response
        guard let http = response as? HTTPURLResponse, http.statusCode == 206,
              response.expectedContentLength < 0 || response.expectedContentLength <= Int64(maximumBytes) else {
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
        self.error = error
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
        completionHandler(redirected)
    }
}

private enum HTTPRangeError: LocalizedError {
    case invalidRange, timeout, unsupported
    var errorDescription: String? {
        switch self {
        case .invalidRange: "无效的视频读取范围。"
        case .timeout: "视频服务器响应超时。"
        case .unsupported: "服务器未正确支持视频范围读取。"
        }
    }
}
