#!/usr/bin/env python3
"""Check actual routing contracts without starting the app or reading media URLs."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/PlaybackDiagnostics.swift').read_text()
features = source[source.index('struct PlaybackMediaFeatures:'):source.index('struct PlaybackDiagnostics:')]
routing = source[source.index('enum PlaybackTransportPolicy:'):] if 'enum PlaybackTransportPolicy:' in source else source[source.index('enum PlaybackTransportPolicy {'):]
swift = 'import Foundation\nenum PlaybackEnginePreference { case automatic, system, mpv }\n' + features + routing
swift += '''
@main struct Checks {
 static func main() {
  let direct = URL(string:"https://server.invalid/Videos/142808/stream.mp4")!
  let proxy = URL(string:"http://127.0.0.1:12345/session/video.mp4")!
  var features = PlaybackMediaFeatures()
  features.container = "mp4"; features.videoCodec = "hevc"; features.videoCodecTag = "hev1"; features.audioCodec = "aac"
  func choose(_ preference: PlaybackEnginePreference, styled: Bool = false) -> PlaybackRouteDecision {
   .choose(preference:preference,url:direct,features:features,hasStyledSubtitle:styled,hasExternalAudio:false,serverDolbyVision:false)
  }
  let automatic = choose(.automatic)
  precondition(!automatic.useMPV && automatic.useAether)
  precondition(choose(.system).useAether)
  precondition(choose(.mpv).useMPV && !choose(.mpv).useAether)
  precondition(choose(.automatic,styled:true).useMPV)
  features.videoCodecTag = "hvc1"
  precondition(!choose(.automatic).useMPV && !choose(.automatic).useAether)
  precondition(PlaybackTransportPolicy.mpvURL(for:direct,embyFileProxy:proxy,isTranscoding:false) == proxy)
  precondition(PlaybackTransportPolicy.mpvURL(for:direct,embyFileProxy:proxy,isTranscoding:true) == direct)
  precondition(PlaybackTransportPolicy.mpvURL(for:direct,embyFileProxy:nil,isTranscoding:false) == direct)
  let hls = URL(string:"https://server.invalid/live/master.m3u8")!
  precondition(PlaybackTransportPolicy.mpvURL(for:hls,embyFileProxy:proxy,isTranscoding:false) == hls)
  let local = URL(fileURLWithPath:"/tmp/download.mp4")
  precondition(PlaybackTransportPolicy.mpvURL(for:local,embyFileProxy:proxy,isTranscoding:false) == local)
  precondition(PlaybackTransportPolicy.mpvURL(for:direct,embyFileProxy:direct,isTranscoding:false) == direct)
  print("PASS: hev1 native remux, hvc1 direct native, explicit MPV, styled subtitles, static-file proxy, local/HLS/transcode boundaries")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-route-checks-') as directory:
    directory = Path(directory)
    code = directory / 'checks.swift'
    code.write_text(swift)
    executable = directory / 'checks'
    subprocess.run(['swiftc', '-module-cache-path', str(directory/'modules'), '-parse-as-library', str(code), '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
