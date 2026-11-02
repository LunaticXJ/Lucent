import Foundation
import CryptoKit

/// All artwork filesystem work has one non-UI owner. Never stores credentials in filenames.
actor ArtworkDiskStore {
    static let shared = ArtworkDiskStore()
    private let root: URL
    private let lifetime: TimeInterval
    private let limit: Int
    private let trimInterval: TimeInterval
    init(root: URL? = nil, lifetime: TimeInterval = 7 * 86400, limit: Int = 300 * 1024 * 1024, trimInterval: TimeInterval = 60) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LucentMediaCache/Artwork", isDirectory: true)
        self.lifetime = lifetime; self.limit = limit; self.trimInterval = trimInterval
    }
    private var lastTrim = Date.distantPast
    private func url(_ key: String) -> URL {
        root.appendingPathComponent(SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() + ".img")
    }
    func read(_ key: String) -> Data? {
        let file = url(key)
        guard let date = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate,
              Date().timeIntervalSince(date) < lifetime,
              let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
        return data
    }
    func store(_ data: Data, key: String) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let free = (try? root.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? 0
        guard free > data.count + 256 * 1024 * 1024 else { return }
        try? data.write(to: url(key), options: .atomic)
        guard Date().timeIntervalSince(lastTrim) >= trimInterval else { return }
        lastTrim = Date()
        let files = (try? FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        let entries = files.compactMap { file -> (URL, Int, Date)? in
            guard let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (file, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.1 }
        for entry in entries.sorted(by: { $0.2 < $1.2 }) where total > limit {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { total -= entry.1 }
        }
    }
}
