import Foundation

enum SubtitleParser {
    static let supportedExtensions: Set<String> = ["srt", "vtt", "ass", "ssa", "sup"]

    static func parse(_ data: Data, fileExtension: String) -> [SubtitleCue] {
        switch fileExtension.lowercased() {
        case "srt", "vtt": return SRTParser.parse(data)
        case "ass", "ssa": return parseASS(data)
        default: return []
        }
    }

    private static func parseASS(_ data: Data) -> [SubtitleCue] {
        let content = SubtitleTextDecoder.decode(data) ?? ""
        var inEvents = false
        var format: [String] = []
        var cues: [SubtitleCue] = []
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") {
                inEvents = line.lowercased() == "[events]"
                continue
            }
            guard inEvents else { continue }
            if line.lowercased().hasPrefix("format:") {
                format = line.dropFirst(7).split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                }
                continue
            }
            guard line.lowercased().hasPrefix("dialogue:"),
                  let startIndex = format.firstIndex(of: "start"),
                  let endIndex = format.firstIndex(of: "end"),
                  let textIndex = format.firstIndex(of: "text") else { continue }
            let fields = line.dropFirst(9).split(separator: ",", maxSplits: max(0, format.count - 1),
                                                 omittingEmptySubsequences: false)
            guard fields.count == format.count,
                  let start = assSeconds(String(fields[startIndex])),
                  let end = assSeconds(String(fields[endIndex])), end > start else { continue }
            let text = String(fields[textIndex])
                .replacingOccurrences(of: #"\{[^}]*\}"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"\N"#, with: "\n")
                .replacingOccurrences(of: #"\n"#, with: "\n")
                .replacingOccurrences(of: #"\h"#, with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SubtitleCue(start: start, end: end, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func assSeconds(_ raw: String) -> Double? {
        let parts = raw.trimmingCharacters(in: .whitespaces).split(separator: ":")
        guard parts.count == 3, let hours = Double(parts[0]), let minutes = Double(parts[1]),
              let seconds = Double(parts[2]) else { return nil }
        return hours * 3600 + minutes * 60 + seconds
    }
}
