#!/usr/bin/env python3
"""Offline production-client checks. Inject only URLProtocol and an isolated cache directory."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
production = (root/'Sources/LucentApp/Danmaku.swift').read_text()
production = production.replace('let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)', 'let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [Fixture.self]\n        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)')
production = production.replace('FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]', 'Fixture.cacheDirectory')
source = '''import Foundation
import CryptoKit
enum KeychainPasswordStore {
 static func playbackServiceSecret(_ key: String) throws -> String? { fatalError("Custom server read official credentials") }
}
''' + production
source += r'''
final class Fixture: URLProtocol, @unchecked Sendable {
 static let cacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("LucentDanmakuTest-" + UUID().uuidString)
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func stopLoading() {}
 override func startLoading() {
  let url = request.url!
  let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []).map { ($0.name, $0.value ?? "") })
  precondition(request.value(forHTTPHeaderField: "X-AppId") == nil)
  precondition(request.value(forHTTPHeaderField: "X-Signature") == nil)
  precondition(url.path.hasPrefix("/credential-prefix/api/v2/"))
  let body: String
  var code = 200
  if url.path.hasSuffix("/search/episodes") {
   precondition(query["anime"] != nil && query["v2"] == "true")
   precondition(query["tmdbId"] == nil) // custom services are searched by title, not an unsupported TMDB-only query
   if query["anime"] == "empty" { body = #"{"success":true,"animes":[]}"# }
   else if query["anime"] == "wrong" { body = "<html>management UI</html>" }
   else if query["anime"] == "denied" { code = 401; body = "{}" }
   else { body = #"{"success":true,"animes":[{"animeTitle":"Fixture","episodes":[{"episodeId":123,"episodeTitle":"E1"},{"episodeId":123,"episodeTitle":"duplicate"}]}]}"# }
  } else {
   precondition(url.path.hasSuffix("/comment/123"))
   precondition(query["format"] == "json" && query["withRelated"] == "true")
   body = url.host == "one.invalid" ? #"{"comments":[{"p":"1,1,16777215,user","m":"one"}]}"# : #"{"comments":[{"p":"1,1,16777215,user","m":"two"}]}"#
  }
  client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
  client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
 }
}
@main struct Verify {
 static func main() async throws {
  defer { try? FileManager.default.removeItem(at: Fixture.cacheDirectory) }
  let one = try DandanplayClient.Server.custom(id: "1", name: "One", address: "https://one.invalid/credential-prefix/")
  let two = try DandanplayClient.Server.custom(id: "2", name: "Two", address: "https://two.invalid/credential-prefix/api/v2/")
  precondition(one.baseURL.path == "/credential-prefix/api/v2")
  precondition(two.baseURL.path == "/credential-prefix/api/v2")
  let withQuery = try DandanplayClient.Server.custom(id: "q", name: "Q", address: "http://127.0.0.1:9321/secret%20path?token=fixture")
  let queryRequest = try DandanplayClient.makeRequest(path: "search/episodes", parameters: [.init(name: "anime", value: "雪国")], server: withQuery)
  precondition(queryRequest.url!.path == "/secret path/api/v2/search/episodes")
  let query = URLComponents(url: queryRequest.url!, resolvingAgainstBaseURL: false)!.queryItems!
  precondition(query.contains(.init(name: "token", value: "fixture")))
  precondition(query.contains(.init(name: "anime", value: "雪国")))
  for bad in ["", "example.com", "file:///tmp/danmaku", "ftp://server", "https://user:pass@host"] {
   do { _ = try DandanplayClient.Server.custom(id: "bad", name: "Bad", address: bad); fatalError("invalid URL accepted") } catch {}
  }
  let official = try DandanplayClient.makeRequest(path: "search/episodes", parameters: [], server: .official, appID: "fixture", secret: "secret", timestamp: "123")
  precondition(official.value(forHTTPHeaderField: "X-AppId") == "fixture")
  let redirect = DandanRedirectDelegate(origin: official.url!)
  var cross = official; cross.url = URL(string: "https://cdn.invalid/data")!
  precondition(redirect.redirectedRequest(cross)?.value(forHTTPHeaderField: "X-AppId") == nil)
  cross.url = URL(string: "http://cdn.invalid/data")!
  precondition(redirect.redirectedRequest(cross) == nil)
  let results = try await DandanplayClient.search("fixture", tmdbID: 1, server: one)
  precondition(results.count == 1 && results[0].server == one)
  let empty = try await DandanplayClient.search("empty", server: one)
  precondition(empty.isEmpty)
  for term in ["wrong", "denied"] {
   do { _ = try await DandanplayClient.search(term, server: one); fatalError("bad response accepted") } catch {}
  }
  let dataOne = try await DandanplayClient.comments(episodeID: 123, server: results[0].server)
  let dataTwo = try await DandanplayClient.comments(episodeID: 123, server: two)
  precondition(try DanmakuParser.parse(dataOne).first?.text == "one")
  precondition(try DanmakuParser.parse(dataTwo).first?.text == "two")
  precondition(DandanplayClient.commentsCacheURL(episodeID: 123, server: one) != DandanplayClient.commentsCacheURL(episodeID: 123, server: two))
  let custom = CustomDanmakuServer(name: "One", address: one.baseURL.absoluteString)
  let encoded = try JSONEncoder().encode([custom, CustomDanmakuServer(name: "Off", address: two.baseURL.absoluteString, enabled: false)])
  precondition(CustomDanmakuServers.decode(encoded).count == 2)
  precondition(CustomDanmakuServers.available(encoded).count == 1)
  print("PASS: base paths, auth prefixes/query, enabled configuration, official signing isolation, redirects, search/decode/errors, result source binding and cross-server comment caches")
 }
}
'''
# Throwing checks are evaluated outside precondition's non-throwing autoclosure.
source = source.replace('precondition(try DanmakuParser.parse(dataOne).first?.text == "one")', 'let parsedOne = try DanmakuParser.parse(dataOne); precondition(parsedOne.first?.text == "one")')
source = source.replace('precondition(try DanmakuParser.parse(dataTwo).first?.text == "two")', 'let parsedTwo = try DanmakuParser.parse(dataTwo); precondition(parsedTwo.first?.text == "two")')
with tempfile.TemporaryDirectory(prefix='lucent-custom-danmaku-') as directory:
 path = Path(directory); (path/'checks.swift').write_text(source)
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(path/'modules'),str(path/'checks.swift'),'-o',str(path/'verify')],check=True)
 subprocess.run([str(path/'verify')],check=True)
