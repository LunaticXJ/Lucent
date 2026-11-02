#!/usr/bin/env python3
"""Exercise production SQL repository, outbox and transition state machine without UI/network."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
store_source = (root/'Sources/LucentApp/LibraryStore.swift').read_text()
start = store_source.index('    private func resumeServerStateSync()')
end = store_source.index('    private func reportServerProgress(', start)
migration_method = store_source[start:end].replace('private func', 'func', 1).replace('UserDefaults.standard', 'defaults')
stubs = r'''
import Foundation
import SQLite3
struct MediaItem: Codable, Equatable, Sendable { var id: UUID; var position: Double }
struct ProfilePlaybackState: Codable, Sendable {
 var position: Double
 init(item: MediaItem) { position = item.position }
}
struct ViewerProfile: Codable, Sendable { var id: UUID; var playbackStates: [UUID: ProfilePlaybackState] }
struct LibrarySnapshot: Codable {
 var items: [MediaItem]; var viewerProfiles: [ViewerProfile]?
 init(items: [MediaItem], folders: [Int] = [], smbSources: [Int] = [], webDAVSources: [Int] = [], jellyfinSources: [Int] = [], embySources: [Int] = [], plexSources: [Int] = [], cloudSources: [Int] = [], dlnaSources: [Int] = [], collections: [Int] = [], smartPlaylists: [Int] = [], libraryConfigUpdatedAt: Date? = nil, viewerProfiles: [ViewerProfile]? = nil, activeProfileID: UUID? = nil) { self.items = items; self.viewerProfiles = viewerProfiles }
}
actor Delivery {
 var positions: [Double] = []
 var failures = 0
 var gate: CheckedContinuation<Void, Never>?
 var held = false
 func send(_ record: ServerStateOutbox.Record) async throws {
  positions.append(record.item.position)
  if held { await withCheckedContinuation { gate = $0 } }
  if failures > 0 { failures -= 1; throw URLError(.timedOut) }
 }
 func hold() { held = true }
 func release() { held = false; gate?.resume(); gate = nil }
 func failOnce() { failures = 1 }
 func values() -> [Double] { positions }
}
@main struct Checks {
 @MainActor static func until(_ condition: () async -> Bool) async {
  for _ in 0..<500 { if await condition() { return }; try? await Task.sleep(for: .milliseconds(5)) }
  fatalError("condition timed out")
 }
 @MainActor static func main() async throws {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let id = UUID(), profile = UUID(), otherID = UUID()
  var item = MediaItem(id: id, position: 1)
  let repository = try LibraryRepository(url: directory.appendingPathComponent("library.sqlite"))
  try repository.save(.init(items: [item, .init(id: otherID, position: 7)], viewerProfiles: [.init(id: profile, playbackStates: [:])]))
  item.position = 20
  repository.enqueueItem(item, profileID: profile) { failure in fatalError(failure) }
  await repository.flush()
  var loaded = try repository.load()
  precondition(loaded.items.first { $0.id == id }?.position == 20)
  precondition(loaded.items.first { $0.id == otherID }?.position == 7)
  precondition(loaded.viewerProfiles?.first?.playbackStates[id]?.position == 20)
  loaded.items = loaded.items.filter { $0.id == id }
  try await repository.saveAsync(loaded)
  let afterDelete = try repository.load(); precondition(afterDelete.items.count == 1)
  print("PASS: background single-item progress, profile overlay, ordered snapshot writes/deletions")
  let oldURL = directory.appendingPathComponent("v1.sqlite")
  var connection: OpaquePointer?
  precondition(sqlite3_open(oldURL.path, &connection) == SQLITE_OK)
  let oldData = try JSONEncoder().encode(MediaItem(id: id, position: 12)).map { String(format: "%02x", $0) }.joined()
  precondition(sqlite3_exec(connection, "PRAGMA user_version=1; CREATE TABLE media_items(id TEXT PRIMARY KEY,payload BLOB NOT NULL); CREATE TABLE configuration(key TEXT PRIMARY KEY,payload BLOB NOT NULL); INSERT INTO media_items VALUES('\(id.uuidString)',X'\(oldData)');", nil, nil, nil) == SQLITE_OK)
  sqlite3_close(connection)
  let migrated = try LibraryRepository(url: oldURL)
  let migratedData = try migrated.load(); precondition(migratedData.items.first?.position == 12)
  print("PASS: v1 database migration preserves existing media")
  let artwork = ArtworkDiskStore(root: directory.appendingPathComponent("artwork"), limit: 100, trimInterval: 0)
  await artwork.store(Data(repeating: 1, count: 80), key: "a")
  let cached = await artwork.read("a"); precondition(cached?.count == 80)
  await artwork.store(Data(repeating: 2, count: 80), key: "b")
  let a = await artwork.read("a"), b = await artwork.read("b")
  precondition((a?.count ?? 0) + (b?.count ?? 0) <= 100)
  let expired = ArtworkDiskStore(root: directory.appendingPathComponent("artwork"), lifetime: 0)
  let expiredData = await expired.read("b"); precondition(expiredData == nil)
  print("PASS: artwork disk reads, capacity eviction and expiration")
  let outbox = ServerStateOutbox(url: directory.appendingPathComponent("outbox.json"), retryDelay: .milliseconds(10))
  let delivery = Delivery(); await delivery.hold()
  let first = ServerStateOutbox.Record(item: .init(id: id, position: 1), stopped: false, revision: Date())
  try await outbox.submit(first) { try await delivery.send($0) }
  await until { await delivery.values().count == 1 }
  let second = ServerStateOutbox.Record(item: .init(id: id, position: 2), stopped: true, revision: first.revision.addingTimeInterval(1))
  try await outbox.submit(second) { try await delivery.send($0) }
  await delivery.release()
  await until { await outbox.pendingCount() == 0 }
  let values = await delivery.values(); precondition(values == [1, 2])
  await delivery.failOnce()
  let retry = ServerStateOutbox.Record(item: .init(id: otherID, position: 3), stopped: true, revision: Date())
  try await outbox.submit(retry) { try await delivery.send($0) }
  await until { await outbox.pendingCount() == 0 }
  let retried = await delivery.values(); precondition(retried.suffix(2) == [3, 3])
  let recoveryURL = directory.appendingPathComponent("recovery.json")
  try JSONEncoder().encode([second]).write(to: recoveryURL)
  let recovered = ServerStateOutbox(url: recoveryURL)
  await recovered.resume { try await delivery.send($0) }
  await until { await recovered.pendingCount() == 0 }
  print("PASS: serial delivery, new-state acknowledgement protection, network retry, persisted recovery")
  let state = PlaybackTransitionCoordinator()
  let ticket = state.begin(target: .mpv)!
  precondition(state.begin(target: .native) == nil)
  state.setIntent(false); state.finish(ticket)
  precondition(state.phase == .paused)
  let old = state.begin(target: .native)!
  state.invalidate(); state.finish(old)
  precondition(state.phase == .preparing)
  for _ in 0..<10 {
   let current = state.begin(target: .mpv)!; state.setIntent(true); state.finish(current)
   precondition(state.phase == .playing)
   let reverse = state.begin(target: .native)!; state.finish(reverse)
  }
  state.invalidate(closing: true); precondition(state.begin(target: .mpv) == nil)
  print("PASS: repeated bidirectional transitions, pause intent, duplicate/stale/closed transition rejection")
 }
}
'''
fixture = """
@MainActor final class LegacyMigrationFixture {
 let defaults: UserDefaults
 let serverOutbox: ServerStateOutbox
 var isDefaultProfile = true
 var items: [MediaItem]
 var errorMessage: String?
 init(defaults: UserDefaults, outbox: ServerStateOutbox, item: MediaItem) { self.defaults = defaults; serverOutbox = outbox; items = [item] }
 func deliverServerState(_ record: ServerStateOutbox.Record) async throws {}
""" + migration_method + "\n}\n"
stubs = stubs.replace('@main struct Checks {', fixture + '@main struct Checks {')
stubs = stubs.replace('  let state = PlaybackTransitionCoordinator()', r'''  let suite = "lucent-cleanup-check-" + UUID().uuidString
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let legacyKey = "lucent.network.pendingServerStates"
  defaults.set([id.uuidString], forKey: legacyKey)
  let migration = LegacyMigrationFixture(defaults: defaults, outbox: ServerStateOutbox(url: directory.appendingPathComponent("migration.json")), item: item)
  await migration.resumeServerStateSync()
  precondition(defaults.stringArray(forKey: legacyKey) == nil)
  let blocker = directory.appendingPathComponent("blocker")
  try Data([1]).write(to: blocker)
  defaults.set([id.uuidString], forKey: legacyKey)
  let failure = LegacyMigrationFixture(defaults: defaults, outbox: ServerStateOutbox(url: blocker.appendingPathComponent("migration.json")), item: item)
  await failure.resumeServerStateSync()
  precondition(defaults.stringArray(forKey: legacyKey) == [id.uuidString] && failure.errorMessage != nil)
  print("PASS: legacy outbox migration clears only after durable success; write failure retains recovery key")
  let state = PlaybackTransitionCoordinator()''')
with tempfile.TemporaryDirectory(prefix='lucent-architecture-') as temp:
    folder = Path(temp)
    (folder/'Checks.swift').write_text(stubs)
    paths = [str(root/'Sources/LucentApp'/name) for name in ['LibraryRepository.swift','ServerStateOutbox.swift','PlaybackTransitionCoordinator.swift','ArtworkDiskStore.swift']]
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(folder/'modules'),*paths,str(folder/'Checks.swift'),'-o',str(folder/'checks')],check=True)
    subprocess.run([str(folder/'checks')],check=True)
