import Foundation
import SQLite3

final class LibraryDatabase {
    private let connection: OpaquePointer
    private var persistedItems: [UUID: MediaItem] = [:]
    private var persistedConfiguration: Data?
    var hasStoredConfiguration: Bool { persistedConfiguration != nil }
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer,
                              SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw DatabaseError.open
        }
        connection = pointer
        do {
            let versionStatement = try prepare("PRAGMA user_version")
            let version = sqlite3_step(versionStatement) == SQLITE_ROW ? sqlite3_column_int(versionStatement, 0) : 0
            sqlite3_finalize(versionStatement)
            guard version <= 1 else { throw DatabaseError.unsupportedVersion }
            try execute("PRAGMA journal_mode=WAL")
            try execute("CREATE TABLE IF NOT EXISTS media_items (id TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            try execute("CREATE TABLE IF NOT EXISTS configuration (key TEXT PRIMARY KEY, payload BLOB NOT NULL)")
            if version == 0 { try execute("PRAGMA user_version=1") }
        } catch {
            sqlite3_close(pointer)
            throw error
        }
    }

    deinit { sqlite3_close(connection) }

    func load() throws -> LibrarySnapshot {
        var items: [MediaItem] = []
        let itemStatement = try prepare("SELECT payload FROM media_items")
        defer { sqlite3_finalize(itemStatement) }
        while sqlite3_step(itemStatement) == SQLITE_ROW {
            guard let data = columnData(itemStatement, index: 0) else { throw DatabaseError.read }
            let item = try JSONDecoder().decode(MediaItem.self, from: data)
            items.append(item)
            persistedItems[item.id] = item
        }
        let configStatement = try prepare("SELECT payload FROM configuration WHERE key='library'")
        defer { sqlite3_finalize(configStatement) }
        if sqlite3_step(configStatement) == SQLITE_ROW,
           let data = columnData(configStatement, index: 0) {
            persistedConfiguration = data
            var snapshot = try JSONDecoder().decode(LibrarySnapshot.self, from: data)
            snapshot.items = items
            return snapshot
        }
        return LibrarySnapshot(items: items, folders: [], smbSources: [], webDAVSources: [],
                               jellyfinSources: [], embySources: [], plexSources: [],
                               cloudSources: [],
                               dlnaSources: [],
                               vlcNetworkSources: [],
                               collections: [], smartPlaylists: [], libraryConfigUpdatedAt: nil,
                               viewerProfiles: [], activeProfileID: nil)
    }

    func save(_ snapshot: LibrarySnapshot) throws {
        let encoder = JSONEncoder()
        var configuration = snapshot
        configuration.items = []
        let configurationData = try encoder.encode(configuration)
        let currentIDs = Set(snapshot.items.map(\.id))
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let upsert = try prepare("INSERT INTO media_items(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload")
            defer { sqlite3_finalize(upsert) }
            for item in snapshot.items where persistedItems[item.id] != item {
                let data = try encoder.encode(item)
                sqlite3_reset(upsert)
                sqlite3_clear_bindings(upsert)
                try bind(item.id.uuidString, to: upsert, index: 1)
                try bind(data, to: upsert, index: 2)
                guard sqlite3_step(upsert) == SQLITE_DONE else { throw DatabaseError.write }
            }
            let remove = try prepare("DELETE FROM media_items WHERE id=?")
            defer { sqlite3_finalize(remove) }
            for id in persistedItems.keys where !currentIDs.contains(id) {
                sqlite3_reset(remove)
                sqlite3_clear_bindings(remove)
                try bind(id.uuidString, to: remove, index: 1)
                guard sqlite3_step(remove) == SQLITE_DONE else { throw DatabaseError.write }
            }
            if persistedConfiguration != configurationData {
                let upsertConfig = try prepare("INSERT INTO configuration(key,payload) VALUES('library',?) ON CONFLICT(key) DO UPDATE SET payload=excluded.payload")
                defer { sqlite3_finalize(upsertConfig) }
                try bind(configurationData, to: upsertConfig, index: 1)
                guard sqlite3_step(upsertConfig) == SQLITE_DONE else { throw DatabaseError.write }
            }
            try execute("COMMIT")
            persistedItems = Dictionary(uniqueKeysWithValues: snapshot.items.map { ($0.id, $0) })
            persistedConfiguration = configurationData
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(connection, sql, nil, nil, nil) == SQLITE_OK else { throw DatabaseError.write }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { throw DatabaseError.write }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer, index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, transient) == SQLITE_OK else {
            throw DatabaseError.write
        }
    }

    private func bind(_ value: Data, to statement: OpaquePointer, index: Int32) throws {
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), transient)
        }
        guard status == SQLITE_OK else { throw DatabaseError.write }
    }

    private func columnData(_ statement: OpaquePointer, index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }
}

private enum DatabaseError: LocalizedError {
    case open, read, write, unsupportedVersion
    var errorDescription: String? {
        switch self {
        case .open: "无法打开媒体库数据库。"
        case .read: "媒体库数据库包含无法读取的数据。"
        case .write: "无法写入媒体库数据库。"
        case .unsupportedVersion: "媒体库由更新版本的 Lucent 创建，当前版本无法打开。"
        }
    }
}
