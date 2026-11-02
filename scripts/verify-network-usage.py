#!/usr/bin/env python3
"""Offline contracts for cellular consent, local exemptions and transfer/sync restrictions."""
from pathlib import Path
import subprocess, tempfile
root=Path(__file__).resolve().parents[1]
production=(root/'Sources/LucentApp/NetworkUsagePolicy.swift').read_text()
source='''import Foundation
struct MediaItem {
 enum Location {
  case bookmark, folderFile, remote(URL), server, cloud
 }
 var location: Location
}
'''+production+'''
@main struct Checks {
 static func main() {
  let routes: [NetworkUsagePolicy.Route] = [.unknown,.offline,.wifi,.cellular,.wired]
  for route in routes {
   for allowed in [false,true] {
    precondition(NetworkUsagePolicy.syncPermitted(on:route,allowed:allowed) ==
     (route == .wifi || route == .wired || (route == .cellular && allowed)))
   }
   precondition(!NetworkUsagePolicy.playbackNeedsConfirmation(on:route,remote:false,approved:false))
   precondition(!NetworkUsagePolicy.playbackNeedsConfirmation(on:route,remote:true,approved:true))
  }
  precondition(NetworkUsagePolicy.playbackNeedsConfirmation(on:.cellular,remote:true,approved:false))
  precondition(!NetworkUsagePolicy.playbackNeedsConfirmation(on:.wifi,remote:true,approved:false))
  for source in [MediaItem.Location.bookmark,.folderFile,.remote(URL(fileURLWithPath:"/tmp/movie.mp4"))] {
   precondition(!MediaItem(location:source).requiresRemotePlayback(hasDownload:false))
  }
  for source in [MediaItem.Location.server,.cloud,.remote(URL(string:"https://fixture.invalid/movie.mp4")!)] {
   precondition(MediaItem(location:source).requiresRemotePlayback(hasDownload:false))
   precondition(!MediaItem(location:source).requiresRemotePlayback(hasDownload:true))
  }
  print("PASS: route/permission matrix, per-session cellular consent, offline/unknown handling, local file and downloaded playback exemptions")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='lucent-network-') as temp:
 p=Path(temp);(p/'checks.swift').write_text(source)
 subprocess.run(['xcrun','swiftc','-swift-version','6','-parse-as-library','-module-cache-path',str(p/'modules'),str(p/'checks.swift'),'-o',str(p/'checks')],check=True)
 subprocess.run([str(p/'checks')],check=True)
# Boundary checks make sure policy decisions reach actual transfer and playback owners.
checks={
 'HTTPDownloader.swift':['configuration.allowsCellularAccess = NetworkUsagePolicy.allowsDownloads','downloadTask(withResumeData: data)'],
 'SMBDownloader.swift':['try NetworkUsagePolicy.shared.requireDownloadAllowed()'],
 'CloudPlaybackSync.swift':['configuration.allowsCellularAccess = NetworkUsagePolicy.allowsSync','configuredWith(configuration: configuration)'],
 'PlaybackView.swift':['await startWithNetworkConsent()','session.suspendForCellularConfirmation()','session.resumeAfterCellularConfirmation(','private let forceRemotePlayback: Bool'],
 'TraktClient.swift':['request.allowsCellularAccess = NetworkUsagePolicy.allowsSync'],
}
for file,needles in checks.items():
 text=(root/'Sources/LucentApp'/file).read_text()
 for needle in needles: assert needle in text,(file,needle)
print('PASS: HTTP/resumed download, SMB chunks, CloudKit, Trakt and player lifecycle enforce the policy')
