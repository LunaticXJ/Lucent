import Foundation
import CryptoKit

/// Presentation-only stale-while-revalidate seed. Never stores credentials.
struct HomeStartupSnapshot: Codable, Sendable {
    struct Shelf: Codable, Sendable { let view: MediaCard; let items: [MediaCard] }
    let version: Int
    let context: String
    let savedAt: Date
    let views: [MediaCard]
    let latest: [MediaCard]
    let continuing: [MediaCard]
    let continuingTotal: Int
    let shelves: [Shelf]
    let artworks: [String: TMDBService.DetailArtwork]
    let selectedHeroID: String?
}
actor HomeStartupCache {
    static let shared = HomeStartupCache()
    private let folder: URL
    init(directory: URL? = nil) {
        folder = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("HomeStartup", isDirectory: true)
    }
    static func context(source: EmbySource, language: String) -> String {
        SHA256.hash(data: Data("1|\(source.id)|\(source.baseAddress)|\(source.userID)|\(language)".utf8)).map { String(format:"%02x",$0) }.joined()
    }
    func read(id: UUID, context: String) -> HomeStartupSnapshot? {
        let url = folder.appendingPathComponent(id.uuidString + ".json")
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 4 * 1024 * 1024,
              let data = try? Data(contentsOf: url), let value = try? JSONDecoder().decode(HomeStartupSnapshot.self, from: data),
              value.version == 1, value.context == context,
              Date().timeIntervalSince(value.savedAt) >= 0, Date().timeIntervalSince(value.savedAt) < 7 * 86400 else { return nil }
        return value
    }
    func update(id: UUID, context: String, artworkID: String? = nil, artwork: TMDBService.DetailArtwork? = nil, selection: String? = nil) {
        guard let existing = read(id: id, context: context) else { return }
        var artworks = existing.artworks
        if let artworkID, let artwork { artworks[artworkID] = artwork }
        write(id: id, value: .init(version: existing.version, context: context, savedAt: existing.savedAt,
            views: existing.views, latest: existing.latest, continuing: existing.continuing,
            continuingTotal: existing.continuingTotal, shelves: existing.shelves,
            artworks: artworks, selectedHeroID: selection ?? existing.selectedHeroID))
    }
    func updateShelves(id: UUID, context: String, shelves: [HomeStartupSnapshot.Shelf]) {
        guard !shelves.isEmpty, let existing = read(id: id, context: context) else { return }
        let updated = Dictionary(shelves.map { ($0.view.id, $0) }, uniquingKeysWith: { _, last in last })
        let merged = existing.views.map { library -> HomeStartupSnapshot.Shelf in
            if let fresh = updated[library.id] { return fresh }
            return existing.shelves.first { $0.view.id == library.id } ?? .init(view: library, items: [])
        }
        write(id: id, value: .init(version: existing.version, context: context, savedAt: existing.savedAt,
            views: existing.views, latest: existing.latest, continuing: existing.continuing,
            continuingTotal: existing.continuingTotal, shelves: merged,
            artworks: existing.artworks, selectedHeroID: existing.selectedHeroID))
    }
    func write(id: UUID, value: HomeStartupSnapshot) {
        guard let data = try? JSONEncoder().encode(value), data.count <= 4 * 1024 * 1024 else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? data.write(to: folder.appendingPathComponent(id.uuidString + ".json"), options: .atomic)
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let sorted = files.sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for file in sorted.dropFirst(6) { try? FileManager.default.removeItem(at: file) }
    }
}
