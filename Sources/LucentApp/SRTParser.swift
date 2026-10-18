import Foundation

struct SubtitleCue: Sendable {
    let start: Double
    let end: Double
    let text: String
}

enum SRTParser {
    static func parse(_ data: Data) -> [SubtitleCue] {
        let raw = SubtitleTextDecoder.decode(data) ?? ""
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return normalized.components(separatedBy: "\n\n").compactMap { block in
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let timingIndex = lines.firstIndex(where: { $0.contains(" --> ") }) else { return nil }
            let times = lines[timingIndex].components(separatedBy: " --> ")
            guard times.count == 2,
                  let start = seconds(times[0]), let end = seconds(times[1]), end > start else { return nil }
            let text = lines.dropFirst(timingIndex + 1).joined(separator: "\n")
                .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return SubtitleCue(start: start, end: end, text: text)
        }.sorted { $0.start < $1.start }
    }

    private static func seconds(_ raw: String) -> Double? {
        let value = raw.trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ").first ?? ""
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count),
              let minutes = Double(parts[parts.count - 2]),
              let seconds = Double(parts[parts.count - 1]) else { return nil }
        let hours = parts.count == 3 ? (Double(parts[0]) ?? -1) : 0
        guard hours >= 0 else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
