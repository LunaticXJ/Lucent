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
        let normalized = stem.replacingOccurrences(of: #"(?i)[\[{](?:tmdb(?:id)?|imdb(?:id)?)[=:-][^\]}]+[\]}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "[._]", with: " ", options: .regularExpression)
        let ns = normalized as NSString
        for pattern in episodePatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)) else { continue }
            let season = Int(ns.substring(with: match.range(at: 1))) ?? 0
            let number = Int(ns.substring(with: match.range(at: 2))) ?? 0
            guard season >= 0, number >= 0 else { continue }
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

        if let regex = try? NSRegularExpression(pattern: #"(?:第\s*)?([零〇一二三四五六七八九十百两\d]{1,5})\s*集"#),
           let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)),
           let number = number(ns.substring(with: match.range(at: 1))), number > 0 {
            let prefix = clean(ns.substring(to: match.range.location))
            let rawSeries = prefix.isEmpty ? (fallbackSeries ?? "") : prefix
            let (series, season) = seriesSeason(rawSeries)
            if !series.isEmpty {
                return ParsedMediaName(title: "第\(number)集", identity: .episode(series: series, season: season ?? 1, number: number, name: nil))
            }
        }

        if let regex = try? NSRegularExpression(pattern: #"(?i)^(.*?)\bEP?\s*(\d{1,4})(?:\b|$)"#),
           let match = regex.firstMatch(in: normalized, range: NSRange(location: 0, length: ns.length)),
           let episode = Int(ns.substring(with: match.range(at: 2))) {
            let prefix = clean(ns.substring(with: match.range(at: 1)))
            let (series, season) = seriesSeason(prefix.isEmpty ? (fallbackSeries ?? "") : prefix)
            if !series.isEmpty { return .init(title: "第\(episode)集", identity: .episode(series: series, season: season ?? 1, number: episode, name: nil)) }
        }
        let (seasonTitle, season) = seriesSeason(normalized)
        if let season, !seasonTitle.isEmpty {
            return .init(title: seasonTitle, identity: .episode(series: seasonTitle, season: season, number: 0, name: nil))
        }

        let yearRegex = try? NSRegularExpression(pattern: #"\b((?:19|20)\d{2})\b"#)
        let yearMatch = yearRegex?.matches(in: normalized, range: NSRange(location: 0, length: ns.length)).first {
            !clean(ns.substring(to: $0.range.location)).isEmpty
        }
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
        let folderPattern = #"(?i)^(?:season\s*|series\s*|s|第\s*)?([零〇一二三四五六七八九十百两\d]+)\s*(?:季)?$"#
        let folderRegex = try? NSRegularExpression(pattern: folderPattern)
        let folderMatch = folderRegex?.firstMatch(in: parent, range: NSRange(parent.startIndex..., in: parent))
        let seasonFolder = folderMatch != nil && (parent.rangeOfCharacter(from: .decimalDigits.inverted) != nil)
        let series = seasonFolder && components.count >= 3
            ? components[components.count - 3] : parent
        if seasonFolder {
            let season = folderMatch.flatMap { number((parent as NSString).substring(with: $0.range(at: 1))) } ?? 1
            let stem = (filename as NSString).deletingPathExtension
            if stem.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil, let number = Int(stem), number > 0 {
                return ParsedMediaName(title: "第\(number)集", identity: .episode(series: clean(series), season: season, number: number, name: nil))
            }
            let parsed = parse(filename: filename, fallbackSeries: series)
            if case .episode(let name, _, let number, let episodeTitle) = parsed.identity,
               filename.range(of: #"(?i)S\d+E\d+|\d+x\d+"#, options: .regularExpression) == nil {
                return ParsedMediaName(title: parsed.title, identity: .episode(series: name, season: season, number: number, name: episodeTitle))
            }
        }
        let parsed = parse(filename: filename, fallbackSeries: series)
        let stem = (filename as NSString).deletingPathExtension
        if !series.isEmpty, stem.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil, let episode = Int(stem) {
            return .init(title: "第\(episode)集", identity: .episode(series: series, season: 1, number: episode, name: nil))
        }
        return parsed
    }

    static func number(_ text: String) -> Int? {
        if let value = Int(text) { return value }
        let digits: [Character: Int] = ["零":0,"〇":0,"一":1,"二":2,"两":2,"三":3,"四":4,"五":5,"六":6,"七":7,"八":8,"九":9]
        var total = 0, current = 0
        for character in text {
            if let digit = digits[character] { current = digit }
            else if character == "十" { total += max(current, 1) * 10; current = 0 }
            else if character == "百" { total += max(current, 1) * 100; current = 0 }
            else { return nil }
        }
        return text.isEmpty ? nil : total + current
    }
    private static func seriesSeason(_ text: String) -> (String, Int?) {
        let pattern = #"(?i)(?:第\s*([零〇一二三四五六七八九十百两\d]+)\s*季|\bS(\d{1,2})\b)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return (clean(text), nil) }
        let range = match.range(at: 1).location == NSNotFound ? match.range(at: 2) : match.range(at: 1)
        return (clean((text as NSString).substring(to: match.range.location)), number((text as NSString).substring(with: range)))
    }

    private static func cutAtQuality(_ value: String) -> String {
        guard let range = value.range(of: qualityPattern, options: .regularExpression) else { return value }
        return String(value[..<range.lowerBound])
    }

    private static func clean(_ value: String) -> String {
        value.replacingOccurrences(of: #"(?i)[\[{](?:tmdb(?:id)?|imdb(?:id)?)[=:-][^\]}]+[\]}]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\[\](){}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s*[-–—]+\s*"#, with: " ", options: .regularExpression)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
