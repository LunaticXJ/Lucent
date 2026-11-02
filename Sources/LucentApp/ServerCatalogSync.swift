import Foundation

/// Refresh only entries previously opened locally. Homepage queries discover new entries;
/// this batch validates cached IDs without importing/scanning an entire server library.
enum ServerCatalogSync {
    enum Failure: LocalizedError {
        case invalidResponse, requestFailed
        var errorDescription: String? { "服务器同步未完成，请稍后重试。" }
    }
    struct Page: Decodable {
        let items: [JellyfinItem]
        let total: Int
        enum CodingKeys: String, CodingKey { case items = "Items", total = "TotalRecordCount" }
    }
    static func cachedItems(base: String, userID: String, token: String, ids: [String]) async throws -> [JellyfinItem] {
        guard let base = URL(string: base) else { throw Failure.invalidResponse }
        var result: [JellyfinItem] = []
        for offset in stride(from: 0, to: ids.count, by: 80) {
            let batch = Array(ids[offset..<min(ids.count, offset + 80)])
            var start = 0
            repeat {
                try Task.checkCancellation()
                var components = URLComponents(url: base.appendingPathComponent("Users").appendingPathComponent(userID)
                    .appendingPathComponent("Items"), resolvingAgainstBaseURL: false)!
                components.queryItems = [.init(name: "Ids", value: batch.joined(separator: ",")),
                    .init(name: "StartIndex", value: String(start)), .init(name: "Limit", value: "80"),
                    .init(name: "EnableUserData", value: "true"), .init(name: "Fields", value: "Overview,MediaSources")]
                var request = URLRequest(url: components.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
                request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
                let (data, response) = try await URLSession.shared.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.requestFailed }
                let page = try JSONDecoder().decode(Page.self, from: data)
                guard page.total <= batch.count, page.total >= 0,
                      page.items.allSatisfy({ batch.contains($0.id) }),
                      page.items.count > 0 || start >= page.total else { throw Failure.invalidResponse }
                let known = Set(result.map(\.id))
                guard !page.items.contains(where: { known.contains($0.id) }) else { throw Failure.invalidResponse }
                result += page.items; start += page.items.count
                if start >= page.total { break }
            } while true
        }
        return result
    }
}
