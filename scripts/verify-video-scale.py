#!/usr/bin/env python3
"""Check production gravity mapping and MPV scaling transitions without launching video."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
surface = (root/'Sources/LucentApp/PlayerSurface.swift').read_text()
modes = surface[surface.index('enum VideoScaleMode:'):surface.index('\n///')]
engine = (root/'Sources/LucentApp/MPVPlaybackEngine.swift').read_text()
method = engine[engine.index('    func setVideoScaleMode('):engine.index('    func addSubtitle(')]
source = 'import AVFoundation\n' + modes + '\nfinal class Probe { var options: [String:String] = [:]\nfunc set(_ key: String, _ value: String) { options[key] = value }\n' + method + '}\n'
source += '''
precondition(VideoScaleMode(rawValue: "fill") == .fill)
precondition(VideoScaleMode.fit.videoGravity == .resizeAspect)
precondition(VideoScaleMode.stretch.videoGravity == .resize)
precondition(VideoScaleMode.fill.videoGravity == .resizeAspectFill)
let probe = Probe()
for mode in [VideoScaleMode.fit, .stretch, .fill, .stretch, .fit] {
    probe.setVideoScaleMode(mode)
    precondition(probe.options["keepaspect"] == (mode == .stretch ? "no" : "yes"))
    precondition(probe.options["panscan"] == (mode == .fill ? "1" : "0"))
    precondition(probe.options["video-unscaled"] == "no")
}
print("PASS: AVPlayer/Aether gravity mapping; MPV fit, stretch, crop transitions and persisted fill compatibility")
'''
with tempfile.TemporaryDirectory(prefix='lucent-video-scale-') as tmp:
    path = Path(tmp); (path/'main.swift').write_text(source)
    subprocess.run(['swiftc','-module-cache-path','/private/tmp/lucent-swift-module-cache',str(path/'main.swift'),'-o',str(path/'verify')],check=True)
    subprocess.run([str(path/'verify')],check=True)
