#!/usr/bin/env python3
"""Exercise production marker parsing/resolution without playback or network."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
rules = (root / 'Sources/LucentApp/PlaybackSkipRules.swift').read_text()
segments = (root / 'Sources/LucentApp/PlaybackSegments.swift').read_text()
checks = r'''
struct PlaybackChapter { let index: Int; let title: String; let start: Double }
func check(_ condition: @autoclosure () -> Bool, _ name: String) { precondition(condition(), name) }
check(PlaybackSkipRules.parseTime("01:30") == 90, "minute clock")
check(PlaybackSkipRules.parseTime("1:02:03") == 3723, "hour clock")
check(PlaybackSkipRules.parseTime("90") == 90, "seconds")
for invalid in ["1:99", "1::2", "-3", "nan", "", "00:00"] { check(PlaybackSkipRules.parseTime(invalid) == nil, "reject invalid time") }
let markers = [PlaybackSegment(kind: .intro, start: 10, end: 90), PlaybackSegment(kind: .credits, start: 1600, end: 1800)]
let resolved = PlaybackSkipRules.resolved(server: markers, introEnd: 60, creditsStart: nil, creditsDuration: 120, duration: 1800)
check(resolved.count == 2 && resolved[0].start == 0 && resolved[0].end == 60, "manual intro overrides server")
check(resolved[1].start == 1680 && resolved[1].end == 1800, "tail duration is relative")
let next = PlaybackSkipRules.resolved(server: [], introEnd: 60, creditsStart: nil, creditsDuration: 120, duration: 2000)
check(next.last?.start == 1880, "different episode duration")
check(PlaybackSkipRules.active(in: resolved, at: 0) == nil, "avoid cold-open skip")
check(PlaybackSkipRules.active(in: resolved, at: 1)?.kind == .intro, "intro window")
check(PlaybackSkipRules.active(in: resolved, at: 59.9) == nil, "hide before boundary")
check(PlaybackSkipRules.resolved(server: [], introEnd: 1800, creditsStart: nil, creditsDuration: nil, duration: 1800).isEmpty, "do not skip entire film")
let emby: [[String: Any]] = [
    ["StartPositionTicks": 100_000_000, "Name": "Chapter 1", "MarkerType": "IntroStart"],
    ["StartPositionTicks": 900_000_000, "Name": "Chapter 2", "MarkerType": "IntroEnd"],
    ["StartPositionTicks": 16_800_000_000, "Name": "Chapter 3", "MarkerType": "CreditsStart"]]
let parsed = PlaybackSegmentClient.fromEmbyChapters(emby, duration: 1800)
check(parsed.contains { $0.kind == .intro && $0.start == 10 && $0.end == 90 }, "explicit Emby markers without named chapters")
check(parsed.contains { $0.kind == .credits && $0.start == 1680 }, "explicit Emby credits")
let chapter = PlaybackSegmentClient.fromChapters([.init(index: 1, title: "Main", start: 90), .init(index: 0, title: "Opening", start: 0)], duration: 1800)
check(chapter.count == 1 && chapter[0].end == 90, "sort chapters before deriving boundaries")
print("PASS: time parsing, manual/server precedence, per-episode credits and safe skip windows")
'''
with tempfile.TemporaryDirectory(prefix='lucent-skip-') as directory:
    path = Path(directory)/'main.swift'; path.write_text(rules+'\n'+segments+'\n'+checks)
    subprocess.run(['swift', '-module-cache-path', '/tmp/lucent-swift-module-cache', str(path)], check=True)
