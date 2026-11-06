#!/usr/bin/env python3
"""Exercise the production native-home loader with deterministic in-process server fixtures."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
text = (root/'Sources/LucentApp/NativeExperience.swift').read_text()
model = text[text.index('@MainActor final class NativeHomeModel:'):text.index('struct NativeHomeView:')]
source = r'''
import Foundation
import Combine
struct JellyfinItem: Sendable { let id: String; let name: String; var type = "Movie" }
struct PlexItem: Sendable { let type: String }
struct Source: Sendable { let id: UUID; var baseAddress: String; var userID: String }
struct Profile { let id: UUID }
struct NativeCatalog: Sendable {
 let id: String; let sourceID: UUID?
 @MainActor static func all(in library: LibraryStore) -> [Self] { library.embySources.map { .init(id:"emby:\($0.id)",sourceID:$0.id) } }
}
struct NativeMediaEntry: Sendable {
 let catalog: NativeCatalog; let remote: JellyfinItem?; let plex: PlexItem?; let local: Int?
}
struct NativeShelf: Sendable {
 let id: String; let title: String; let entries: [NativeMediaEntry]; var landscape = false; var parentID: String? = nil
}
@MainActor enum LocalizationPreferences {
 struct Value { var contentLanguage = "zh-CN" }
 static var current = Value()
}
@MainActor final class LibraryStore {
 var activeProfile: Profile? = nil
 var embySources: [Source] = []; var jellyfinSources: [Source] = []; var plexSources: [Source] = []
 func synchronizeServerHome(sourceID: UUID, emby: Bool, displayedItems: [JellyfinItem]) async throws {}
 func synchronizePlexHome(sourceID: UUID) async throws {}
}
enum KeychainPasswordStore {
 static func embyToken(for id: UUID) throws -> String? { "fixture" }
 static func jellyfinToken(for id: UUID) throws -> String? { "fixture" }
 static func plexToken(for id: UUID) throws -> String? { "fixture" }
}
actor Fixture {
 static let shared = Fixture()
 var held = true
 var failShelf = true
 var reads = 0
 var latestFails = false
 func failLatest() { latestFails = true }
 func release() { held = false }
 func reset(fail: Bool) { held = true; failShelf = fail }
 func count() -> Int { reads }
 func latest(_ source: Source) throws -> [JellyfinItem] {
  reads += 1
  if latestFails { throw URLError(.timedOut) }
  return [.init(id:"new",name:source.baseAddress)]
 }
 func featured(_ id: String) async throws -> [JellyfinItem] {
  while held { try await Task.sleep(for:.milliseconds(5)) }
  if id == "bad" && failShelf { throw URLError(.cannotConnectToHost) }
  return [.init(id:id,name:id)]
 }
}
enum EmbyClient {
 struct Page: Sendable { let items: [JellyfinItem]; var totalCount: Int { items.count } }
 static func latest(source: Source, token: String) async throws -> [JellyfinItem] { try await Fixture.shared.latest(source) }
 static func resume(source: Source, token: String) async throws -> Page { .init(items:[.init(id:"resume",name:"resume")]) }
 static func browse(source: Source, token: String, parentID: String?) async throws -> Page { .init(items:[.init(id:"good",name:"good",type:"CollectionFolder"),.init(id:"bad",name:"bad",type:"CollectionFolder")]) }
 static func featured(source: Source, token: String, parentID: String, itemTypes: String) async throws -> Page { .init(items:try await Fixture.shared.featured(parentID)) }
 static func featuredItemTypes(for item: JellyfinItem) -> String { "Movie,Series" }
}
enum JellyfinClient {
 static func browsePage(source: Source, token: String, start: Int) async throws -> [JellyfinItem] { [] }
}
enum PlexClient {
 static func catalogPage(source: Source, token: String, start: Int) async throws -> [PlexItem] { [] }
}
'''
source += model
source += r'''
@main struct Checks {
 @MainActor static func waitForRoots(_ model: NativeHomeModel) async throws {
  for _ in 0..<200 {
   if model.loading && model.shelves.contains(where: { $0.id == "libraries" }) { return }
   try await Task.sleep(for:.milliseconds(5))
  }
  fatalError("Root content blocked behind library shelf requests")
 }
 @MainActor static func main() async throws {
  let library = LibraryStore(); let id = UUID()
  library.embySources = [.init(id:id,baseAddress:"https://one.invalid",userID:"one")]
  let catalog = NativeCatalog(id:"emby:\(id)",sourceID:id)
  let model = NativeHomeModel()
  let first = Task { await model.load(catalog:catalog,library:library) }
  try await waitForRoots(model)
  precondition(model.shelves.contains { $0.id == "latest" && !$0.entries.isEmpty })
  await Fixture.shared.release(); await first.value
  precondition(!model.loading)
  precondition(model.shelfErrors["bad"] != nil)
  precondition(model.shelves.contains { $0.id == "bad" })
  precondition(model.shelves.first { $0.id == "good" }?.entries.count == 1)
  await Fixture.shared.reset(fail:false)
  let cancelled = Task { await model.load(catalog:catalog,library:library,force:true) }
  try await waitForRoots(model); cancelled.cancel(); await cancelled.value
  precondition(!model.loading && model.error == nil)
  await Fixture.shared.release()
  await model.load(catalog:catalog,library:library,force:true)
  let before = await Fixture.shared.count()
  await model.load(catalog:catalog,library:library)
  let cached = await Fixture.shared.count(); precondition(cached == before)
  library.embySources[0].userID = "two"
  await model.load(catalog:catalog,library:library)
  let changedUser = await Fixture.shared.count(); precondition(changedUser == before + 1)
  LocalizationPreferences.current.contentLanguage = "en-US"
  await model.load(catalog:catalog,library:library)
  let changedLanguage = await Fixture.shared.count(); precondition(changedLanguage == changedUser + 1)
  library.embySources[0].baseAddress = "https://two.invalid"
  await model.load(catalog:catalog,library:library)
  let changedHost = await Fixture.shared.count(); precondition(changedHost == changedLanguage + 1)
  await Fixture.shared.reset(fail:false)
  await model.load(catalog:catalog,library:library,force:true,rootOnly:true)
  precondition(!model.loading && model.shelves.contains { $0.id == "latest" })
  await Fixture.shared.release(); await Fixture.shared.failLatest()
  await model.load(catalog:catalog,library:library,force:true)
  precondition(!model.loading && model.error != nil)
  precondition(model.shelves.contains { $0.id == "continue" && !$0.entries.isEmpty })
  print("PASS: independent root failure, root-only recommendations, staged home publication, library navigation shelf, partial errors, cancellation/loading recovery and cache separation by account/language/address")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-native-home-') as directory:
 p = Path(directory); (p/'check.swift').write_text(source)
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(p/'modules'),str(p/'check.swift'),'-o',str(p/'verify')],check=True)
 subprocess.run([str(p/'verify')],check=True)
