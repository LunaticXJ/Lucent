import Foundation

/// Fetch explicitly scoped IDs in bounded batches; never discover or scan a whole library.
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
    static func batches(ids: [String]) -> [[String]] {
        let unique = Array(Set(ids)).sorted()
        return stride(from: 0, to: unique.count, by: 80).map {
            Array(unique[$0..<min(unique.count, $0 + 80)])
        }
    }
    static func cachedItems(base: String, userID: String, token: String, ids: [String], fields: String = "Overview,MediaSources") async throws -> [JellyfinItem] {
        guard let base = URL(string: base) else { throw Failure.invalidResponse }
        var result: [JellyfinItem] = []
        for batch in batches(ids: ids) {
            var start = 0
            repeat {
                try Task.checkCancellation()
                var components = URLComponents(url: base.appendingPathComponent("Users").appendingPathComponent(userID)
                    .appendingPathComponent("Items"), resolvingAgainstBaseURL: false)!
                components.queryItems = [.init(name: "Ids", value: batch.joined(separator: ",")),
                    .init(name: "Recursive", value: "true"), .init(name: "EnableTotalRecordCount", value: "true"),
                    .init(name: "StartIndex", value: String(start)), .init(name: "Limit", value: "80"),
                    .init(name: "EnableUserData", value: "true"), .init(name: "Fields", value: fields)]
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
