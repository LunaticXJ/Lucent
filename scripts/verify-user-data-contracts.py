#!/usr/bin/env python3
"""Offline checks for local favorites and the explicit iCloud settings allowlist."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
store = (root/'Sources/LucentApp/LibraryStore.swift').read_text()
toggle = store[store.index('    func toggleFavorite('):store.index('    func finishPlayback(')]
assert 'reportServerProgress' not in toggle
assert 'favoriteUpdatedAt = Date()' in toggle
assert 'stateUpdatedAt = Date()' not in toggle
assert '.favorite = remote.userData' not in store
assert '.favorite = value.userData' not in store
for line in store.splitlines():
    if 'Client.updateUserData(' in line:
        assert 'favorite:' not in line
assert 'case .embyItem, .jellyfinItem, .plexItem: continue' in store
assert 'CloudUserPreferences.apply(preferences)' in store
cloud = (root/'Sources/LucentApp/CloudPlaybackSync.swift').read_text()
preferences = cloud[cloud.index('enum CloudUserPreferences {'):]
source = 'import Foundation\nenum NetworkUsagePolicy { static func notifySettingsChanged() {} }\n' + preferences
source += r'''
let suite = "LucentUserDataTest." + UUID().uuidString
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
defaults.set("dark", forKey: "lucent.appearance.theme")
defaults.set(true, forKey: "lucent.iCloudSyncEnabled")
defaults.set("secret", forKey: "lucent.metadataToken")
let snapshot = CloudUserPreferences.capture(defaults: defaults)
precondition(snapshot["lucent.iCloudSyncEnabled"] == nil)
precondition(snapshot["lucent.metadataToken"] == nil)
defaults.set("light", forKey: "lucent.appearance.theme")
defaults.set(0.5, forKey: "lucent.danmaku.opacity")
var incoming = snapshot
incoming["lucent.iCloudSyncEnabled"] = try! PropertyListSerialization.data(fromPropertyList: [false], format: .binary, options: 0)
CloudUserPreferences.apply(incoming, defaults: defaults)
precondition(defaults.string(forKey: "lucent.appearance.theme") == "dark")
precondition(defaults.object(forKey: "lucent.danmaku.opacity") == nil)
precondition(defaults.bool(forKey: "lucent.iCloudSyncEnabled"))
precondition(defaults.string(forKey: "lucent.metadataToken") == "secret")
print("PASS: local favorites, server progress ownership, preferences round trip/reset, opt-in and credentials excluded")
'''
with tempfile.TemporaryDirectory(prefix='lucent-user-data-') as directory:
    path = Path(directory)
    (path/'main.swift').write_text(source)
    subprocess.run(['swiftc','-module-cache-path',str(path/'modules'),str(path/'main.swift'),'-o',str(path/'verify')],check=True)
    subprocess.run([str(path/'verify')],check=True)
