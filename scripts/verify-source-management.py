#!/usr/bin/env python3
"""Check source URL/configuration contracts and DAV listings without UI or live credentials."""
from pathlib import Path
import subprocess
import tempfile

root=Path(__file__).resolve().parents[1]
view=(root/'Sources/LucentApp/LibraryView.swift').read_text()
model=(root/'Sources/LucentApp/MediaItem.swift').read_text()
source='import Foundation\n'
source+=view[view.index('private struct ServerAddressDraft {'):view.index('private struct ServerFormField')]
source+=model[model.index('struct SourceDirectoryEntry:'):model.index('enum MediaLocation:')]
source+=model[model.index('struct SMBSource:'):model.index('struct JellyfinSource:')]
source+=(root/'Sources/LucentApp/WebDAVClient.swift').read_text().replace('import Foundation','')
source+='''
enum SMBScanner { struct RangeResult { let data: Data; let totalSize: UInt64 } }
enum HTTPRangeReader {
 static func read(url: URL, headers: [String:String], offset: UInt64, length: Int) throws -> SMBScanner.RangeResult { fatalError("not used") }
}
final class FixtureProtocol: URLProtocol, @unchecked Sendable {
 override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "fixture.invalid" }
 override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
 override func startLoading() {
   precondition(request.httpMethod == "PROPFIND")
   precondition(request.value(forHTTPHeaderField: "Depth") == "1")
   let hrefs = ["/videos/", "/videos/电影/", "/videos/中文%20电影.mkv", "/videos/中文%20电影.mkv", "/videos/readme.txt", "/videos/电影/深层.mkv", "https://other.invalid/videos/foreign.mkv", "https://fixture.invalid:9999/videos/port.mkv", "/escape.mkv"]
   let rows = hrefs.map { href in "<d:response><d:href>\\(href)</d:href><d:propstat><d:prop><d:resourcetype>\\(href.hasSuffix("/") ? "<d:collection/>" : "")</d:resourcetype></d:prop></d:propstat></d:response>" }.joined()
   let xml = "<d:multistatus xmlns:d=\\"DAV:\\">\\(rows)</d:multistatus>"
   client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 207, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
   client?.urlProtocol(self, didLoad: Data(xml.utf8)); client?.urlProtocolDidFinishLoading(self)
 }
 override func stopLoading() {}
}
@main struct SourceChecks {
 static func main() async throws {
   var draft = ServerAddressDraft()
   draft.host = "https://nas.example:8920/emby"
   draft.absorbPastedAddress()
   precondition(draft.host == "nas.example" && draft.port == "8920" && draft.path == "/emby")
   precondition(draft.address == "https://nas.example:8920/emby")
   draft.host = "https://nas.example/"
   draft.absorbPastedAddress()
   precondition(draft.port.isEmpty && draft.path.isEmpty && draft.address == "https://nas.example/")
   draft.port = "65536"; precondition(draft.address == nil)
   draft.port = "0"; precondition(draft.address == nil)
   draft.port = ""; draft.host = "bad host"; precondition(draft.address == nil)
   draft.host = "https://name:secret@nas.example/"; draft.absorbPastedAddress(); precondition(draft.address == nil)
   let legacy = Data("{\\"id\\":\\"00000000-0000-0000-0000-000000000001\\",\\"host\\":\\"nas\\",\\"share\\":\\"movies\\",\\"username\\":\\"guest\\"}".utf8)
   var smb = try JSONDecoder().decode(SMBSource.self, from: legacy)
   precondition(smb.displayName == nil && smb.name == "movies · nas")
   precondition(smb.domain == nil && smb.syncAllowed == nil)
   smb.domain = "WORKGROUP"; smb.syncAllowed = false
   smb.displayName = "家庭影院"
   precondition(try JSONDecoder().decode(SMBSource.self, from: JSONEncoder().encode(smb)).name == "家庭影院")
   precondition(URLProtocol.registerClass(FixtureProtocol.self))
   let web = WebDAVSource(baseAddress: "https://fixture.invalid/videos/", username: "")
   let files = try await WebDAVClient.contents(source: web, password: nil, path: "")
   precondition(Set(files.map(\\.path)) == Set(["电影", "中文 电影.mkv"]))
   do { _ = try await WebDAVClient.contents(source: web, password: nil, path: "../escape"); fatalError("must reject traversal") } catch {}
   print("PASS: URL parsing, optional ports, invalid inputs, old configuration decoding, name persistence, WebDAV immediate children/Chinese names/duplicates/origin/port/path boundaries")
 }
}
'''
# Throwing precondition autoclosure isn't allowed; decode separately.
source=source.replace('precondition(try JSONDecoder().decode(SMBSource.self, from: JSONEncoder().encode(smb)).name == "家庭影院")','let restored = try JSONDecoder().decode(SMBSource.self, from: JSONEncoder().encode(smb)); precondition(restored.name == "家庭影院" && restored.domain == "WORKGROUP" && restored.syncAllowed == false)')
with tempfile.TemporaryDirectory(prefix="lucent-source-checks-") as directory:
    directory = Path(directory)
    input_file = directory / "checks.swift"
    executable = directory / "checks"
    input_file.write_text(source)
    subprocess.run(["swiftc", "-module-cache-path", str(directory / "modules"),
                    "-parse-as-library", str(input_file), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
