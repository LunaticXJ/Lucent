#!/usr/bin/env python3
"""Run production resume policy and LibraryStore write path without launching playback."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
policy = (root / 'Sources/LucentApp/PlaybackProgressPolicy.swift').read_text().split('import SwiftUI')[0]
tracker = (root / 'Sources/LucentApp/PlaybackDiagnostics.swift').read_text()
tracker = tracker[tracker.index('struct PlaybackProgressTracker {'):tracker.index('\nenum PlaybackLogHistory')]
store = (root / 'Sources/LucentApp/LibraryStore.swift').read_text()
write = store[store.index('    func updateProgress(id:'):store.index('    func markUnwatched')]
# Inject a deterministic policy; the production body is otherwise unmodified.
write = write.replace('PlaybackProgressPolicy.current', 'policy')
fixture = '''
struct Tech { var duration: Double = 0 }
struct Item {
    var id = UUID()
    var position = 300.0
    var duration: Double? = 1000
    var watched = false
    var lastPlayedAt: Date?
    var stateUpdatedAt: Date?
    var technicalInfo: Tech? = nil
}
final class RepositoryFixture {
    func enqueueItem(_ item: Item, profileID: UUID?, onError: @escaping (String) -> Void) {}
}
final class Store {
    var database: RepositoryFixture? = nil
    var activeProfileID: UUID? = nil
    var errorMessage: String? = nil
    func scheduleSync() {}
    var items = [Item()]
    var policy = PlaybackProgressPolicy()
    var lastServerReport: [UUID: Date] = [:]
    var completions = 0
    var reports: [Item] = []
    func markWatched(id: UUID) { completions += 1 }
    func reportServerProgress(item: Item, stopped: Bool) { reports.append(item) }
    func save() {}
'''+write+'\n}\n'
checks = r'''
func check(_ value: @autoclosure () -> Bool, _ name: String) { precondition(value(), name) }
let policy = PlaybackProgressPolicy()
check(policy.state(position: 49.99, duration: 1000) == .beginning, "before minimum")
check(policy.state(position: 50, duration: 1000) == .resumable(50), "minimum inclusive")
check(policy.state(position: 899.99, duration: 1000) == .resumable(899.99), "before completion")
check(policy.state(position: 900, duration: 1000) == .completed, "completion inclusive")
check(policy.state(position: 2000, duration: 1000) == .completed, "overrun")
check(policy.state(position: .nan, duration: 1000) == .unavailable, "invalid clock")
check(policy.state(position: 100, duration: nil) == .unavailable, "unknown duration")
check(policy.resumePosition(position: 100, duration: nil, watched: false) == 100, "keep existing checkpoint if probe fails")
check(policy.resumePosition(position: 30, duration: 1000, watched: false) == 0, "do not resume intro")
check(policy.resumePosition(position: 920, duration: 1000, watched: false) == 0, "ignore legacy completed checkpoint")
check(policy.resumePosition(position: 300, duration: 1000, watched: true) == 0, "completed restarts")
let custom = PlaybackProgressPolicy(minimumPercent: 2, completedPercent: 95)
check(custom.state(position: 20, duration: 1000) == .resumable(20), "custom start")
check(custom.state(position: 940, duration: 1000) == .resumable(940), "custom end")
check(custom.state(position: 950, duration: 1000) == .completed, "custom complete")
let invalid = PlaybackProgressPolicy(minimumPercent: 100, completedPercent: .nan)
check(invalid.minimumPercent < invalid.completedPercent, "sanitize settings")
let store = Store()
let id = store.items[0].id
store.updateProgress(id: id, position: 20, duration: 1000)
check(store.items[0].position == 0 && !store.items[0].watched, "beginning clears resume")
store.updateProgress(id: id, position: 300, duration: 1000)
check(store.items[0].position == 300, "save qualified progress")
store.updateProgress(id: id, position: .nan, duration: 1000)
check(store.items[0].position == 300, "invalid callback cannot clear checkpoint")
store.updateProgress(id: id, position: 900, duration: 1000)
check(store.items[0].position == 0 && store.items[0].watched, "completion clears resume and marks watched")
check(store.completions == 1 && store.reports.last?.watched == true && store.reports.last?.position == 0, "completion sync emitted immediately")
store.updateProgress(id: id, position: 950, duration: 1000)
check(store.completions == 1, "completion not repeatedly marked")
store.updateProgress(id: id, position: 100, duration: 1000)
check(store.items[0].watched && store.items[0].position == 0, "rewatch does not undo watched status")
store.items[0].watched = false
store.items[0].position = 250
store.items[0].duration = nil
store.updateProgress(id: id, position: 2, duration: nil)
check(store.items[0].position == 250, "unknown duration preserves checkpoint")
var transport = PlaybackProgressTracker(initialPosition: 300)
transport.beginLoad(at: 300)
check(!transport.observe(0, ready: true), "startup flash cannot erase resume")
check(transport.observe(900, ready: true), "live completion position confirmed")
check(transport.recoveryPosition == 900, "handover retains live clock despite persisted zero")
print("PASS: percentage boundaries, writes, replay, unknown duration, completion sync and live handover clock")
'''
with tempfile.TemporaryDirectory(prefix='lucent-progress-') as directory:
    source = Path(directory) / 'main.swift'
    source.write_text(policy+'\n'+tracker+'\n'+fixture+'\n'+checks)
    subprocess.run(['swift', '-module-cache-path', '/tmp/lucent-swift-module-cache', str(source)], check=True)
