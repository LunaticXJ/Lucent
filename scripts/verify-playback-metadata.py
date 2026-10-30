#!/usr/bin/env python3
"""Offline checks of the production playback-to-library persistence method."""
from pathlib import Path
import tempfile,subprocess
root=Path(__file__).resolve().parents[1]
context={'__file__':str(root/'scripts/verify-local-catalog.py')}
exec((root/'scripts/verify-local-catalog.py').read_text().split("source += r'''")[0],context)
store=(root/'Sources/LucentApp/LibraryStore.swift').read_text()
a=store.index('    func recordPlaybackMedia(');b=store.index('\n    func updateProgress(',a)
source=context['source']+'\nenum FixtureSession { static let shared = URLSession.shared }\n'
source+='final class Store { var items: [MediaItem] = []; var saves=0; func save(){ saves += 1 }\n'+store[a:b]+'\n}\n'
source+=r'''
@main struct Checks {
 static func main() throws {
  let store=Store()
  let item=MediaItem(title:"Video",location:.remote(URL(string:"https://fixture.invalid/video.mp4")!))
  store.items=[item]
  let features=PlaybackMediaFeatures(container:"mp4",videoCodec:"hevc",videoCodecTag:"hev1",audioCodec:"aac",dynamicRange:"SDR",resolution:"3840×1640")
  let tracks=Data(#"[{"Type":"Audio","Index":1,"Codec":"aac"},{"Type":"Subtitle","Index":2,"Codec":"ass"}]"#.utf8)
  store.recordPlaybackMedia(id:item.id,features:features,duration:120.2,streams:tracks)
  precondition(store.saves == 1 && store.items[0].technicalInfo?.duration == 120)
  precondition(store.items[0].localPlaybackFeatures.videoCodecTag == "hev1")
  precondition(store.items[0].localPlaybackFeatures.styledSubtitleStreamIndices == [2])
  store.recordPlaybackMedia(id:item.id,features:features,duration:120.2,streams:tracks)
  precondition(store.saves == 1, "identical observations must not write repeatedly")
  store.recordPlaybackMedia(id:item.id,features:.unknown,duration:0,streams:nil)
  precondition(store.items[0].localPlaybackFeatures.videoCodecTag == "hev1")
  let restored=try JSONDecoder().decode(MediaItem.self,from:JSONEncoder().encode(store.items[0]))
  precondition(restored.localPlaybackFeatures.videoCodecTag == "hev1" && restored.technicalInfo?.streams.count == 3)
  let replacement=Data(#"[{"Type":"Audio","Index":5,"Codec":"aac"}]"#.utf8)
  store.recordPlaybackMedia(id:item.id,features:features,duration:120.2,streams:replacement)
  precondition(store.items[0].technicalInfo?.streams.filter { $0.type == "Audio" }.count == 1)
  let server=MediaItem(title:"Server",location:.embyItem(sourceID:UUID(),itemID:"1"))
  store.items.append(server)
  store.recordPlaybackMedia(id:server.id,features:features,duration:120,streams:tracks)
  precondition(store.items[1].technicalInfo == nil)
  print("PASS: playback metadata persistence, hev1 restart routing, track snapshots, no duplicate writes, roundtrip decoding and server isolation")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-playback-metadata-') as tmp:
 p=Path(tmp);(p/'Check.swift').write_text(source)
 subprocess.run(['swiftc','-swift-version','6','-parse-as-library','-module-cache-path','/tmp/lucent-swift-module-cache',str(p/'Check.swift'),'-o',str(p/'check')],check=True)
 subprocess.run([str(p/'check')],check=True)
