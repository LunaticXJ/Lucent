import Foundation
import Network

enum SSDPDiscovery {
    static func discover() async -> [URL] {
        let connection = NWConnection(host: "239.255.255.250", port: 1900, using: .udp)
        let (stream, continuation) = AsyncStream<URL>.makeStream()
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let query = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 2\r\nST: urn:schemas-upnp-org:service:ContentDirectory:1\r\n\r\n"
                connection.send(content: Data(query.utf8), completion: .contentProcessed { _ in })
                receive(on: connection, yielding: continuation)
            case .failed, .cancelled:
                continuation.finish()
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "Lucent.SSDP"))
        let collected = Task { () -> [URL] in
            var urls = Set<URL>()
            for await url in stream { urls.insert(url) }
            return urls.sorted { $0.absoluteString < $1.absoluteString }
        }
        try? await Task.sleep(for: .seconds(3))
        connection.cancel()
        continuation.finish()
        return await collected.value
    }

    private static func receive(on connection: NWConnection,
                                yielding continuation: AsyncStream<URL>.Continuation) {
        connection.receiveMessage { data, _, _, error in
            if let data, let response = String(data: data, encoding: .utf8) {
                for line in response.components(separatedBy: .newlines) {
                    let parts = line.split(separator: ":", maxSplits: 1)
                    guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "location",
                          let url = URL(string: parts[1].trimmingCharacters(in: .whitespacesAndNewlines)),
                          ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                          let host = url.host, localHost(host) else { continue }
                    continuation.yield(url)
                }
            }
            if error == nil { receive(on: connection, yielding: continuation) }
            else { continuation.finish() }
        }
    }

    private static func localHost(_ host: String) -> Bool {
        let value = host.lowercased()
        if value == "localhost" || value.hasSuffix(".local") || !value.contains(".") { return true }
        let octets = value.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return octets[0] == 10 || octets[0] == 127 ||
                (octets[0] == 192 && octets[1] == 168) ||
                (octets[0] == 172 && (16...31).contains(Int(octets[1]))) ||
                (octets[0] == 169 && octets[1] == 254)
        }
        return value.hasPrefix("fe80:") || value.hasPrefix("fc") || value.hasPrefix("fd")
    }
}
