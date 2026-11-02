#!/usr/bin/env python3
"""Execute production locale resolution and date formatting without launching the app."""
import json
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'Sources/LucentApp/LocalizationPreferences.swift').read_text()
checks = r'''
func expect(_ condition: @autoclosure () -> Bool, _ name: String) {
    precondition(condition(), name)
}
var p = LocalizationPreferences()
p.systemLanguages = ["zh-Hans-CN"]
p.systemLocale = "en_US"
p.systemZone = "America/Los_Angeles"
expect(p.interfaceLanguage == "zh-Hans", "simplified system language")
expect(p.contentLanguage == "zh-CN", "TMDB region-qualified language")
expect(p.subtitleSearchLanguage == "zh-cn", "OpenSubtitles simplified code")
p.systemLanguages = ["zh-Hant-TW"]
expect(p.interfaceLanguage == "zh-Hant", "traditional system language")
expect(p.subtitleSearchLanguage == "zh-tw", "OpenSubtitles traditional code")
p.interface = "en"
p.content = "ja-JP"
p.subtitles = "zh-TW"
p.audio = "original"
p.region = "GB"
expect(p.contentLanguage == "ja-JP", "content independent of interface and region")
expect(p.subtitleSearchLanguage == "zh-tw", "subtitles independent of metadata")
expect(p.audioTrackLanguages.isEmpty, "source audio retained by default")
expect(p.subtitleTrackLanguages.contains("zho"), "ISO 639-2 subtitle aliases")
p.audio = "en-US"
expect(p.audioTrackLanguages.contains("eng"), "audio alias")
expect(p.regionCode == "GB", "manual region")
p.dateOrder = "ymd"
expect(p.releaseDate("2026-11-01T00:00:00Z") == "2026/11/01", "release date is not shifted to previous day")
p.dateOrder = "dmy"
expect(p.releaseDate("2026-11-01") == "01/11/2026", "day-first date")
p.dateOrder = "mdy"
expect(p.releaseDate("2026-11-01") == "11/01/2026", "month-first date")
p.clock = "24"
p.zone = "UTC"
let date = ISO8601DateFormatter().date(from: "2026-11-01T13:05:00Z")!
expect(p.formatted(date).hasSuffix("13:05"), "24-hour clock")
p.clock = "12"
expect(p.formatted(date).contains("1:05"), "12-hour clock")
p.zone = "Asia/Shanghai"
p.clock = "24"
expect(p.formatted(date).hasSuffix("21:05"), "manual timezone")
p.interface = "system"
p.systemLanguages = ["fr-FR"]
p.content = "auto"
expect(p.interfaceLanguage == "en", "unsupported interface language fallback")
expect(p.contentLanguage == "fr-FR", "system content language is not limited to translated UI")
expect(p.releaseDate("bad-date") == nil, "invalid release date")
print("PASS: production locale, language aliases, date order, clock and timezone")
'''
with tempfile.TemporaryDirectory(prefix='lucent-locale-') as directory:
    script = pathlib.Path(directory) / 'main.swift'
    script.write_text(source + '\n' + checks)
    subprocess.run(['swift', '-module-cache-path', '/tmp/lucent-swift-module-cache', str(script)], check=True)
catalog = json.loads((root / 'Sources/LucentApp/Resources/Localizable.xcstrings').read_text())
for key in ['首页', '片源', '设置', '语言与地区', '界面语言', '字幕首选语言', '播放手势']:
    for language in ['en', 'zh-Hant']:
        assert catalog['strings'][key]['localizations'][language]['stringUnit']['value']
print(f"PASS: localized UI catalog ({len(catalog['strings'])} keys)")
