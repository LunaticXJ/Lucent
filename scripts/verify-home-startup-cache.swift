import Foundation
struct MediaCard: Codable, Sendable { let id: String }
struct EmbySource: Sendable { let id: UUID; let baseAddress: String; let userID: String }
enum TMDBService { struct DetailArtwork: Codable, Sendable { let posterURL: URL? } }
@main struct Check {
 static func main() async throws {
 let folder = URL(fileURLWithPath: "/private/tmp/lucent-startup-cache-check-" + UUID().uuidString)
 defer { try? FileManager.default.removeItem(at: folder) }
 let cache = HomeStartupCache(directory:folder), id = UUID()
 func value(_ date:Date) -> HomeStartupSnapshot { .init(version:1,context:"account-language",savedAt:date,views:[.init(id:"library")],latest:[.init(id:"poster")],continuing:[],continuingTotal:0,shelves:[],artworks:[:],selectedHeroID:"poster") }
 await cache.write(id:id,value:value(Date()))
 let hit = await cache.read(id:id,context:"account-language"); precondition(hit?.latest.first?.id == "poster")
 let mismatch = await cache.read(id:id,context:"other-account"); precondition(mismatch == nil)
 await cache.update(id:id,context:"account-language",artworkID:"poster",artwork:.init(posterURL:URL(string:"https://example.com/poster")),selection:"other")
 let updated = await cache.read(id:id,context:"account-language"); precondition(updated?.selectedHeroID == "other" && updated?.artworks["poster"] != nil)
 await cache.write(id:id,value:value(Date(timeIntervalSinceNow: -8*86400)))
 let expired = await cache.read(id:id,context:"account-language"); precondition(expired == nil)
 try Data("broken".utf8).write(to:folder.appendingPathComponent(id.uuidString+".json"))
 let corrupt = await cache.read(id:id,context:"account-language"); precondition(corrupt == nil)
 print("PASS: restore, context isolation, artwork/selection update, expiration, corrupt-file fallback")
 }
}
