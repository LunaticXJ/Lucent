#!/usr/bin/env python3
"""Offline regression checks for server-side folder filtering and empty-page pagination."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
client = (root / 'Sources/LucentApp/EmbyClient.swift').read_text()
browser = (root / 'Sources/LucentApp/EmbyBrowserView.swift').read_text()

def block(source, marker):
    start = source.index(marker)
    cursor = source.index('{', start) + 1
    depth = 1
    while depth:
        if source[cursor] == '{': depth += 1
        elif source[cursor] == '}': depth -= 1
        cursor += 1
    return source[start:cursor]

swift = '''import Foundation
struct EmbySource { let baseAddress: String; let userID: String }
enum EmbyError: Error { case invalidResponse }
// Isolate the request builder's device-ID store from the user's app preferences.
enum UserDefaults {
 static let standard = Store()
 struct Store {
  func string(forKey: String) -> String? { "fixture-device" }
  func set(_ value: String, forKey: String) {}
 }
}
enum EmbyClient {
'''
for marker in ['enum BrowseSort:', 'enum BrowseFacet:', 'static func browseRequest(', 'private static func makeRequest(']:
    swift += block(client, marker) + '\n'
swift += '}\nstruct JellyfinSource { let baseAddress: String; let userID: String }\nenum JellyfinError: Error { case invalidResponse }\nenum JellyfinClient {\n'
jelly = (root / 'Sources/LucentApp/JellyfinClient.swift').read_text()
for marker in ['static func directoryRequest(', 'private static func makeRequest(']:
    swift += block(jelly, marker) + '\n'
swift += '''}
struct PageState {
 let loaded: Bool
 let entries: [Int]
 let nextStartIndex: Int
 let totalCount: Int
'''
swift += block(browser, 'private var hasMorePages:').replace('private ', '')
swift += '''
}
@main struct Checks {
 static func query(_ request: URLRequest) -> [String:String] {
  let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems ?? []
  precondition(Set(items.map(\\.name)).count == items.count, "Query keys must be unique")
  return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
 }
 static func main() throws {
  let source = EmbySource(baseAddress: "https://fixture.invalid/emby", userID: "fixture-user")
  let folder = try EmbyClient.browseRequest(source: source, token: "fixture", parentID: "library",
   startIndex: 48, limit: 48, includeMediaDetails: false, foldersOnly: true)
  let folders = query(folder)
  precondition(folders["IsFolder"] == "true")
  precondition(folders["ExcludeItemTypes"] == "Series")
  precondition(folders["Recursive"] == "false")
  precondition(folders["IncludeItemTypes"] == nil)
  precondition(folders["StartIndex"] == "48" && folders["Limit"] == "48")
  precondition(folders["Fields"] == "DateCreated,ProductionYear")
  precondition(folder.value(forHTTPHeaderField: "X-Emby-Token") == "fixture")
  let series = query(try EmbyClient.browseRequest(source: source, token: "fixture", parentID: "library",
   itemType: "Series", facet: .genre("genre-fixture")))
  precondition(series["Recursive"] == "true" && series["IncludeItemTypes"] == "Series")
  precondition(series["GenreIds"] == "genre-fixture")
  precondition(series["IsFolder"] == nil && series["ExcludeItemTypes"] == nil)
  precondition(series["Fields"]!.contains("MediaSources"))
  let recentEpisodes = query(try EmbyClient.browseRequest(source: source, token: "fixture", parentID: "library",
   itemType: "Series", sort: .latestEpisodeAdded, ascending: false, includeMediaDetails: false))
  precondition(recentEpisodes["SortBy"] == "DateLastContentAdded")
  precondition(recentEpisodes["SortOrder"] == "Descending")
  precondition(recentEpisodes["Fields"]!.contains("ProductionYear"))
  precondition(!PageState(loaded: true, entries: [], nextStartIndex: 48, totalCount: 100).hasMorePages)
  precondition(!PageState(loaded: true, entries: [], nextStartIndex: 0, totalCount: 0).hasMorePages)
  precondition(PageState(loaded: true, entries: [1,2], nextStartIndex: 48, totalCount: 100).hasMorePages)
  precondition(!PageState(loaded: true, entries: [1,2], nextStartIndex: 100, totalCount: 100).hasMorePages)
  precondition(!PageState(loaded: false, entries: [1,2], nextStartIndex: 48, totalCount: 100).hasMorePages)
  let all = try EmbyClient.browseRequest(source: source, token: "fixture", parentID: nil, itemType: "Movie,Series", sort: .added, ascending: false)
  precondition(all.url!.path.hasSuffix("/Items"))
  precondition(query(all)["Recursive"] == "true" && query(all)["ParentId"] == nil)
  let libraries = try EmbyClient.browseRequest(source: source, token: "fixture", parentID: nil)
  precondition(libraries.url!.path.hasSuffix("/Views"))
  let jf = JellyfinSource(baseAddress: "https://fixture.invalid/jellyfin", userID: "u")
  let child = try JellyfinClient.directoryRequest(source: jf, token: "fixture", parentID: "season", start: 17, limit: 60)
  let childQuery = query(child)
  precondition(childQuery["ParentId"] == "season" && childQuery["Recursive"] == "false")
  precondition(childQuery["IncludeItemTypes"] == nil && childQuery["StartIndex"] == "17")
  precondition(childQuery["EnableUserData"] == "true" && child.value(forHTTPHeaderField: "X-Emby-Token") == "fixture")
  let top = query(try JellyfinClient.directoryRequest(source: jf, token: "fixture", parentID: nil))
  precondition(top["Recursive"] == "true" && top["IncludeItemTypes"] == "Movie,Series")
  print("PASS: folder/series filtering, empty pagination, root library vs title routes, Jellyfin parent/season preservation and playback user data")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-browser-pagination-') as directory:
    path = Path(directory)
    (path / 'checks.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-parse-as-library',
                    '-module-cache-path', str(path / 'modules'), str(path / 'checks.swift'),
                    '-o', str(path / 'checks')], check=True)
    subprocess.run([str(path / 'checks')], check=True)
