import Foundation
import Network

/// Bridges authenticated range reads to AVPlayer's ordinary HTTP byte-range requests.
final class RangeHTTPServer: @unchecked Sendable {
    private let readRange: @Sendable (UInt64, Int) throws -> SMBScanner.RangeResult
    private let asyncReadRange: (@Sendable (UInt64, Int) async throws -> SMBScanner.RangeResult)?
    private let onReadFailure: (@Sendable (Error) -> Void)?
    private let maxReadAttempts: Int
    private let fileExtension: String
    private let token = UUID().uuidString
    private let queue = DispatchQueue(label: "com.lucent.range-http")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var cachedTotalSize: UInt64?
    private var running = false
    var supportsSynchronousInputStream: Bool { asyncReadRange == nil }

    init(source: SMBSource, password: String?, path: String) {
        fileExtension = Self.safeExtension((path as NSString).pathExtension)
        asyncReadRange = nil
        onReadFailure = nil
        maxReadAttempts = 3
        readRange = { offset, length in
            try SMBScanner.readRange(source: source, password: password, path: path,
                                     offset: offset, length: length)
        }
    }

    init(fileExtension: String, maxReadAttempts: Int = 3,
         readRange: @escaping @Sendable (UInt64, Int) throws -> SMBScanner.RangeResult,
         onReadFailure: (@Sendable (Error) -> Void)? = nil) {
        self.fileExtension = Self.safeExtension(fileExtension)
        self.readRange = readRange
        asyncReadRange = nil
        self.onReadFailure = onReadFailure
        self.maxReadAttempts = max(1, maxReadAttempts)
    }

    init(fileExtension: String,
         asyncReadRange: @escaping @Sendable (UInt64, Int) async throws -> SMBScanner.RangeResult) {
        self.fileExtension = Self.safeExtension(fileExtension)
        readRange = { _, _ in throw RangeHTTPError.asyncOnly }
        self.asyncReadRange = asyncReadRange
        onReadFailure = nil
        maxReadAttempts = 3
    }

    func makeInputStream() -> RangeInputStream {
        RangeInputStream { [self] offset, length in
            try readWithRetry(offset: offset, length: length)
        }
    }

    func start() async throws -> URL {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters, on: .any)
        setListener(listener)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
            let gate = ContinuationGate(continuation)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        gate.resume(.failure(RangeHTTPError.noPort))
                        return
                    }
                    guard let self,
                          let url = URL(string: "http://127.0.0.1:\(port.rawValue)/\(self.token)/video.\(self.fileExtension)") else {
                        gate.resume(.failure(RangeHTTPError.noPort))
                        return
                    }
                    gate.resume(.success(url))
                case .failed(let error):
                    gate.resume(.failure(error))
                case .cancelled:
                    gate.resume(.failure(RangeHTTPError.cancelled))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        lock.lock()
        running = false
        let listener = self.listener
        self.listener = nil
        let connections = self.connections
        self.connections.removeAll()
        lock.unlock()
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    private func setListener(_ listener: NWListener) {
        lock.lock()
        self.listener = listener
        running = true
        lock.unlock()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard running, connections.count < 16 else {
            lock.unlock()
            connection.cancel()
            return
        }
        connections.append(connection)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard case .cancelled = state, let connection else { return }
            self?.remove(connection)
        }
        connection.start(queue: queue)
        receiveRequest(connection, data: Data())
    }

    private func remove(_ connection: NWConnection) {
        lock.lock()
        connections.removeAll { $0 === connection }
        lock.unlock()
    }

    private func receiveRequest(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] chunk, _, complete, error in
            guard let self else { return }
            var request = data
            if let chunk { request.append(chunk) }
            if request.count > 16_384 || error != nil {
                connection.cancel()
                return
            }
            if let marker = request.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(connection, request: Data(request[..<marker.upperBound]))
            } else if complete {
                connection.cancel()
            } else {
                self.receiveRequest(connection, data: request)
            }
        }
    }

    private func handle(_ connection: NWConnection, request: Data) {
        guard let text = String(data: request, encoding: .utf8),
              let firstLine = text.components(separatedBy: "\r\n").first else {
            sendError(connection, status: "400 Bad Request")
            return
        }
        let parts = firstLine.split(separator: " ")
        guard parts.count == 3, ["GET", "HEAD"].contains(parts[0]),
              parts[1] == "/\(token)/video.\(fileExtension)" else {
            sendError(connection, status: "404 Not Found")
            return
        }
        let headOnly = parts[0] == "HEAD"
        let rangeHeader = text.components(separatedBy: "\r\n").first {
            $0.lowercased().hasPrefix("range:")
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let size: UInt64
                if let cached = self.lock.withLock({ self.cachedTotalSize }) {
                    size = cached
                } else {
                    size = try await self.readWithRetryAsync(offset: 0, length: 1).totalSize
                }
                guard size > 0 else {
                    self.sendError(connection, status: "416 Range Not Satisfiable")
                    return
                }
                let requested = self.parseRange(rangeHeader, size: size)
                guard let requested else {
                    self.sendError(connection, status: "416 Range Not Satisfiable")
                    return
                }
                let partial = rangeHeader != nil
                let length = requested.end - requested.start + 1
                let status = partial ? "206 Partial Content" : "200 OK"
                var headers = "HTTP/1.1 \(status)\r\nContent-Type: \(self.contentType)\r\nAccept-Ranges: bytes\r\nContent-Length: \(length)\r\nConnection: close\r\n"
                if partial { headers += "Content-Range: bytes \(requested.start)-\(requested.end)/\(size)\r\n" }
                headers += "\r\n"
                if headOnly {
                    connection.send(content: Data(headers.utf8), completion: .contentProcessed { _ in connection.cancel() })
                } else {
                    // Do not advertise a successful response until the upstream
                    // source has actually supplied the first block. Otherwise a
                    // failed signed CDN redirect looks like endless buffering.
                    let firstLength = Int(min(1_048_576, length))
                    let first = try await self.readWithRetryAsync(offset: requested.start, length: firstLength)
                    guard !first.data.isEmpty, UInt64(first.data.count) <= length else {
                        self.sendError(connection, status: "502 Bad Gateway")
                        return
                    }
                    var response = Data(headers.utf8)
                    response.append(first.data)
                    let next = requested.start + UInt64(first.data.count)
                    connection.send(content: response, completion: .contentProcessed { error in
                        if error != nil || next > requested.end { connection.cancel() }
                        else { self.sendBytes(connection, offset: next, end: requested.end) }
                    })
                }
            } catch {
                self.sendError(connection, status: "502 Bad Gateway")
            }
        }
    }

    private func parseRange(_ header: String?, size: UInt64) -> (start: UInt64, end: UInt64)? {
        guard let header else { return (0, size - 1) }
        let value = header.dropFirst(6).trimmingCharacters(in: .whitespaces)
        guard value.hasPrefix("bytes="), !value.contains(",") else { return nil }
        let components = value.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
        guard components.count == 2 else { return nil }
        if components[0].isEmpty {
            guard let suffix = UInt64(components[1]), suffix > 0 else { return nil }
            return (size - min(size, suffix), size - 1)
        }
        guard let start = UInt64(components[0]), start < size else { return nil }
        let end: UInt64
        if components[1].isEmpty { end = size - 1 }
        else {
            guard let parsed = UInt64(components[1]) else { return nil }
            end = min(parsed, size - 1)
        }
        guard end >= start else { return nil }
        return (start, end)
    }

    private func sendBytes(_ connection: NWConnection, offset: UInt64, end: UInt64) {
        guard offset <= end else { connection.cancel(); return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let length = Int(min(1_048_576, end - offset + 1))
                let result = try await self.readWithRetryAsync(offset: offset, length: length)
                guard !result.data.isEmpty else { connection.cancel(); return }
                connection.send(content: result.data, completion: .contentProcessed { error in
                    if error != nil { connection.cancel() }
                    else { self.sendBytes(connection, offset: offset + UInt64(result.data.count), end: end) }
                })
            } catch {
                connection.cancel()
            }
        }
    }

    private func sendError(_ connection: NWConnection, status: String) {
        connection.send(content: Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                        completion: .contentProcessed { _ in connection.cancel() })
    }

    private func readWithRetry(offset: UInt64, length: Int) throws -> SMBScanner.RangeResult {
        var lastError: Error = RangeHTTPError.cancelled
        for attempt in 0..<maxReadAttempts {
            lock.lock()
            let active = running
            lock.unlock()
            guard active else { throw RangeHTTPError.cancelled }
            do {
                let result = try readRange(offset, length)
                lock.withLock { cachedTotalSize = result.totalSize }
                return result
            }
            catch {
                lastError = error
                if attempt + 1 < maxReadAttempts { Thread.sleep(forTimeInterval: 0.25 * Double(1 << attempt)) }
            }
        }
        onReadFailure?(lastError)
        throw lastError
    }

    private func readWithRetryAsync(offset: UInt64, length: Int) async throws -> SMBScanner.RangeResult {
        guard let asyncReadRange else { return try readWithRetry(offset: offset, length: length) }
        var lastError: Error = RangeHTTPError.cancelled
        for attempt in 0..<3 {
            let active = lock.withLock { running }
            guard active else { throw RangeHTTPError.cancelled }
            do {
                let result = try await asyncReadRange(offset, length)
                lock.withLock { cachedTotalSize = result.totalSize }
                return result
            }
            catch {
                lastError = error
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(Int64(250 * (1 << attempt)))) }
            }
        }
        throw lastError
    }

    private var contentType: String {
        switch fileExtension {
        case "mp4", "m4v": "video/mp4"
        case "mov": "video/quicktime"
        case "mkv": "video/x-matroska"
        case "webm": "video/webm"
        case "ts": "video/mp2t"
        case "avi": "video/x-msvideo"
        default: "application/octet-stream"
        }
    }

    private static func safeExtension(_ value: String) -> String {
        let normalized = value.lowercased()
        return ["mp4", "m4v", "mov", "mkv", "webm", "ts", "m2ts", "mts", "avi",
                "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso"].contains(normalized) ? normalized : "mp4"
    }
}

private final class ContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false
    private let continuation: CheckedContinuation<URL, Error>

    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        guard !completed else { lock.unlock(); return }
        completed = true
        lock.unlock()
        continuation.resume(with: result)
    }
}

private enum RangeHTTPError: LocalizedError {
    case noPort, cancelled, asyncOnly
    var errorDescription: String? { "无法启动本机播放服务。" }
}
