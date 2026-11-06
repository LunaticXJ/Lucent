#!/usr/bin/env python3
"""Check hero geometry remains stable when the viewport changes for system UI."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/MobileHomeView.swift').read_text()
start = source.index('private enum HomeHeroLayout {')
end = source.index('\nprivate struct HomeBrowserRoute:', start)
mount_start = source.index('    private var mountedHeroIndices:')
mount_end = source.index('    private func hero(height:', mount_start)
mounted = source[mount_start:mount_end].replace('private var mountedHeroIndices:', 'var mountedHeroIndices:')
fixture = 'import Foundation\n' + source[start:end] + '''
struct Mounted {
    var latest: [Int]
    var heroIndex: Int
    var outgoingHeroIndex: Int?
    var heroDragTarget: Int?
''' + mounted + '''
}
assert(Mounted(latest: [], heroIndex: 0).mountedHeroIndices.isEmpty)
assert(Mounted(latest: [0], heroIndex: 0).mountedHeroIndices == [0])
assert(Mounted(latest: [0, 1], heroIndex: 0).mountedHeroIndices == [0, 1])
assert(Mounted(latest: Array(0..<8), heroIndex: 0).mountedHeroIndices == [0, 1, 7])
assert(Mounted(latest: Array(0..<8), heroIndex: 4, outgoingHeroIndex: 0).mountedHeroIndices == [0, 3, 4, 5])
assert(Mounted(latest: Array(0..<8), heroIndex: 7, outgoingHeroIndex: 12, heroDragTarget: 0).mountedHeroIndices == [0, 6, 7])

let window = CGSize(width: 440, height: 956)
let initial = HomeHeroLayout.height(windowSize: window, viewportSize: window, isPad: false, scale: 3)
for height in [840.0, 780.0, 956.0] {
    let changed = HomeHeroLayout.height(windowSize: window, viewportSize: CGSize(width: 440, height: height), isPad: false, scale: 3)
    assert(initial == changed)
}
assert(initial == HomeHeroLayout.height(windowSize: CGSize(width: 956, height: 440), viewportSize: window, isPad: false, scale: 3))
assert(HomeHeroLayout.height(windowSize: nil, viewportSize: window, isPad: false, scale: 3) == initial)
assert(HomeHeroLayout.height(windowSize: CGSize(width: 600, height: 800), viewportSize: window, isPad: true, scale: 2) == 650)
print("PASS: stable window height across viewport changes, rotation, initial fallback, iPad and bounded carousel mounting")
'''
with tempfile.TemporaryDirectory(prefix='lucent-hero-layout-') as directory:
    test = Path(directory) / 'main.swift'
    test.write_text(fixture)
    subprocess.run(['swift', '-module-cache-path', str(Path(directory) / 'cache'), str(test)], check=True)
