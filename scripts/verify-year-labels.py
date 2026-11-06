#!/usr/bin/env python3
"""Exercise the actual year-range formatter without UI or network access."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/MediaCard.swift').read_text()
formatter = source[source.index('enum CatalogYearLabel {'):]
fixture = '''import Foundation
extension String { var lucentLocalized: String { self } }
''' + formatter + '''
func year(_ start: Int? = 2024, series: Bool = true, status: String? = nil, end: String? = nil) -> String? {
    CatalogYearLabel.text(start: start, isSeries: series, status: status, endDate: end, present: "现在")
}
assert(year(status: "Continuing") == "2024")
assert(year(status: "Returning Series", end: "2025-01-01") == "2024")
assert(year(status: "In Production") == "2024")
assert(year(status: "Ended", end: "2026-01-01") == "2024")
assert(year(status: "Canceled", end: "2024-12-31") == "2024")
assert(year(status: nil, end: nil) == "2024")
assert(year(series: false, status: "Continuing", end: "2026-01-01") == "2024")
assert(year(nil, status: "Continuing") == nil)
assert(year(0, status: "Continuing") == nil)
assert(CatalogYearLabel.text(start: 2024, isSeries: true, status: "Continuing", endDate: nil, present: "Present") == "2024")
print("PASS: start-year-only labels for ongoing/ended/canceled/unknown series, movies and missing years")
'''
with tempfile.TemporaryDirectory(prefix='lucent-year-labels-') as directory:
    test = Path(directory) / 'main.swift'
    test.write_text(fixture)
    subprocess.run(['swift', '-module-cache-path', str(Path(directory) / 'cache'), str(test)], check=True)
