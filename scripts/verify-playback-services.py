#!/usr/bin/env python3
"""Exercise production subtitle transport, danmaku parsing/layout and cached-ID sync, offline."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = '''import Foundation
import CryptoKit
struct MediaItem: Sendable {
 enum Identity: Sendable { case episode(String, Int, Int, String) }
 struct Metadata: Sendable { let providerID: Int }
 var identity: Identity?; var metadata: Metadata?; var title: String
}
enum SubtitleParser { static let supportedExtensions: Set<String> = ["srt","vtt","ass","ssa","sup"] }
enum KeychainPasswordStore {
 static func playbackServiceSecret(_ key: String) throws -> String? { "fixture-only" }
}
struct JellyfinItem: Decodable, Sendable {
 let id: String
 enum CodingKeys: String, CodingKey { case id = "Id" }
}
'''
for name in ['OpenSubtitlesClient.swift','Danmaku.swift','ServerCatalogSync.swift']:
    source += (root/'Sources/LucentApp'/name).read_text() + '\n'
view = (root/'Sources/LucentApp/DanmakuView.swift').read_text()
source += view[view.index('struct DanmakuLayout:'):view.index('struct DanmakuOverlay:')]
source += r'''
final class Fixture: URLProtocol, @unchecked Sendable {
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func stopLoading() {}
 override func startLoading() {
  let url = request.url!, query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
  let q = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
  var code = 200
  let payload: String
  switch url.path {
  case "/api/v1/subtitles":
   precondition(request.value(forHTTPHeaderField:"Api-Key") == "fixture")
   precondition(request.value(forHTTPHeaderField:"Authorization") == "Bearer fixture-token")
   precondition(q["page"] == "2" && q["season_number"] == "2" && q["episode_number"] == "3")
   precondition(q["query"] == "雪国" && q["languages"] == "zh-cn,zh-tw")
   payload = #"{"total_pages":2,"data":[{"attributes":{"language":"zh-cn","release":null,"download_count":null,"hearing_impaired":null,"files":[{"file_id":1,"file_name":"a.srt"},{"file_id":2,"file_name":"b.srt"}]}}]}"#
  case "/api/v1/login": payload = #"{"token":"fixture-token","base_url":"vip-api.opensubtitles.com"}"#
  case "/api/v1/download":
   if request.value(forHTTPHeaderField:"Api-Key") == "quota" { code = 429; payload = "{}" }
   else { payload = #"{"link":"https://dl.opensubtitles.com/fixture.srt","file_name":"fixture.srt"}"# }
  case "/fixture.srt":
   precondition(request.value(forHTTPHeaderField:"Api-Key") == nil)
   precondition(request.value(forHTTPHeaderField:"Authorization") == nil)
   payload = "1\n00:00:00,000 --> 00:00:01,000\nHello\n"
  case "/Users/u/Items":
   precondition(request.cachePolicy == .reloadIgnoringLocalCacheData)
   precondition(request.value(forHTTPHeaderField:"X-Emby-Token") == "fixture-token")
   if q["Ids"] == "poison" { payload = #"{"Items":[{"Id":"foreign"}],"TotalRecordCount":1}"# }
   else if q["Ids"] == "empty" { payload = #"{"Items":[],"TotalRecordCount":0}"# }
   else if q["StartIndex"] == "0" { payload = #"{"Items":[{"Id":"a"}],"TotalRecordCount":2}"# }
   else { payload = #"{"Items":[{"Id":"b"}],"TotalRecordCount":2}"# }
  default: fatalError("unexpected fixture path")
  }
  client?.urlProtocol(self, didReceive: HTTPURLResponse(url:url,statusCode:code,httpVersion:nil,headerFields:nil)!, cacheStoragePolicy:.notAllowed)
  client?.urlProtocol(self,didLoad:Data(payload.utf8)); client?.urlProtocolDidFinishLoading(self)
 }
}
@main struct Checks {
 static func main() async throws {
  precondition(URLProtocol.registerClass(Fixture.self))
  let json = Data(#"{"comments":[{"p":"1.25,1,16777215,u","m":"你好"},{"p":"1.25,1,16777215,u","m":"你好"},{"p":"2,5,255,u","m":"顶部"},{"p":"3,4,65535,u","m":"底部"},{"p":"-1,1,1,u","m":"bad"},{"p":"1,7,1,u","m":"unsupported"}]}"#.utf8)
  let values = try DanmakuParser.parse(json)
  precondition(values.count == 3 && values[0].time == 1.25 && values[1].mode == .top && values[2].mode == .bottom)
  let xml = Data(#"<i><d p="4.5,1,25,16777215,0">你好 &amp; 世界</d><d p="5,5,25,255,0">顶</d></i>"#.utf8)
  let parsed = try DanmakuParser.parse(xml)
  precondition(parsed.count == 2 && parsed[0].text == "你好 & 世界" && parsed[1].mode == .top)
  do { _ = try DanmakuParser.parse(Data("<broken>".utf8)); fatalError("malformed accepted") } catch {}
  let dense = (0..<500).map { DanmakuComment(time: Double($0) * 0.02,text:"字幕\($0)",color:0xFFFFFF,mode:.scroll) }
  let layout = DanmakuLayout(comments:dense,width:800,height:400,fontSize:22,area:0.5,duration:8)
  precondition(layout.entries.count < dense.count && layout.entries.count > 0)
  precondition(layout.active(at:100).isEmpty)
  for time in stride(from:0.0,to:20.0,by:0.05) {
   let active = layout.active(at:time)
   for lane in 0..<layout.lanes {
    let line = active.filter { $0.lane == lane }
    for pair in zip(line,line.dropFirst()) {
     let left = 800 - (time - pair.0.comment.time) / 8 * (800 + pair.0.width)
     let right = 800 - (time - pair.1.comment.time) / 8 * (800 + pair.1.width)
     precondition(left + pair.0.width < right, "lane collision")
    }
   }
  }
  precondition(DandanplayClient.signature(appID:"a",secret:"b",timestamp:"1",path:"/api/v2/comment/1") == Data(SHA256.hash(data:Data("a1/api/v2/comment/1b".utf8))).base64EncodedString())
  let item = MediaItem(identity:.episode("雪国",2,3,""),metadata:nil,title:"Snow")
  let login = OpenSubtitlesClient.Login(token:"fixture-token",baseURL:"vip-api.opensubtitles.com")
  let matches = try await OpenSubtitlesClient.search(item:item,language:"zh-cn,zh-tw",apiKey:"fixture",query:"雪国",page:2,session:login)
  precondition(matches.count == 2 && matches[1].id == 2 && matches[0].release == "a.srt")
  let (sub,filename) = try await OpenSubtitlesClient.download(fileID:1,apiKey:"fixture",session:login)
  precondition(filename == "fixture.srt" && String(decoding:sub,as:UTF8.self).contains("Hello"))
  do { _ = try await OpenSubtitlesClient.download(fileID:1,apiKey:"quota"); fatalError("quota ignored") } catch {}
  let synced = try await ServerCatalogSync.cachedItems(base:"https://fixture.invalid",userID:"u",token:"fixture-token",ids:["a","deleted","b"])
  precondition(synced.map(\.id) == ["a","b"])
  let empty = try await ServerCatalogSync.cachedItems(base:"https://fixture.invalid",userID:"u",token:"fixture-token",ids:["empty"])
  precondition(empty.isEmpty)
  do { _ = try await ServerCatalogSync.cachedItems(base:"https://fixture.invalid",userID:"u",token:"fixture-token",ids:["poison"]); fatalError("foreign ID accepted") } catch {}
  print("PASS: subtitle multi-file results, query/episode/language/page/auth, quota errors and credential-free downloads; danmaku JSON/XML, dedupe, modes, density, seek window and lane collisions; server cached-ID paging, deletion/empty snapshots and foreign-ID rejection")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-services-') as directory:
    path = Path(directory)
    (path/'checks.swift').write_text(source)
    subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(path/'modules'),str(path/'checks.swift'),'-o',str(path/'checks')],check=True)
    subprocess.run([str(path/'checks')],check=True)
