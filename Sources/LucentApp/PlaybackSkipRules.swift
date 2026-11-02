import Foundation

enum PlaybackSkipRules {
    static func parseTime(_ text: String) -> Double? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.allSatisfy(\.isFinite),
              numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return nil }
        let seconds = numbers.reduce(0) { $0 * 60 + $1 }
        return seconds > 0 ? seconds : nil
    }
    static func resolved(server: [PlaybackSegment], introEnd: Double?, creditsStart: Double?,
                         creditsDuration: Double?, duration: Double) -> [PlaybackSegment] {
        var result = server
        if let introEnd, introEnd.isFinite, introEnd > 0 {
            result.removeAll { $0.kind == .intro }
            result.append(.init(kind: .intro, start: 0, end: introEnd))
        }
        if let creditsDuration, creditsDuration.isFinite, creditsDuration > 0, duration > creditsDuration {
            result.removeAll { $0.kind == .credits }
            result.append(.init(kind: .credits, start: duration - creditsDuration, end: duration))
        } else if let creditsStart, creditsStart.isFinite, creditsStart > 0, duration > creditsStart {
            result.removeAll { $0.kind == .credits }
            result.append(.init(kind: .credits, start: creditsStart, end: duration))
        }
        return result.filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start &&
            (duration <= 0 || ($0.end <= duration && $0.end - $0.start < duration))
        }.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
    }
    static func active(in segments: [PlaybackSegment], at time: Double) -> PlaybackSegment? {
        guard time.isFinite else { return nil }
        return segments.first { time >= max(0.5, $0.start) && time < $0.end - 0.5 }
    }
}
