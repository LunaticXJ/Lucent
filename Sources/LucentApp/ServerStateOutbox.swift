import Foundation

/// Durable latest-state queue. One request at a time; an acknowledgement never
/// removes a newer state submitted while the request was suspended.
actor ServerStateOutbox {
    struct Record: Codable, Sendable {
        let item: MediaItem
        let stopped: Bool
        let revision: Date
        var key: UUID { item.id }
    }
    private var pending: [UUID: Record] = [:]
    private var loaded = false
    private var worker: Task<Void, Never>?
    private let url: URL
    private let retryDelay: Duration
    init(url: URL, retryDelay: Duration = .seconds(15)) { self.url = url; self.retryDelay = retryDelay }
    func pendingCount() -> Int { load(); return pending.count }
    private func load() {
        guard !loaded else { return }; loaded = true
        if let data = try? Data(contentsOf: url), let values = try? JSONDecoder().decode([Record].self, from: data) {
            for value in values where pending[value.key].map({ $0.revision < value.revision }) ?? true { pending[value.key] = value }
        }
    }
    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(Array(pending.values)).write(to: url, options: .atomic)
    }
    func submit(_ record: Record, deliver: @escaping @Sendable (Record) async throws -> Void) throws {
        try submit([record], deliver: deliver)
    }
    func submit(_ records: [Record], deliver: @escaping @Sendable (Record) async throws -> Void) throws {
        load()
        for record in records where pending[record.key].map({ $0.revision <= record.revision }) ?? true {
            pending[record.key] = record
        }
        try persist() // Do not start a request until its recovery record is durable.
        start(deliver: deliver)
    }
    func resume(deliver: @escaping @Sendable (Record) async throws -> Void) {
        load(); start(deliver: deliver)
    }
    private func start(deliver: @escaping @Sendable (Record) async throws -> Void) {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task {
            defer { worker = nil }
            while !Task.isCancelled, !pending.isEmpty {
                let batch = pending.values.sorted { $0.revision < $1.revision }
                var failed = false
                for record in batch {
                    guard !Task.isCancelled else { return }
                    // A queued old value may already have been replaced before its turn.
                    guard pending[record.key]?.revision == record.revision else { continue }
                    do {
                        try await deliver(record)
                        if pending[record.key]?.revision == record.revision { pending[record.key] = nil }
                        try persist()
                    } catch { failed = true }
                }
                if failed { do { try await Task.sleep(for: retryDelay) } catch { return } }
            }
        }
    }
}
