#!/usr/bin/env python3
"""Offline checks of production scope models and provider directory pagination.
Does not launch Lucent, use credentials, or contact a real storage service.
"""
import pathlib, subprocess, tempfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
models = (ROOT / 'Sources/LucentApp/AggregateLibraryModels.swift').read_text() + '\n' + (ROOT / 'Sources/LucentApp/LibraryWorkCoordinators.swift').read_text()
chinese = (ROOT / 'Sources/LucentApp/ChineseCloudClient.swift').read_text()
cloud = (ROOT / 'Sources/LucentApp/CloudDriveClient.swift').read_text()
# Route every request in the copied production client into an ephemeral offline fixture session.
cloud = cloud.replace('URLSession.shared', 'FixtureSession.shared')
chinese = chinese.replace('URLSession.shared', 'FixtureSession.shared')
store = (ROOT / 'Sources/LucentApp/LibraryStore.swift').read_text()
def method(name):
    start = store.index('    func ' + name + '(')
    brace = store.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        if store[end] == '{': depth += 1
        elif store[end] == '}': depth -= 1
        end += 1
    return store[start:end]
imports = """
struct ImportSnapshot: Codable { let scopes: [LibraryFileSource] }
final class ImportDatabase {
 var fail = false
 func saveAsync(_ snapshot: ImportSnapshot) async throws { if fail { throw LibraryScopeError.unavailable } }
}
final class ImportStore {
 var libraryStorages: [LibraryStorage] = []
 var fileSources: [LibraryFileSource] = []
 var database: ImportDatabase? = ImportDatabase()
 let fileURL = URL(fileURLWithPath: "/tmp/lucent-fixture-unused.json")
 var scanned: [UUID] = []
 func snapshot() -> ImportSnapshot { .init(scopes: fileSources) }
 func scanFileScope(_ id: UUID) { scanned.append(id) }
""" + method('scopeOverlap') + '\n' + method('importDirectories') + "\n}\n"
stubs = r'''
import Foundation
struct CloudSource { let provider: CloudProvider }
enum CloudProvider { case dropbox, googleDrive, pan115, pan123, baiduPan, guangyaPan }
enum SMBScanner { struct RangeResult {} }
enum HTTPRangeReader {
 static func read(request: URLRequest, offset: UInt64, length: Int) throws -> SMBScanner.RangeResult { fatalError() }
}
enum GuangyaClient {
 struct Entry { let id: String; let name: String }
 static func scan(token: String) async throws -> [Entry] { [] }
 static func contents(token: String, directoryID: String) async throws -> [StorageDirectory] { [] }
 static func downloadRequest(token: String, identifier: String) async throws -> URLRequest { fatalError() }
}
enum FixtureSession {
 static let shared: URLSession = {
  let config = URLSessionConfiguration.ephemeral
  config.protocolClasses = [Fixture.self]; config.urlCache = nil
  return URLSession(configuration: config)
 }()
}
final class Fixture: URLProtocol {
 static var calls: [URLRequest] = []
 override class func canInit(with request: URLRequest) -> Bool { true }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
  Self.calls.append(request)
  let url = request.url!
  let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems ?? []
  func q(_ name: String) -> String? { query.first { $0.name == name }?.value }
  var json: [String: Any]
  switch url.host! {
  case "proapi.115.com":
   precondition(q("cid") == "folder-115")
   if q("offset") == "0" { json = ["state":true, "count":2, "data":[["fn":"子目录", "fc":"0", "fid":"directory-id"]]] }
   else { precondition(q("offset") == "1"); json = ["state":true,"count":2,"data":[["fn":"电影.mkv","fc":"1","pc":"download-pickcode","fid":"file-id"]]] }
  case "open-api.123pan.com":
   precondition(q("parentFileId") == "folder-123")
   if q("lastFileId") == "0" { json = ["code":0,"data":["lastFileId":42,"fileList":[["fileId":42,"filename":"子目录","type":1,"trashed":0]]]] }
   else { precondition(q("lastFileId") == "42"); json = ["code":0,"data":["lastFileId":-1,"fileList":[["fileId":43,"filename":"电影.mp4","type":0,"trashed":0],["fileId":44,"filename":"已删除.mp4","type":0,"trashed":1]]]] }
  case "www.googleapis.com":
   precondition(q("q")!.contains("'folder-google' in parents"))
   json = ["files":[["id":"g-dir","name":"子目录","mimeType":"application/vnd.google-apps.folder"],["id":"g-file","name":"电影.mkv","mimeType":"video/x-matroska"],["id":"doc","name":"readme.txt","mimeType":"text/plain"]]]
  case "api.dropboxapi.com":
   var bodyData = request.httpBody ?? Data()
   if bodyData.isEmpty, let stream = request.httpBodyStream {
    stream.open(); defer { stream.close() }
    var buffer = [UInt8](repeating: 0, count: 1024)
    while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bodyData.append(buffer, count: count) }
   }
   let body = try! JSONSerialization.jsonObject(with: bodyData) as! [String:Any]
   precondition(body["path"] as? String == "id:folder-dropbox" && body["recursive"] as? Bool == false)
   json = ["entries":[[".tag":"folder","id":"id:child","name":"子目录"],[".tag":"file","id":"id:movie","name":"电影.mkv"]], "cursor":"done", "has_more":false]
  default: fatalError("Unexpected request")
  }
  client!.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
  client!.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: json))
  client!.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct Check {
 static func main() async throws {
  let discovered = try await LibraryScanCoordinator.discover(root: .root, read: { directory in
   if directory.identifier.isEmpty {
    return [.init(identifier: "child", name: "child", path: "child", isDirectory: true), .init(identifier: "child", name: "child", path: "child", isDirectory: true), .init(identifier: "a.mkv", name: "a.mkv", path: "a.mkv", isDirectory: false)]
   }
   return [.root, .init(identifier: "b.mkv", name: "b.mkv", path: "child/b.mkv", isDirectory: false)]
  }, progress: { _ in })
  precondition(discovered.count == 2)

  precondition(LibraryScopePath.contains("", "电影/2026"))
  precondition(LibraryScopePath.contains("电影", "电影/2026"))
  precondition(!LibraryScopePath.contains("电影", "电影合集"))
  precondition(!LibraryScopePath.overlaps("TV/A", "TV/B"))
  precondition(LibraryScopePath.overlaps("/TV/A/", "TV/A/S01"))
  var scope = LibraryFileSource(storageID: UUID(), name: "电影", directoryID: "native-id", path: "电影")
  scope.itemIDs = [UUID(), UUID()]; scope.enabled = false; scope.needsConfirmation = true
  let restored = try JSONDecoder().decode(LibraryFileSource.self, from: JSONEncoder().encode(scope))
  precondition(restored == scope)
  let importStore = ImportStore()
  let storageID = UUID()
  importStore.libraryStorages = [.init(id: storageID, name: "NAS", subtitle: "SMB", kind: .smb)]
  let first = StorageDirectory(identifier: "movies", name: "电影", path: "电影", isDirectory: true)
  let second = StorageDirectory(identifier: "tv", name: "剧集", path: "剧集", isDirectory: true)
  try await importStore.importDirectories(storageID: storageID, directories: [(first, "家庭影院"), (second, "我的剧集")], scanImmediately: true)
  precondition(importStore.fileSources.count == 2 && importStore.scanned.count == 2)
  let before = importStore.fileSources
  do {
   try await importStore.importDirectories(storageID: storageID, directories: [(.root, "整盘")], scanImmediately: true)
   fatalError("Parent overlap was accepted")
  } catch LibraryScopeError.overlap { }
  precondition(importStore.fileSources == before)
  let third = StorageDirectory(identifier: "docs", name: "纪录片", path: "纪录片", isDirectory: true)
  importStore.database!.fail = true
  do {
   try await importStore.importDirectories(storageID: storageID, directories: [(third, "纪录片")], scanImmediately: false)
   fatalError("Failed transaction was accepted")
  } catch LibraryScopeError.unavailable { }
  precondition(importStore.fileSources == before && importStore.scanned.count == 2)
  URLProtocol.registerClass(Fixture.self)
  let one = try await ChineseCloudClient.contents(provider: .pan115, token: "fixture", directoryID: "folder-115")
  precondition(one.count == 2 && one[0].identifier == "directory-id" && one[0].isDirectory && one[1].identifier == "download-pickcode")
  let two = try await ChineseCloudClient.contents(provider: .pan123, token: "fixture", directoryID: "folder-123")
  precondition(two.count == 2 && two[0].isDirectory && two[1].identifier == "43")
  let three = try await CloudDriveClient.contents(source: .init(provider: .googleDrive), token: "fixture", directoryID: "folder-google")
  precondition(three.count == 2 && three[0].isDirectory && three[1].identifier == "g-file")
  let four = try await CloudDriveClient.contents(source: .init(provider: .dropbox), token: "fixture", directoryID: "id:folder-dropbox")
  precondition(four.count == 2 && four[0].isDirectory && four[1].identifier == "id:movie")
  precondition(Fixture.calls.count == 6)
  print("PASS: scope boundaries, atomic import/rollback, source persistence, 115/123 pagination, trash filtering, Google/Dropbox native folder IDs")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-aggregate-') as tmp:
    folder = pathlib.Path(tmp)
    source = folder / 'Check.swift'
    source.write_text(models + '\n' + chinese + '\n' + cloud + '\n' + imports + '\n' + stubs)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', '/tmp/lucent-swift-module-cache', str(source), '-o', str(folder / 'check')], check=True)
    subprocess.run([str(folder / 'check')], check=True)
