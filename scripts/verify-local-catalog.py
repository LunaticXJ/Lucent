#!/usr/bin/env python3
"""Offline catalog contracts using production models, parser and TMDB client.
No app launch, network requests or user media access.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
def read(name): return (root/'Sources/LucentApp'/name).read_text()
jelly_source = read('JellyfinClient.swift')
jelly = jelly_source.split('enum JellyfinClient {')[0] + jelly_source[jelly_source.index('extension JellyfinItem {'):]
diag = read('PlaybackDiagnostics.swift')
features = diag[diag.index('struct PlaybackMediaFeatures:'):diag.index('enum MediaInfoLabels {')]
collection = read('LocalCatalogCollectionView.swift')
collection = collection[collection.index('enum LocalCatalogCollection:'):collection.index('struct LocalCatalogArtwork:')]
source = '\n'.join([read('PlaybackProgressPolicy.swift').split('import SwiftUI')[0], read('LocalizationPreferences.swift'), read('MediaCard.swift'), read('LocalCatalogIndex.swift'), collection, read('AggregateLibraryModels.swift'), read('MediaItem.swift'), jelly, features,
    'enum MediaInfoLabels { static func known(_ value: String?) -> String? { value } }',
    read('LocalLibraryCatalog.swift'), read('MediaNameParser.swift'), read('TMDBService.swift').replace('URLSession.shared','FixtureSession.shared')])
source += r'''
enum FixtureSession {
 static let shared: URLSession = {
  let config = URLSessionConfiguration.ephemeral; config.urlCache = nil; config.protocolClasses = [Fixture.self]
  return URLSession(configuration: config)
 }()
}
final class Fixture: URLProtocol {
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  let url = request.url!
  precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.contains { $0.name == "language" && $0.value == TMDBService.deviceLanguage })
  precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
  let json: [String:Any]
  if url.path.contains("/search/") {
   json = ["results":[["id":1,"title":"沙丘","original_title":"Dune","release_date":"1984-12-14"], ["id":2,"title":"沙丘","original_title":"Dune","release_date":"2021-09-15"]]]
  } else if url.path.contains("/episode/") {
   json = ["name":"第一集","overview":"单集简介","still_path":"/still.jpg","air_date":"2026-10-01","vote_average":8.5]
  } else {
   json = ["id":2,"title":"沙丘","overview":"电影简介","poster_path":"/poster.jpg","backdrop_path":"/backdrop.jpg","vote_average":8.1,"release_date":"2021-09-15","genres":[["name":"科幻"]],"credits":["cast":[["id":3,"name":"演员","character":"角色","profile_path":"/person.jpg"]]]]
  }
  client!.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
  client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json)); client!.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Checks {
 static func main() async throws {
  // Regression: the phone's 80 unmatched episodes belonged to these two year-suffixed folders.
  for (folder, title, year) in [("我们的歌 2019", "我们的歌", 2019), ("我想和你唱 2016", "我想和你唱", 2016), ("我们的歌 (2019)", "我们的歌", 2019), ("我们的歌（2019）", "我们的歌", 2019)] {
   let query = CatalogMatching.seriesQuery(folder)
   precondition(query.title == title && query.year == year)
   let candidate = try JSONDecoder().decode(TMDBSearchResult.self, from: JSONSerialization.data(withJSONObject: ["id":100,"name":title,"first_air_date":"\(year)-01-01"]))
   precondition(CatalogMatching.best([candidate],title:query.title,year:query.year)?.id == 100)
   precondition(CatalogMatching.best([candidate],title:folder,year:nil) == nil)
  }
  precondition(CatalogMatching.seriesQuery("1984").title == "1984")
  precondition(CatalogMatching.seriesQuery("我们的歌2019").year == nil)
  precondition(CatalogMatching.seriesQuery("我们的歌").year == nil)
  let results = try await TMDBService.search(title:"沙丘", television:false, token:"fixture")
  precondition(CatalogMatching.best(results,title:"沙丘",year:2021)?.id == 2)
  precondition(CatalogMatching.best(results,title:"Dune",year:1984)?.id == 1)
  precondition(CatalogMatching.best(results,title:"沙丘",year:nil) == nil)
  precondition(CatalogMatching.best(results,title:"沙丘",year:2020) == nil)
  let meta = try await TMDBService.catalog(id:2,television:false,token:"fixture")
  precondition(meta.catalogVersion == 2 && meta.year == 2021 && meta.genres == ["科幻"] && meta.cast?.first?.profilePath == "/person.jpg")
  let episode = try await TMDBService.catalogEpisode(id:2,season:1,number:1,token:"fixture")
  precondition(episode.stillPath == "/still.jpg")
  let parsed = MediaNameParser.parse(relativePath:"玉簟秋/第2季/01.mkv")
  precondition(parsed.identity == .episode(series:"玉簟秋",season:2,number:1,name:nil))
  precondition(MediaNameParser.parse(relativePath:"玉簟秋/第2季/第02集.mp4").identity == .episode(series:"玉簟秋",season:2,number:2,name:nil))
  precondition(MediaNameParser.parse(filename:"兰香如故 第01集.mkv").identity == .episode(series:"兰香如故",season:1,number:1,name:nil))
  var item = MediaItem(title:"沙丘",location:.remote(URL(string:"https://fixture.invalid/movie.mkv")!),identity:.movie(year:2021))
  item.metadata = meta
  item.technicalInfo = .init(probedAt:Date(),duration:120,container:"mkv",width:1920,height:1080,videoCodec:"hevc",dynamicRange:"HDR10",streamData:Data(#"[{"Type":"Video","Codec":"hevc","Width":1920,"Height":1080},{"Type":"Audio","Codec":"aac","Channels":2},{"Type":"Subtitle","Codec":"ass","Index":2,"IsDefault":true}]"#.utf8))
  let detail = item.localDetailItem()!
  precondition(detail.mediaSources?.first?.mediaStreams?.count == 3 && detail.runTimeTicks == 1200000000 && detail.genres == ["科幻"])
  precondition(detail.people?.first?.name == "演员")
  precondition(item.localPlaybackFeatures.styledSubtitleStreamIndices == [2] && item.localPlaybackFeatures.dynamicRange == "HDR10")
  var invalidDuration = item
  invalidDuration.technicalInfo!.duration = Double.greatestFiniteMagnitude
  invalidDuration.duration = nil
  precondition(invalidDuration.localDetailItem()?.runTimeTicks == nil)
  precondition(MediaIdentity.episode(series:"Show",season:1,number:11,name:nil).episodeSortOrder < MediaIdentity.episode(series:"Show",season:1,number:100,name:nil).episodeSortOrder)
  let roundtrip = try JSONDecoder().decode(MediaItem.self, from: JSONEncoder().encode(item))
  precondition(roundtrip == item)
  var old = try JSONSerialization.jsonObject(with:JSONEncoder().encode(item)) as! [String:Any]
  for key in ["technicalInfo","catalogEpisode","metadataRetryAfter","metadataMatchStatus"] { old.removeValue(forKey:key) }
  let legacy = try JSONDecoder().decode(MediaItem.self,from:JSONSerialization.data(withJSONObject:old))
  precondition(legacy.technicalInfo == nil && legacy.id == item.id && legacy.position == item.position)
  var tv = MediaItem(title:"第1集",location:item.location,identity:.episode(series:"Show",season:1,number:1,name:nil))
  tv.metadata = meta; tv.catalogEpisode = episode
  precondition(tv.localDetailItem()?.overview == "单集简介" && tv.localDetailItem(asSeries:true)?.overview == "电影简介")
  var tv2 = tv; tv2.identity = .episode(series:"Show",season:1,number:2,name:nil)
  precondition(tv.catalogGroupID == tv2.catalogGroupID && tv.catalogGroupID != item.catalogGroupID)
  item.addedAt = Date(timeIntervalSince1970: 1000)
  tv.addedAt = Date(timeIntervalSince1970: 500); tv.watched = true
  tv2.addedAt = Date(timeIntervalSince1970: 2000); tv2.watched = false; tv2.favorite = true
  let card = MediaCard(local: tv, asSeries: true)
  precondition(card.type == "Series" && card.rating == tv.metadata?.rating)
  precondition(card.legacyPresentation.providerIds?["Tmdb"] == String(tv.metadata!.providerID))
  let serverCard = MediaCard(server: card.legacyPresentation)
  precondition(serverCard.id == card.id && serverCard.title == card.title)
  let index = LocalCatalogIndex(files: [item, tv, tv2])
  precondition(index.cards.count == 2 && index.groups[tv.catalogGroupID]?.count == 2)
  let cards = [item, tv]
  let files = [item, tv, tv2]
  precondition(LocalCatalogCollection.all.items(cards: cards, files: files).first?.catalogGroupID == tv.catalogGroupID)
  precondition(LocalCatalogCollection.favorites.items(cards: cards, files: files).first?.catalogGroupID == tv.catalogGroupID)
  precondition(LocalCatalogCollection.unwatched.items(cards: cards, files: files).contains { $0.catalogGroupID == tv.catalogGroupID })
  precondition(!LocalCatalogCollection.isWatched(tv, members: [tv, tv2]))
  precondition(LocalCatalogCollection.isWatched(tv, members: [tv]))
  // Home classification is disjoint, keeps explicit folders and uses TMDB IDs across languages.
  var classified = tv
  classified.metadata!.originCountries = ["CN"]; classified.metadata!.genreIDs = [18]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .chineseSeries)
  classified.metadata!.genreIDs = [16]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .chineseAnimation)
  classified.metadata!.genreIDs = [10764]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .variety)
  classified.metadata!.genreIDs = [99]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .documentaries)
  classified.metadata!.genreIDs = [18]; classified.metadata!.originCountries = ["JP"]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .asianSeries)
  classified.metadata!.originCountries = ["US"]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .westernSeries)
  classified.catalogPath = "电视剧/国产剧/Show/S01E01.mkv"
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == .chineseSeries)
  classified.catalogPath = nil; classified.metadata!.originCountries = []; classified.metadata!.originalLanguage = nil
  classified.metadata!.genres = ["剧情"]
  precondition(LocalCatalogCollection.category(classified,members:[classified]) == nil)
  precondition(LocalCatalogCollection.homeCategories.map(\.title) == ["电影","国产剧","综艺","国漫","日韩剧","欧美剧","纪录片"])
  precondition(LocalCatalogCollection.category(item,members:[item]) == .movies)
  print("PASS: series collection recency, episode favorites, partially watched shows; title/year ambiguity, original titles, localized TMDB catalog/episode, Chinese episode parsing, persisted tracks, local details, grouping and backward decoding")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-catalog-') as tmp:
    folder=Path(tmp); (folder/'Check.swift').write_text(source)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path','/tmp/lucent-swift-module-cache',str(folder/'Check.swift'),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check')],check=True)
