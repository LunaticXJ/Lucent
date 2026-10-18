import Foundation

struct ParsedMediaName {
    let title: String
    let identity: MediaIdentity
}

enum MediaNameParser {
    private static let episodePatterns = [
        #"(?i)\bS(\d{1,2})[ ._-]*E(\d{1,3})\b"#,
        #"(?i)\b(\d{1,2})x(\d{1,3})\b"#
    ]
    private static let qualityPattern = #"(?i)\b(?:2160p|1080p|720p|480p|WEB[- ]?DL|WEBRip|BluRay|BDRip|HDRip|REMUX|H\.?26[45]|HEVC|AV1)\b"#

    static func parse(filename: String, fallbackSeries: String? = nil) -> ParsedMediaName {
        let stem = (filename as NSString).deletingPathExtension
        let normalized = stem.replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        let ns = normalized as NSString
        for pattern in episodePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)) else { continue }
            let season = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let number = Int(ns.substring(with: match.range(at: 2))) ?? 0
            guard season > 0, number > 0 else { continue }
            let series = clean(ns.substring(to: match.range.location).isEmpty
                               ? (fallbackSeries ?? "") : ns.substring(to: match.range.location))
            guard !series.isEmpty else { continue }
            let remainder = ns.substring(from: match.range.location + match.range.length)
            let episodeName = clean(cutAtQuality(remainder))
            return ParsedMediaName(
                title: episodeName.isEmpty ? "第\(number)集" : episodeName,
                identity: .episode(series: series, season: season, number: number,
                                   name: episodeName.isEmpty ? nil : episodeName)
            )
        }

        let yearRegex = try? NSRegularExpression(pattern: #"\b((?:19|20)\d{2})\b"#)
        let yearMatch = yearRegex?.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length))
        let year = yearMatch.flatMap { Int(ns.substring(with: $0.range(at: 1))) }
        let prefix = yearMatch.map { ns.substring(to: $0.range.location) } ?? cutAtQuality(normalized)
        let title = clean(prefix)
        return ParsedMediaName(title: title.isEmpty ? stem : title, identity: .movie(year: year))
    }

    static func title(from filename: String) -> String { parse(filename: filename).title }

    static func parse(relativePath: String) -> ParsedMediaName {
        let components = relativePath.split(separator: "/").map(String.init)
        guard let filename = components.last else { return parse(filename: relativePath) }
        let parent = components.count >= 2 ? components[components.count - 2] : ""
        let seasonFolder = parent.range(of: #"(?i)^(?:season|series|第)\s*\d+\s*(?:季)?$"#,
                                        options: .regularExpression) != nil
        let series = seasonFolder && components.count >= 3
            ? components[components.count - 3] : parent
        return parse(filename: filename, fallbackSeries: series)
    }

    private static func cutAtQuality(_ value: String) -> String {
        guard let range = value.range(of: qualityPattern, options: .regularExpression) else { return value }
        return String(value[..<range.lowerBound])
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"[\[\](){}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-–—]+\s*"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
