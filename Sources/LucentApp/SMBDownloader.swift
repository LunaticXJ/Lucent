import Foundation

enum SMBDownloader {
    static func copy(source: SMBSource, password: String?, path: String, to destination: URL,
                     progress: @escaping @Sendable (Double) -> Void) throws {
        let first = try SMBScanner.readRange(source: source, password: password, path: path,
                                             offset: 0, length: 1_048_576)
        guard first.totalSize > 0, !first.data.isEmpty else { throw CocoaError(.fileReadUnknown) }
        var existingSize = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if existingSize > 0 {
            let prefix = try Data(contentsOf: destination, options: .mappedIfSafe).prefix(min(existingSize, first.data.count))
            if UInt64(existingSize) > first.totalSize || prefix != first.data.prefix(prefix.count) {
                try FileManager.default.removeItem(at: destination)
                existingSize = 0
            }
        }
        if let available = try? destination.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityKey])
            .volumeAvailableCapacity,
           first.totalSize - UInt64(existingSize) > UInt64(max(0, available - 100_000_000)) {
            throw SMBDownloadError.insufficientSpace
        }
        guard existingSize > 0 || FileManager.default.createFile(atPath: destination.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var offset = UInt64(existingSize)
        if offset == 0 {
            try handle.write(contentsOf: first.data)
            offset = UInt64(first.data.count)
        } else {
            try handle.seekToEnd()
        }
        progress(Double(offset) / Double(first.totalSize))
        while offset < first.totalSize {
            try Task<Never, Never>.checkCancellation()
            let next = try SMBScanner.readRange(source: source, password: password, path: path,
                                                offset: offset, length: 1_048_576)
            guard !next.data.isEmpty, next.totalSize == first.totalSize else { throw CocoaError(.fileReadUnknown) }
            try handle.write(contentsOf: next.data)
            offset += UInt64(next.data.count)
            progress(Double(offset) / Double(first.totalSize))
        }
    }
}

private enum SMBDownloadError: LocalizedError {
    case insufficientSpace
    var errorDescription: String? { "设备可用空间不足，无法下载该影片。" }
}
