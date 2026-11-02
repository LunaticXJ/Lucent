import Foundation

/// Value-only catalog index; safe to construct away from the UI actor.
struct LocalCatalogIndex: Sendable {
    let groups: [String: [MediaItem]]
    let cards: [MediaItem]
    init(files: [MediaItem]) {
        groups = Dictionary(grouping: files.filter { $0.missingSince == nil && $0.metadata != nil }, by: \.catalogGroupID)
        cards = groups.values.compactMap { group in
            group.min {
                if $0.isInProgress != $1.isInProgress { return $0.isInProgress }
                if $0.isInProgress { return ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
                return ($0.identity?.episodeSortOrder ?? 0) < ($1.identity?.episodeSortOrder ?? 0)
            }
        }.sorted { $0.addedAt > $1.addedAt }
    }
}
