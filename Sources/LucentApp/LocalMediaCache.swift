import Foundation
import CryptoKit

/// Evictable artwork and byte-range data. Keys are logical media identities,
/// never signed URLs or authorization headers.
final class LocalMediaCache: @unchecked Sendable {
    static let shared = LocalMediaCache()
    static let videoLimitKey = "lucent.cache.videoLimitGB"
    private let lock = NSLock()
    private let root: URL
    private let blockSize = 1_048_576
    private var activeKeys: [String: Int] = [:]

    private init() {
        root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LucentMediaCache", isDirectory: true)
    }

    var videoLimitGB: Int {
        let saved = UserDefaults.standard.object(forKey: Self.videoLimitKey) as? Int
        #if os(tvOS)
        return max(0, min(5, saved ?? 1))
        #elseif os(macOS)
        return max(0, min(100, saved ?? 20))
        #else
        return max(0, min(50, saved ?? 5))
        #endif
    }

    func setVideoLimitGB(_ value: Int) {
        UserDefaults.standard.set(max(0, value), forKey: Self.videoLimitKey)
        trimVideo()
    }

    func beginUse(_ key: String) {
        lock.withLock { activeKeys[digest(key), default: 0] += 1 }
    }
    func endUse(_ key: String) {
        lock.withLock {
            let id = digest(key)
            let count = activeKeys[id] ?? 0
            if count <= 1 { activeKeys[id] = nil }
            else { activeKeys[id] = count - 1 }
        }
        trimVideo()
    }

    @MainActor func imageData(key: String, fetch: () async throws -> Data) async throws -> Data {
        let url = imageDirectory.appendingPathComponent(digest(key) + ".img")
        let fresh = (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate
            .map { Date().timeIntervalSince($0) < 7 * 24 * 3600 } ?? false
        if fresh, let data = try? Data(contentsOf: url), !data.isEmpty {
            touch(url)
            return data
        }
        let data = try await fetch()
        guard !data.isEmpty else { return data }
        try? FileManager.default.createDirectory(at: imageDirectory, withIntermediateDirectories: true)
        if hasSpace(for: data.count) { try? data.write(to: url, options: .atomic) }
        trim(directory: imageDirectory, limit: 300 * 1_048_576, protected: [])
        return data
    }

    func readRange(key: String, offset: UInt64, length: Int,
                   fetch: (UInt64, Int) throws -> SMBScanner.RangeResult) throws -> SMBScanner.RangeResult {
        if videoLimitGB == 0 { return try fetch(offset, length) }
        do {
            return try assemble(key: key, offset: offset, length: length) { start in
                try fetch(start, blockSize)
            }
        } catch CacheError.incompleteBlock {
            return try fetch(offset, length)
        }
    }

    func readRange(key: String, offset: UInt64, length: Int,
                   fetch: (UInt64, Int) async throws -> SMBScanner.RangeResult) async throws -> SMBScanner.RangeResult {
        if videoLimitGB == 0 { return try await fetch(offset, length) }
        guard length > 0, offset <= UInt64.max - UInt64(length) else { throw CacheError.invalidRange }
        let id = digest(key)
        var result = Data()
        var total: UInt64 = 0
        var cursor = offset
        let end = offset + UInt64(length)
        while cursor < end {
            let start = cursor / UInt64(blockSize) * UInt64(blockSize)
            let chunk: SMBScanner.RangeResult
            do { chunk = try await block(id: id, start: start) { try await fetch(start, blockSize) } }
            catch CacheError.incompleteBlock { return try await fetch(offset, length) }
            total = chunk.totalSize
            guard cursor < total else { break }
            let within = Int(cursor - start)
            let count = min(chunk.data.count - within, Int(min(end - cursor, total - cursor)))
            guard count > 0 else { throw CacheError.invalidRange }
            result.append(chunk.data[within..<(within + count)])
            cursor += UInt64(count)
        }
        guard !result.isEmpty else { throw CacheError.invalidRange }
        return SMBScanner.RangeResult(data: result, totalSize: total)
    }

    private func assemble(key: String, offset: UInt64, length: Int,
                          fetch: (UInt64) throws -> SMBScanner.RangeResult) throws -> SMBScanner.RangeResult {
        guard length > 0, offset <= UInt64.max - UInt64(length) else { throw CacheError.invalidRange }
        let id = digest(key)
        var result = Data()
        var total: UInt64 = 0
        var cursor = offset
        let end = offset + UInt64(length)
        while cursor < end {
            let start = cursor / UInt64(blockSize) * UInt64(blockSize)
            let chunk = try block(id: id, start: start) { try fetch(start) }
            total = chunk.totalSize
            guard cursor < total else { break }
            let within = Int(cursor - start)
            let count = min(chunk.data.count - within, Int(min(end - cursor, total - cursor)))
            guard count > 0 else { throw CacheError.invalidRange }
            result.append(chunk.data[within..<(within + count)])
            cursor += UInt64(count)
        }
        guard !result.isEmpty else { throw CacheError.invalidRange }
        return SMBScanner.RangeResult(data: result, totalSize: total)
    }

    private func block(id: String, start: UInt64,
                       fetch: () throws -> SMBScanner.RangeResult) throws -> SMBScanner.RangeResult {
        if let cached = cachedBlock(id: id, start: start) { return cached }
        let received = try fetch()
        guard received.data.count == Int(min(UInt64(blockSize), received.totalSize - min(start, received.totalSize)))
        else { throw CacheError.incompleteBlock }
        saveBlock(received, id: id, start: start)
        return received
    }

    private func block(id: String, start: UInt64,
                       fetch: () async throws -> SMBScanner.RangeResult) async throws -> SMBScanner.RangeResult {
        if let cached = cachedBlock(id: id, start: start) { return cached }
        let received = try await fetch()
        guard received.data.count == Int(min(UInt64(blockSize), received.totalSize - min(start, received.totalSize)))
        else { throw CacheError.incompleteBlock }
        saveBlock(received, id: id, start: start)
        return received
    }

    private func cachedBlock(id: String, start: UInt64) -> SMBScanner.RangeResult? {
        let sizeURL = videoDirectory.appendingPathComponent(id + ".size")
        let blockURL = videoDirectory.appendingPathComponent("\(id)-\(start).bin")
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: sizeURL.path),
              let date = attributes[.modificationDate] as? Date,
              Date().timeIntervalSince(date) < 7 * 24 * 3600,
              let sizeText = try? String(contentsOf: sizeURL, encoding: .utf8),
              let total = UInt64(sizeText), start < total,
              let data = try? Data(contentsOf: blockURL),
              data.count == Int(min(UInt64(blockSize), total - start)) else { return nil }
        touch(blockURL)
        return SMBScanner.RangeResult(data: data, totalSize: total)
    }

    private func saveBlock(_ result: SMBScanner.RangeResult, id: String, start: UInt64) {
        guard start < result.totalSize,
              result.data.count == Int(min(UInt64(blockSize), result.totalSize - start)) else { return }
        guard hasSpace(for: result.data.count) else { return }
        try? FileManager.default.createDirectory(at: videoDirectory, withIntermediateDirectories: true)
        let sizeURL = videoDirectory.appendingPathComponent(id + ".size")
        let previous = (try? String(contentsOf: sizeURL, encoding: .utf8)).flatMap(UInt64.init)
        if let previous, previous != result.totalSize { removeBlocks(id: id) }
        try? String(result.totalSize).write(to: sizeURL, atomically: true, encoding: .utf8)
        let blockURL = videoDirectory.appendingPathComponent("\(id)-\(start).bin")
        try? result.data.write(to: blockURL, options: .atomic)
        trimVideo()
    }

    func sizes() -> (images: UInt64, video: UInt64) {
        (directorySize(imageDirectory), directorySize(videoDirectory))
    }

    func clearImages() { clear(imageDirectory, protected: []) }
    func clearVideo() { clear(videoDirectory, protected: lock.withLock { Set(activeKeys.keys) }) }

    private var imageDirectory: URL { root.appendingPathComponent("Artwork", isDirectory: true) }
    private var videoDirectory: URL { root.appendingPathComponent("Video", isDirectory: true) }
    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func hasSpace(for bytes: Int) -> Bool {
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: root.deletingLastPathComponent().path)
        let free = (attributes?[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
        return free > 2 * 1_073_741_824 + UInt64(bytes)
    }
    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }
    private func files(_ directory: URL) -> [(url: URL, size: UInt64, date: Date)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, UInt64(values.fileSize ?? 0), values.contentModificationDate ?? .distantPast)
        }
    }
    private func directorySize(_ directory: URL) -> UInt64 { files(directory).reduce(0) { $0 + $1.size } }
    private func removeBlocks(id: String) {
        for file in files(videoDirectory) where file.url.lastPathComponent.hasPrefix(id + "-") {
            try? FileManager.default.removeItem(at: file.url)
        }
    }
    private func trimVideo() {
        trim(directory: videoDirectory, limit: UInt64(videoLimitGB) * 1_073_741_824,
             protected: lock.withLock { Set(activeKeys.keys) })
    }
    private func trim(directory: URL, limit: UInt64, protected: Set<String>) {
        lock.withLock {
            let entries = files(directory).filter { $0.url.pathExtension != "size" }
            var total = entries.reduce(UInt64(0)) { $0 + $1.size }
            for entry in entries.sorted(by: { $0.date < $1.date }) where total > limit {
                if protected.contains(where: { entry.url.lastPathComponent.hasPrefix($0 + "-") ||
                    entry.url.lastPathComponent == $0 + ".size" }) { continue }
                try? FileManager.default.removeItem(at: entry.url)
                total -= entry.size
            }
        }
    }
    private func clear(_ directory: URL, protected: Set<String>) {
        lock.withLock {
            for entry in files(directory) {
                if protected.contains(where: { entry.url.lastPathComponent.hasPrefix($0 + "-") ||
                    entry.url.lastPathComponent == $0 + ".size" }) { continue }
                try? FileManager.default.removeItem(at: entry.url)
            }
        }
    }
    private enum CacheError: Error { case invalidRange, incompleteBlock }
}
