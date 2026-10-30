import Foundation

#if !os(tvOS)
enum FolderScanner {
    struct Entry: Identifiable, Sendable {
        let name: String
        let relativePath: String
        let isDirectory: Bool
        var id: String { relativePath }
    }

    static func contents(bookmark: Data, relativePath: String) throws -> [Entry] {
        guard !relativePath.split(separator: "/").contains("..") else { throw CocoaError(.fileReadNoPermission) }
        var stale = false
        #if os(macOS)
        let root = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let root = try URL(resolvingBookmarkData: bookmark, options: [],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale, root.startAccessingSecurityScopedResource() else { throw CocoaError(.fileReadNoPermission) }
        defer { root.stopAccessingSecurityScopedResource() }
        let directory = root.appendingPathComponent(relativePath, isDirectory: true).standardizedFileURL
        guard directory.path == root.standardizedFileURL.path ||
              directory.path.hasPrefix(root.standardizedFileURL.path + "/") else { throw CocoaError(.fileReadNoPermission) }
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        let children = try FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        let allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm", "m2ts", "mts",
                                    "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso", "strm", "m3u", "m3u8"]
        return try children.compactMap { url in
            let values = try url.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { return nil }
            let isDirectory = values.isDirectory == true
            guard isDirectory || (values.isRegularFile == true && allowed.contains(url.pathExtension.lowercased())) else { return nil }
            let path = relativePath.isEmpty ? url.lastPathComponent : relativePath + "/" + url.lastPathComponent
            return Entry(name: url.lastPathComponent, relativePath: path, isDirectory: isDirectory)
        }.sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    static func scan(bookmark: Data) throws -> [String] {
        var stale = false
        #if os(macOS)
        let root = try URL(resolvingBookmarkData: bookmark, options: .withSecurityScope,
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        #else
        let root = try URL(resolvingBookmarkData: bookmark, options: [],
                           relativeTo: nil, bookmarkDataIsStale: &stale)
        #endif
        guard !stale, root.startAccessingSecurityScopedResource() else {
            throw CocoaError(.fileReadNoPermission)
        }
        defer { root.stopAccessingSecurityScopedResource() }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw CocoaError(.fileReadUnknown)
        }
        let allowed: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "ts", "webm",
                                    "m2ts", "mts", "wmv", "flv", "vob", "mpg", "mpeg", "ogv", "iso",
                                    "strm", "m3u", "m3u8"]
        let prefix = root.standardizedFileURL.path + "/"
        var paths: [String] = []
        for case let file as URL in enumerator {
            let name = file.lastPathComponent.uppercased()
            if (name == "VIDEO_TS" || name == "BDMV"),
               (try? file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let path = file.standardizedFileURL.path
                if path.hasPrefix(prefix) { paths.append(String(path.dropFirst(prefix.count))) }
                enumerator.skipDescendants()
                continue
            }
            guard allowed.contains(file.pathExtension.lowercased()),
                  (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            let path = file.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            paths.append(String(path.dropFirst(prefix.count)))
        }
        return paths
    }
}
#endif
