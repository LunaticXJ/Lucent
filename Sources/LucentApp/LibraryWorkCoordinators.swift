import Foundation

@MainActor
final class LibraryScanCoordinator {
    var tasks: [UUID: Task<Void, Never>] = [:]
    var pending: [UUID] = []
    let concurrency = 2
    nonisolated static func discover(root: StorageDirectory,
        read: @escaping @Sendable (StorageDirectory) async throws -> [StorageDirectory],
        progress: @escaping @Sendable (Int) async -> Void) async throws -> [StorageDirectory] {
        try await withThrowingTaskGroup(of: [StorageDirectory].self) { group in
            group.addTask {
                var directories = [root], cursor = 0
                var visited = Set<String>(), files: [StorageDirectory] = []
                while cursor < directories.count {
                    try Task.checkCancellation()
                    let current = directories[cursor]; cursor += 1
                    guard visited.insert(current.identifier).inserted else { continue }
                    let entries = try await read(current)
                    for entry in entries {
                        if entry.isDirectory { directories.append(entry) } else { files.append(entry) }
                    }
                    guard files.count + visited.count + directories.count - cursor <= 50_000 else { throw LibraryScopeError.limit }
                    await progress(files.count)
                }
                return files
            }
            return try await group.next() ?? []
        }
    }
    func cancel(_ id: UUID) {
        pending.removeAll { $0 == id }; tasks[id]?.cancel()
    }
}

/// One metadata drain owns its lifecycle, independent from the library UI store.
@MainActor
final class MetadataCoordinator {
    private(set) var task: Task<Void, Never>?
    var isRunning: Bool { task != nil }
    func start(_ operation: @escaping @MainActor () async -> Void) {
        guard task == nil else { return }
        task = Task { await operation(); task = nil }
    }
}
