#!/usr/bin/env python3
"""Offline regression checks for episode entry/selection priority and visible page alignment."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/SeriesDetailView.swift').read_text()
def block(marker):
    start = source.index(marker)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor].replace('private ', '')

swift = '''import Foundation
extension String { var lucentLocalized: String { self } }
struct Episode {
 let id: String
 let parentIndexNumber: Int?
 let indexNumber: Int?
 var progress: Double = 0
 var watched = false
 var lastPlayedAt: Date? = nil
}
typealias JellyfinItem = Episode
struct Entry { let id: UUID }
struct Local { let lastPlayedAt: Date? }
final class Fixture {
 var selectedEpisodeID: String? = nil
 var remoteID: String? = nil
 var item = Entry(id: UUID())
 var isSeriesEntry = false
 var episodes: [Episode] = []
 var season = 1
 var episodePage = 0
 func episodeWatched(_ episode: Episode) -> Bool { episode.watched }
 func episodeProgressSeconds(_ episode: Episode) -> Double { episode.progress }
 func localItem(for episode: Episode) -> Local? { episode.lastPlayedAt.map { Local(lastPlayedAt: $0) } }
'''
for marker in ['private var seasonEpisodes:', 'private var shownEpisodes:', 'private var activeEpisode:',
               'private var activeEpisodeLabel:', 'private func revealActiveEpisode(']:
    swift += block(marker) + '\n'
swift += '''}
@main struct Checks {
 static func main() {
  let f = Fixture()
  f.episodes = (1...25).map { Episode(id:"ep-\\($0)",parentIndexNumber:2,indexNumber:$0,progress:$0 == 2 ? 900 : 0) }
  f.remoteID = "ep-18"
  precondition(f.activeEpisode?.id == "ep-18", "The opened episode outranks a different unfinished episode")
  f.revealActiveEpisode()
  precondition(f.season == 2 && f.episodePage == 1)
  precondition(f.shownEpisodes.contains { $0.id == "ep-18" })
  precondition(f.activeEpisodeLabel == "第2季·第18集")
  f.selectedEpisodeID = "ep-24"
  precondition(f.activeEpisode?.id == "ep-24", "Explicit selection outranks the opened episode")
  f.revealActiveEpisode()
  precondition(f.episodePage == 2 && f.shownEpisodes.contains { $0.id == "ep-24" })
  f.selectedEpisodeID = nil
  f.isSeriesEntry = true
  precondition(f.activeEpisode?.id == "ep-2", "Series entries retain resumable episode selection")
  let local = Fixture()
  let localID = local.item.id.uuidString
  local.episodes = [Episode(id:"unfinished",parentIndexNumber:1,indexNumber:1,progress:900),
                    Episode(id:localID,parentIndexNumber:3,indexNumber:8)]
  precondition(local.activeEpisode?.id == localID, "Local episode entry has the same priority as server entry")
  let empty = Fixture()
  precondition(empty.activeEpisode == nil && empty.activeEpisodeLabel == nil)
  print("PASS: incoming/selected episode priority, local/server parity, season/page alignment and season-episode captions")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-episode-selection-') as directory:
    path = Path(directory)
    (path / 'checks.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-module-cache-path', str(path / 'modules'), str(path / 'checks.swift'),
                    '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
