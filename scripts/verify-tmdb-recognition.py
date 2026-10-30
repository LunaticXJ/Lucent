#!/usr/bin/env python3
"""Offline behavioral contracts for the Swift TMDB recognizer; no app/media/network.
Uses production code and injected typed providers. Rule mapping is documented alongside design.
"""
from pathlib import Path
import subprocess, tempfile, ast, re, typing, enum, json, sys
root = Path(__file__).resolve().parents[1]
base = (root/'scripts/verify-local-catalog.py').read_text()
context = {'__file__': str(root/'scripts/verify-local-catalog.py')}
exec(base.split("source += r'''")[0], context)
source = context['source'] + r'''
enum FixtureSession {
 static let shared: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [WireFixture.self]; config.urlCache = nil
  return URLSession(configuration:config)
 }()
}
final class WireFixture: URLProtocol {
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func stopLoading() {}
 override func startLoading() {
  let url = request.url!, params = URLComponents(url:url,resolvingAgainstBaseURL:false)!.queryItems ?? []
  func q(_ key: String) -> String? { params.first { $0.name == key }?.value }
  precondition(q("language") == TMDBService.deviceLanguage)
  if q("api_key") != nil { precondition(q("api_key") == String(repeating:"a",count:32) && request.value(forHTTPHeaderField:"Authorization") == nil) }
  else { precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture") }
  var status = 200
  let json: [String:Any]
  switch url.path {
  case "/3/search/tv":
   precondition(q("first_air_date_year") == "2024" && q("query") == "Wire" && q("include_adult") == "false")
   json = ["results":[["id":21,"name":"Wire","first_air_date":"2024-01-01"]]]
  case "/3/tv/21", "/3/movie/21":
   precondition(q("append_to_response") == "alternative_titles,translations")
   json = ["id":21,"name":"Wire","alternative_titles":["results":[["title":"别名"]]],"translations":["translations":[["data":["name":"译名"]]]],"seasons":[["season_number":2,"air_date":"2024-01-01"]]]
  case "/3/movie/404": status = 404; json = [:]
  case "/3/movie/401": status = 401; json = [:]
  case "/3/tv/episode_group/abc":
   json = ["groups":[["order":1,"episodes":[["order":0,"season_number":3,"episode_number":7,"air_date":"2024-01-01"]]]]]
  case "/3/find/tt1234567":
   json = ["movie_results":[["id":22,"title":"Movie"]],"tv_results":[["id":23,"name":"Series"]]]
  default: preconditionFailure("Unexpected HTTP request \(url.path)")
  }
  client!.urlProtocol(self,didReceive:HTTPURLResponse(url:url,statusCode:status,httpVersion:nil,headerFields:nil)!,cacheStoragePolicy:.notAllowed)
  client!.urlProtocol(self,didLoad:try! JSONSerialization.data(withJSONObject:json)); client!.urlProtocolDidFinishLoading(self)
 }
}
func candidate(_ id: Int, _ name: String, _ year: Int, tv: Bool = false) -> TMDBSearchResult {
 let data: [String:Any] = ["id":id, tv ? "name" : "title":name,
  tv ? "first_air_date" : "release_date":"\(year)-01-01", "media_type":tv ? "tv" : "movie"]
 return try! JSONDecoder().decode(TMDBSearchResult.self,from:JSONSerialization.data(withJSONObject:data))
}
func detail(_ id: Int, _ title: String, year: Int = 2000, aliases: [String] = [], seasons: [Int:Int] = [:]) -> CatalogCandidateDetails {
 let data: [String:Any] = ["id":id,"title":title,"release_date":"\(year)-01-01",
  "alternative_titles":["titles":aliases.map { ["title":$0] }],
  "seasons":seasons.map { ["season_number":$0.key,"air_date":"\($0.value)-01-01"] as [String:Any] }]
 return try! JSONDecoder().decode(CatalogCandidateDetails.self,from:JSONSerialization.data(withJSONObject:data))
}
actor Calls {
 var values: [String] = []
 func add(_ value: String) { values.append(value) }
 func all() -> [String] { values }
}
func recognizer(_ search: @escaping TMDBCatalogRecognizer.Search,
 details: @escaping TMDBCatalogRecognizer.Details = { _,_ in nil },
 external: @escaping TMDBCatalogRecognizer.External = { _ in [] },
 group: @escaping TMDBCatalogRecognizer.EpisodeGroup = { _ in .init(groups:[]) }) -> TMDBCatalogRecognizer {
 TMDBCatalogRecognizer(search:search,details:details,external:external,episodeGroup:group)
}
@main struct Checks {
 static func main() async throws {
  // 1. Exact year, next year, previous year -- in precisely that order.
  let years = Calls()
  let byYear = recognizer { title,kind,year in
   await years.add("\(kind.rawValue):\(year ?? 0)")
   return year == 2018 ? [candidate(18,title,2018)] : []
  }
  let byYearResult = try await byYear.recognize(.init(names:["Film"],year:2019,kind:.movie))
  precondition(byYearResult?.id == 18)
  let yearCalls = await years.all(); precondition(yearCalls == ["movie:2019","movie:2020","movie:2018"])
  // 2. Most recent title wins, independently of provider popularity order.
  let recent = recognizer { title,_,_ in [candidate(1,title,1984),candidate(2,title,2021)] }
  let recentResult = try await recent.recognize(.init(names:["Dune"],kind:.movie))
  precondition(recentResult?.id == 2)
  // 3. Title pass precedes aliases, even when a newer alias candidate is first.
  let noAlias = Calls()
  let titles = recognizer({ _,_,_ in [candidate(3,"Other",2026),candidate(4,"Target",2020)] },details:{ id,_ in
   await noAlias.add("detail"); return detail(id,"Other",aliases:["Target"])
  })
  let titlesResult = try await titles.recognize(.init(names:["Target"],kind:.movie))
  precondition(titlesResult?.id == 4)
  let aliasCalls = await noAlias.all(); precondition(aliasCalls.isEmpty)
  // 4. Translated/alternative title matching and Chinese/English search ordering.
  let aliases = recognizer({ _,_,_ in [candidate(5,"Original",2020)] },details:{ id,_ in detail(id,"Original",aliases:["目标"]) })
  let aliasesResult = try await aliases.recognize(.init(names:["目标"],kind:.movie))
  precondition(aliasesResult?.id == 5)
  let names = CatalogRecognitionInput.searchNames("我們的歌 Our Song")
  precondition(names == ["我們的歌","我们的歌","Our Song"], "\(names)")
  precondition(TMDBCatalogRecognizer.nameKey("A: B—C！") == "ABC")
  // 5. Current-season year is distinct from the series premiere year.
  let seasons = recognizer({ title,kind,_ in [candidate(6,title,2016,tv:kind == .tv)] },details:{ id,_ in detail(id,"Show",seasons:[2:2024]) })
  let seasonsResult = try await seasons.recognize(.init(names:["Show"],year:2024,kind:.tv,season:2))
  precondition(seasonsResult?.id == 6 && seasonsResult?.reason == "剧集/当前季年份匹配")
  // 6. TV exhausts year search then retries without year; never crosses to movies.
  let tvCalls = Calls()
  let television = recognizer { title,kind,year in
   await tvCalls.add("\(kind.rawValue):\(year ?? 0)")
   return year == nil ? [candidate(7,title,1990,tv:true)] : []
  }
  let tvResult = try await television.recognize(.init(names:["Show"],year:2024,kind:.tv))
  precondition(tvResult?.id == 7)
  let tvSequence = await tvCalls.all(); precondition(tvSequence == ["tv:2024","tv:2025","tv:2023","tv:0"])
  // 7. Unknown/no-year uses multi; movies precede television regardless of date.
  let multi = recognizer { title,kind,_ in
   precondition(kind == .unknown)
   return [candidate(8,title,2026,tv:true),candidate(9,title,1980)]
  }
  let multiResult = try await multi.recognize(.init(names:["Shared"]))
  precondition(multiResult?.id == 9 && multiResult?.kind == .movie)
  // 8. Movie miss -> television -> multi fallback.
  let fallbackCalls = Calls()
  let fallback = recognizer { title,kind,_ in
   await fallbackCalls.add(kind.rawValue)
   return kind == .tv ? [candidate(10,title,2024,tv:true)] : []
  }
  let fallbackResult = try await fallback.recognize(.init(names:["Show"],year:2024,kind:.movie))
  precondition(fallbackResult?.kind == .tv)
  let fallbackSequence = await fallbackCalls.all(); precondition(fallbackSequence == ["movie","movie","movie","tv"])
  // 9. Explicit ID probes both namespaces, using title/year to disambiguate.
  let ids = recognizer({ _,_,_ in preconditionFailure("No title search for explicit ID") },details:{ id,kind in
   detail(id,kind == .tv ? "Wanted" : "Unrelated",year:2024)
  })
  let idResult = try await ids.recognize(.init(names:["Wanted"],year:2024,tmdbID:11))
  precondition(idResult?.kind == .tv)
  let ambiguous = recognizer({ _,_,_ in [] },details:{ id,_ in detail(id,"Same") })
  let ambiguousResult = try await ambiguous.recognize(.init(names:["Same"],tmdbID:11))
  precondition(ambiguousResult == nil)
  // 10. IMDb lookup and explicit episode-group mapping.
  let external = recognizer({ _,_,_ in [] },external:{ _ in [candidate(12,"Found",2020)] })
  let externalResult = try await external.recognize(.init(names:[],imdbID:"tt1234567"))
  precondition(externalResult?.id == 12)
  let grouping = recognizer({ _,_,_ in [] },group:{ _ in
   .init(groups:[.init(order:1,episodes:[.init(order:0,season_number:3,episode_number:7,air_date:"2024-01-01")])])
  })
  let coordinates = try await grouping.coordinates(group:"abc",season:1,episode:1)
  precondition(coordinates.season == 3 && coordinates.episode == 7)
  // 11. Same-show 80-file positive and negative caches; no repetitive API lookup.
  let cachedCalls = Calls()
  let cached = recognizer { title,_,_ in await cachedCalls.add(title); return [candidate(13,title,2019,tv:true)] }
  for _ in 0..<80 { _ = try await cached.recognize(.init(names:["我们的歌"],year:2019,kind:.tv,season:1)) }
  let cachedSequence = await cachedCalls.all(); precondition(cachedSequence.count == 1)
  let negativeCalls = Calls()
  let negative = recognizer { title,_,_ in await negativeCalls.add(title); return [] }
  for _ in 0..<80 { _ = try await negative.recognize(.init(names:["Missing"],kind:.tv)) }
  let negativeSequence = await negativeCalls.all(); precondition(negativeSequence.count == 1)
  // 12. Transport errors and cancellation are not cached as negative matches.
  let errors = Calls()
  let failing = recognizer { _,_,_ in await errors.add("failed"); throw URLError(.notConnectedToInternet) }
  for _ in 0..<2 {
   do { _ = try await failing.recognize(.init(names:["Error"])); preconditionFailure() }
   catch { precondition((error as? URLError)?.code == .notConnectedToInternet) }
  }
  let errorSequence = await errors.all(); precondition(errorSequence.count == 2)
  // 13. Existing library entries read TMDB tags from folders, retaining exact IDs.
  let file = MediaItem(title:"Show",location:.webDAVFile(sourceID:UUID(),relativePath:"Show (2019) [tmdb-42]/Season 02/S02E01.mkv"),identity:.episode(series:"Show (2019) [tmdb-42]",season:2,number:1,name:nil))
  let input = CatalogRecognitionInput(item:file)
  precondition(input.names == ["Show"] && input.year == 2019 && input.tmdbID == 42 && input.season == 2)
  precondition(MediaNameParser.parse(relativePath:"Show (2019)/S02/01.mkv").identity == .episode(series:"Show 2019",season:2,number:1,name:nil))
  precondition(MediaNameParser.parse(relativePath:"我们的歌 2019/第二季/第十二集.mkv").identity == .episode(series:"我们的歌 2019",season:2,number:12,name:nil))
  precondition(MediaNameParser.parse(filename:"Show S00E01.mkv").identity == .episode(series:"Show",season:0,number:1,name:nil))
  precondition(MediaNameParser.parse(filename:"1984.mkv").identity == .movie(year:nil))
  // Production HTTP adapters: query/auth, aliases/translations, missing IDs, auth failures.
  let wire = try await TMDBService.recognitionSearch(title:"Wire",kind:.tv,year:2024,token:"fixture")
  precondition(wire.first?.id == 21)
  let wireDetail = try await TMDBService.recognitionDetails(id:21,kind:.tv,token:"fixture")
  precondition(wireDetail?.allNames == ["Wire","别名","译名"] && wireDetail?.seasons?.first?.season_number == 2)
  let keyDetail = try await TMDBService.recognitionDetails(id:21,kind:.movie,token:String(repeating:"a",count:32))
  precondition(keyDetail?.id == 21)
  let missingID = try await TMDBService.recognitionDetails(id:404,kind:.movie,token:"fixture")
  precondition(missingID == nil)
  do { _ = try await TMDBService.recognitionDetails(id:401,kind:.movie,token:"fixture"); preconditionFailure() }
  catch { precondition(error.localizedDescription.contains("认证失败")) }
  let wireGroup = try await TMDBService.recognitionEpisodeGroup(id:"abc",token:"fixture")
  precondition(wireGroup.groups.first?.episodes.first?.episode_number == 7)
  let wireExternal = try await TMDBService.recognitionExternal(id:"tt1234567",token:"fixture")
  precondition(wireExternal.map(\.recognitionKind) == [.movie,.tv])
  let proof = ["year":byYearResult!.id,"recent":recentResult!.id,"titlePass":titlesResult!.id,"alias":aliasesResult!.id,"season":seasonsResult!.id,"multi":multiResult!.id]
  print(String(data:try JSONSerialization.data(withJSONObject:proof,options:.sortedKeys),encoding:.utf8)!)
  print("PASS: TMDB recognition -- 13 behavior groups: year order, newest candidate, title/alias passes, multilingual names, season years, type fallback, explicit/external IDs, episode groups, 80-file caches, failures and existing file tags")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-recognition-') as tmp:
    folder=Path(tmp); (folder/'Check.swift').write_text(source)
    subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path','/tmp/lucent-swift-module-cache',str(folder/'Check.swift'),'-o',str(folder/'check')],check=True)
    result = subprocess.run([str(folder/'check')],check=True,capture_output=True,text=True)
    print(result.stdout.strip())
    swift_results = json.loads(result.stdout.splitlines()[0])
    # Optional differential check: execute selected methods directly from an external
    # upstream checkout. No upstream source is copied into Lucent or this test.
    if len(sys.argv) > 1:
        upstream = Path(sys.argv[1])
        class Kind(enum.Enum):
            MOVIE = "movie"
            TV = "tv"
        class Logger:
            def __getattr__(self, name): return lambda *a, **k: None
        env = dict(re=re, traceback=__import__('traceback'), Optional=typing.Optional,
                   List=typing.List, Union=typing.Union, MediaType=Kind,
                   logger=Logger(), TMDbException=RuntimeError)
        strings = ast.parse((upstream/'string.py').read_text())
        cls = next(n for n in strings.body if isinstance(n,ast.ClassDef) and n.name == 'StringUtils')
        cls.body = [n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name == 'clear']
        exec(compile(ast.fix_missing_locations(ast.Module(body=[cls],type_ignores=[])),str(upstream/'string.py'),'exec'),env)
        tree = ast.parse((upstream/'tmdbapi.py').read_text())
        cls = next(n for n in tree.body if isinstance(n,ast.ClassDef) and n.name == 'TmdbApi')
        keep = {'__compare_names','_validate_match_params','_generate_year_range','_log_match_debug',
                '_set_media_type','_sort_multi_results','_convert_media_type','_match_multi_title',
                '_match_multi_names','match','__search_movie_by_name','__search_tv_by_name',
                '__search_tv_by_season','__get_tv_seasons','match_multi'}
        cls.body = [n for n in cls.body if isinstance(n,ast.FunctionDef) and n.name in keep]
        exec(compile(ast.fix_missing_locations(ast.Module(body=[cls],type_ignores=[])),str(upstream/'tmdbapi.py'),'exec'),env)
        def candidate(id,name,year,tv=False):
            return {'id':id,'name' if tv else 'title':name,
                    'first_air_date' if tv else 'release_date':f'{year}-01-01',
                    'media_type':'tv' if tv else 'movie'}
        def matcher(search,details=None):
            obj=env['TmdbApi']()
            class Search:
                total_results=10
                def movies(self,term,year=None): return search(term,Kind.MOVIE,year)
                def tv_shows(self,term,release_year=None): return search(term,Kind.TV,release_year)
                def multi(self,term): return search(term,None,None)
            obj.search=Search()
            obj.get_info=lambda mtype,tmdbid: details(tmdbid) if details else {}
            return obj
        answers={}
        answers['year']=matcher(lambda name,kind,year:[candidate(18,name,2018)] if year=='2018' else []).match('Film',Kind.MOVIE,year='2019')['id']
        answers['recent']=matcher(lambda name,*_:[candidate(1,name,1984),candidate(2,name,2021)]).match('Dune',Kind.MOVIE)['id']
        answers['titlePass']=matcher(lambda *_:[candidate(3,'Other',2026),candidate(4,'Target',2020)],lambda id:{'id':id,'names':['Target']}).match('Target',Kind.MOVIE)['id']
        answers['alias']=matcher(lambda *_:[candidate(5,'Original',2020)],lambda id:{'id':id,'names':['目标']}).match('目标',Kind.MOVIE)['id']
        answers['season']=matcher(lambda name,*_:[candidate(6,name,2016,True)],lambda id:{'id':id,'name':'Show','seasons':[{'season_number':2,'air_date':'2024-01-01'}]}).match('Show',Kind.TV,year='2024',season_year='2024',season_number=2)['id']
        answers['multi']=matcher(lambda name,*_:[candidate(8,name,2026,True),candidate(9,name,1980)]).match_multi('Shared')['id']
        assert answers == swift_results, (answers,swift_results)
        print('PASS: 6 differential scenarios produce the same IDs in the external MoviePilot implementation and Swift')
