import Foundation

/// Connections remain the owners of credentials and playback locations. A file source
/// only grants an explicitly selected directory a place in the aggregate index.
struct LibraryFileSource: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var storageID: UUID
    var name: String
    var directoryID: String
    var path: String
    var enabled = true
    var needsConfirmation = false
    var importedAt: Date? = Date()
    var lastScannedAt: Date?
    var itemIDs: Set<UUID> = []
}

struct StorageDirectory: Identifiable, Equatable, Sendable {
    let identifier: String
    let name: String
    let path: String
    let isDirectory: Bool
    var playbackURL: URL? = nil
    var id: String { identifier }
    static let root = StorageDirectory(identifier: "", name: "全部目录", path: "", isDirectory: true)
}

struct LibraryStorage: Identifiable, Sendable {
    enum Kind: String, Hashable, Sendable { case local, smb, webDAV, cloud, dlna }
    let id: UUID
    let name: String
    let subtitle: String
    let kind: Kind
    var icon: String {
        switch kind {
        case .local: "folder"
        case .smb: "externaldrive.connected.to.line.below"
        case .webDAV: "network"
        case .cloud: "cloud"
        case .dlna: "tv"
        }
    }
}

enum LibraryScopeError: LocalizedError {
    case unavailable, invalidDirectory, overlap(String), limit
    var errorDescription: String? {
        switch self {
        case .unavailable: "存储不可用，请检查连接或重新授权。"
        case .invalidDirectory: "请选择有效目录并填写文件源名称。"
        case .overlap(let name): "该目录与文件源「\(name)」的扫描范围重叠，请先调整已有文件源。"
        case .limit: "目录内容过多，请缩小导入范围。"
        }
    }
}

enum LibraryScopePath {
    static func normalized(_ path: String) -> String {
        path.split(separator: "/").filter { $0 != "." }.joined(separator: "/")
    }
    static func contains(_ parent: String, _ child: String) -> Bool {
        let parent = normalized(parent), child = normalized(child)
        return parent.isEmpty || parent == child || child.hasPrefix(parent + "/")
    }
    static func overlaps(_ a: String, _ b: String) -> Bool { contains(a, b) || contains(b, a) }
}
