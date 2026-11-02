import Foundation

struct PlaybackSegment: Identifiable, Sendable {
    enum Kind: String, Sendable { case intro, recap, credits }
    let kind: Kind
    let start: Double
    let end: Double
    var id: String { "\(kind.rawValue)-\(start)-\(end)" }
    var title: String {
        switch kind {
        case .intro: "片头"
        case .recap: "前情回顾"
        case .credits: "片尾"
        }
    }
}

enum PlaybackSegmentClient {
    static func emby(baseAddress: String, itemID: String, token: String,
                     duration: Double?) async throws -> [PlaybackSegment] {
        guard let base = URL(string: baseAddress) else { return [] }
        var components = URLComponents(url: base.appendingPathComponent("Items").appendingPathComponent(itemID),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "Fields", value: "Chapters")]
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let values = json["Chapters"] as? [[String: Any]] else { return [] }
        let runtime = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            ?? (json["RunTimeTicks"] as? NSNumber).map { $0.doubleValue / 10_000_000 } ?? 0
        return fromEmbyChapters(values, duration: runtime)
    }

    static func fromEmbyChapters(_ values: [[String: Any]], duration: Double) -> [PlaybackSegment] {
        let rows = values.compactMap { value -> (time: Double, name: String, marker: String)? in
            guard let ticks = (value["StartPositionTicks"] as? NSNumber)?.doubleValue,
                  ticks.isFinite, ticks >= 0 else { return nil }
            return (ticks / 10_000_000, value["Name"] as? String ?? "", (value["MarkerType"] as? String ?? "").lowercased())
        }.sorted { $0.time < $1.time }
        let chapters = rows.enumerated().map { PlaybackChapter(index: $0.offset, title: $0.element.name, start: $0.element.time) }
        var result = fromChapters(chapters, duration: duration)
        if let start = rows.first(where: { $0.marker == "introstart" }),
           let end = rows.first(where: { $0.marker == "introend" && $0.time > start.time }) {
            result.removeAll { $0.kind == .intro }
            result.append(.init(kind: .intro, start: start.time, end: end.time))
        }
        if let start = rows.first(where: { $0.marker == "creditsstart" }), duration > start.time {
            result.removeAll { $0.kind == .credits }
            result.append(.init(kind: .credits, start: start.time, end: duration))
        }
        return result
    }

    static func jellyfin(baseAddress: String, itemID: String, token: String) async throws -> [PlaybackSegment] {
        guard let base = URL(string: baseAddress) else { return [] }
        var request = URLRequest(url: base.appendingPathComponent("MediaSegments").appendingPathComponent(itemID))
        request.setValue(token, forHTTPHeaderField: "X-Emby-Token")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let segments = json["Items"] as? [[String: Any]] else { return [] }
        return segments.compactMap { item in
            guard let type = (item["Type"] as? String)?.lowercased(),
                  let kind = kind(type),
                  let start = (item["StartTicks"] as? NSNumber)?.doubleValue,
                  let end = (item["EndTicks"] as? NSNumber)?.doubleValue,
                  end > start else { return nil }
            return PlaybackSegment(kind: kind, start: start / 10_000_000, end: end / 10_000_000)
        }
    }

    static func plex(baseAddress: String, ratingKey: String, token: String) async throws -> [PlaybackSegment] {
        guard let base = URL(string: baseAddress) else { return [] }
        var components = URLComponents(url: base.appendingPathComponent("library/metadata/\(ratingKey)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "includeMarkers", value: "1")]
        var request = URLRequest(url: components.url!)
        request.setValue(token, forHTTPHeaderField: "X-Plex-Token")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let container = json["MediaContainer"] as? [String: Any],
              let metadata = (container["Metadata"] as? [[String: Any]])?.first,
              let markers = metadata["Marker"] as? [[String: Any]] else { return [] }
        return markers.compactMap { marker in
            guard let type = (marker["type"] as? String)?.lowercased(),
                  let kind = kind(type),
                  let start = (marker["startTimeOffset"] as? NSNumber)?.doubleValue,
                  let end = (marker["endTimeOffset"] as? NSNumber)?.doubleValue,
                  end > start else { return nil }
            return PlaybackSegment(kind: kind, start: start / 1_000, end: end / 1_000)
        }
    }

    static func fromChapters(_ chapters: [PlaybackChapter], duration: Double) -> [PlaybackSegment] {
        let chapters = chapters.filter { $0.start.isFinite && $0.start >= 0 }.sorted { $0.start < $1.start }
        return chapters.enumerated().compactMap { index, chapter in
            let title = chapter.title.lowercased()
            guard !title.contains("introend"), let kind = kind(title) else { return nil }
            let end = index + 1 < chapters.count ? chapters[index + 1].start : duration
            guard end > chapter.start, end - chapter.start < 1_200 else { return nil }
            return PlaybackSegment(kind: kind, start: chapter.start, end: end)
        }
    }

    private static func kind(_ raw: String) -> PlaybackSegment.Kind? {
        if raw.contains("intro") || raw.contains("opening") || raw.contains("片头") { return .intro }
        if raw.contains("recap") || raw.contains("previously") || raw.contains("前情") { return .recap }
        if raw.contains("credit") || raw.contains("outro") || raw.contains("片尾") { return .credits }
        return nil
    }
}
