#!/usr/bin/env python3
"""Check bounded unique batching and prevent home detail/sync request fan-out."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/ServerCatalogSync.swift').read_text()
a = source.index('    static func batches(')
b = source.index('    static func cachedItems', a)
fixture = 'import Foundation\nenum Batches {\n' + source[a:b] + '''}
assert(Batches.batches(ids: []).isEmpty)
let ids = (0..<181).map(String.init)
let pages = Batches.batches(ids: ids + ids)
assert(pages.count == 3)
assert(pages.allSatisfy { $0.count <= 80 })
assert(Set(pages.flatMap { $0 }) == Set(ids))
assert(pages.flatMap { $0 }.count == 181)
print("PASS: zero/duplicate/multiple-batch request bounds")
'''
with tempfile.TemporaryDirectory(prefix='lucent-request-scope-') as d:
    test = Path(d) / 'main.swift'; test.write_text(fixture)
    subprocess.run(['swift', '-module-cache-path', str(Path(d)/'cache'), str(test)], check=True)
home = (root / 'Sources/LucentApp/MobileHomeView.swift').read_text()
assert 'ServerDetailClient.item(' not in home
store = (root / 'Sources/LucentApp/LibraryStore.swift').read_text()
sync = store[store.index('    func synchronizeServerHome('):store.index('    func openEmbyItem(')]
assert 'ServerCatalogSync.cachedItems' not in sync
assert 'let remote = displayedItems' in sync and 'guard requested.contains(key)' in sync
assert 'LucentCatalogCaption(' not in home
assert 'Text(item.yearText ?? " ")' in home
print('PASS: home has no per-item detail requests; state sync is scoped to supplied rows and issues no request')
