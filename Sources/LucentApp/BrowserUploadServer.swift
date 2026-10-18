import Foundation
import Network
import Darwin

/// A deliberately small, session-scoped LAN upload endpoint. The random path is shown only on device.
final class BrowserUploadServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.lucent.browser-upload")
    private let token = UUID().uuidString.replacingOccurrences(of: "-", with: "")
    private let destination: URL
    private let completed: @Sendable (URL) -> Void
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private let maxBytes: Int64 = 20 * 1024 * 1024 * 1024

    init(destination: URL, completed: @escaping @Sendable (URL) -> Void) {
        self.destination = destination
        self.completed = completed
    }

    func start() async throws -> URL {
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let listener = try NWListener(using: .tcp, on: .any)
        setListener(listener)
        return try await withCheckedThrowingContinuation { continuation in
            let gate = UploadContinuationGate(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port,
                          let host = Self.lanAddress(),
                          let url = URL(string: "http://\(host):\(port.rawValue)/\(self.token)/") else {
                        gate.resume(.failure(UploadError.noAddress)); return
                    }
                    gate.resume(.success(url))
                case .failed(let error): gate.resume(.failure(error))
                case .cancelled: gate.resume(.failure(UploadError.stopped))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.start(queue: queue)
        }
    }

    private func setListener(_ value: NWListener) {
        lock.lock()
        listener = value
        lock.unlock()
    }

    func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        let connections = self.connections
        self.connections = []
        lock.unlock()
        connections.forEach { $0.cancel() }
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        lock.lock()
        guard listener != nil, connections.count < 4 else { lock.unlock(); connection.cancel(); return }
        connections.append(connection)
        lock.unlock()
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            if case .cancelled = state, let connection {
                self?.lock.lock(); self?.connections.removeAll { $0 === connection }; self?.lock.unlock()
            }
        }
        connection.start(queue: queue)
        readHeader(connection, accumulated: Data())
    }

    private func readHeader(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }
            guard error == nil else { connection.cancel(); return }
            if let separator = buffer.range(of: Data("\r\n\r\n".utf8)) {
                guard separator.lowerBound <= 16_384 else { self.reply(connection, code: 413); return }
                self.handle(connection, header: Data(buffer[..<separator.lowerBound]),
                            body: Data(buffer[separator.upperBound...]))
            } else if buffer.count > 16_384 { self.reply(connection, code: 413) }
            else if done { connection.cancel() }
            else { self.readHeader(connection, accumulated: buffer) }
        }
    }

    private func handle(_ connection: NWConnection, header: Data, body: Data) {
        guard let text = String(data: header, encoding: .utf8),
              let line = text.components(separatedBy: "\r\n").first else { reply(connection, code: 400); return }
        let parts = line.split(separator: " ")
        guard parts.count == 3 else { reply(connection, code: 400); return }
        let root = "/\(token)/"
        if parts[0] == "GET", parts[1] == Substring(root) {
            let html = """
            <!doctype html><html lang="zh"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
            <title>Lucent 上传</title><body style="font:18px system-ui;max-width:600px;margin:12vh auto;padding:24px">
            <h1>传送到 Lucent</h1><input id="files" type="file" accept="video/*,.mkv,.avi,.ts,.iso" multiple>
            <p id="status"></p><script>
            const picker=document.getElementById('files'), message=document.getElementById('status');
            picker.onchange=async()=>{for(const f of picker.files){message.textContent='正在上传 '+f.name;
            const r=await fetch(location.pathname+'upload/'+encodeURIComponent(f.name),{method:'PUT',body:f});
            message.textContent=f.name+(r.ok?' 已完成':' 失败 ('+r.status+')');}}
            </script></body></html>
            """
            reply(connection, code: 200, body: Data(html.utf8), type: "text/html; charset=utf-8")
            return
        }
        guard parts[0] == "PUT", parts[1].hasPrefix(root + "upload/"),
              let rawName = String(parts[1].dropFirst((root + "upload/").count)).removingPercentEncoding,
              !rawName.isEmpty, rawName == (rawName as NSString).lastPathComponent,
              !rawName.contains("\\"), !rawName.contains("/"), !rawName.hasPrefix("."),
              let sizeLine = text.components(separatedBy: "\r\n").first(where: { $0.lowercased().hasPrefix("content-length:") }),
              let length = Int64(sizeLine.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)),
              length > 0, length <= maxBytes, Int64(body.count) <= length else {
            reply(connection, code: 400); return
        }
        let ext = (rawName as NSString).pathExtension.lowercased()
        guard ["mp4", "m4v", "mov", "mkv", "avi", "webm", "ts", "m2ts", "mpg", "mpeg", "iso"].contains(ext) else {
            reply(connection, code: 415); return
        }
        #if os(tvOS)
        let free = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity
        #else
        let free = try? destination.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage
        #endif
        if let free,
           Int64(free) < length + 128 * 1024 * 1024 {
            reply(connection, code: 507); return
        }
        let staging = destination.appendingPathComponent(UUID().uuidString + ".part")
        guard FileManager.default.createFile(atPath: staging.path, contents: nil),
              let file = try? FileHandle(forWritingTo: staging) else { reply(connection, code: 500); return }
        receiveBody(connection, file: file, staging: staging, name: rawName, remaining: length, chunk: body)
    }

    private func receiveBody(_ connection: NWConnection, file: FileHandle, staging: URL,
                             name: String, remaining: Int64, chunk: Data) {
        do {
            try file.write(contentsOf: chunk)
            let left = remaining - Int64(chunk.count)
            if left == 0 {
                try file.close()
                let target = uniqueDestination(name)
                try FileManager.default.moveItem(at: staging, to: target)
                completed(target)
                reply(connection, code: 201)
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, done, error in
                guard let self else { return }
                guard error == nil, let data, !data.isEmpty, Int64(data.count) <= left else {
                    try? file.close(); try? FileManager.default.removeItem(at: staging)
                    connection.cancel(); return
                }
                if done && Int64(data.count) < left {
                    try? file.close(); try? FileManager.default.removeItem(at: staging)
                    connection.cancel()
                } else {
                    self.receiveBody(connection, file: file, staging: staging, name: name, remaining: left, chunk: data)
                }
            }
        } catch {
            try? file.close(); try? FileManager.default.removeItem(at: staging)
            reply(connection, code: 500)
        }
    }

    private func uniqueDestination(_ name: String) -> URL {
        var url = destination.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var suffix = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = destination.appendingPathComponent("\(base) (\(suffix)).\(ext)")
            suffix += 1
        }
        return url
    }

    private func reply(_ connection: NWConnection, code: Int, body: Data = Data(), type: String = "text/plain") {
        let phrase = [200:"OK", 201:"Created", 400:"Bad Request", 413:"Payload Too Large",
                      415:"Unsupported Media Type", 500:"Internal Server Error",
                      507:"Insufficient Storage"][code] ?? "Error"
        let header = Data("HTTP/1.1 \(code) \(phrase)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        connection.send(content: header + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private static func lanAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0 else { return nil }
        defer { freeifaddrs(list) }
        var cursor = list
        while let current = cursor {
            let item = current.pointee
            if item.ifa_addr.pointee.sa_family == UInt8(AF_INET),
               (item.ifa_flags & UInt32(IFF_LOOPBACK)) == 0 {
                var address = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let size = socklen_t(item.ifa_addr.pointee.sa_len)
                if getnameinfo(item.ifa_addr, size, &address, socklen_t(address.count), nil, 0, NI_NUMERICHOST) == 0 {
                    return String(decoding: address.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) },
                                  as: UTF8.self)
                }
            }
            cursor = item.ifa_next
        }
        return nil
    }
}

private enum UploadError: Error { case noAddress, stopped }

private final class UploadContinuationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?

    init(_ continuation: CheckedContinuation<URL, Error>) { self.continuation = continuation }

    func resume(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
