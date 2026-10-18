import Foundation

enum SubtitleRangeLoader {
    static func read(maximumBytes: Int = 8_388_608,
                     range: @Sendable (UInt64, Int) throws -> SMBScanner.RangeResult) throws -> Data {
        let first = try range(0, min(maximumBytes, 1_048_576))
        guard first.totalSize <= UInt64(maximumBytes) else { throw CocoaError(.fileReadTooLarge) }
        var data = first.data
        while UInt64(data.count) < first.totalSize {
            let remaining = Int(first.totalSize - UInt64(data.count))
            let part = try range(UInt64(data.count), min(remaining, 1_048_576))
            guard !part.data.isEmpty, part.totalSize == first.totalSize else {
                throw CocoaError(.fileReadCorruptFile)
            }
            data.append(part.data)
        }
        return data
    }
}
