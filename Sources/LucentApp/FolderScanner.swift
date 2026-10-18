import Foundation

#if !os(tvOS)
enum FolderScanner {
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
