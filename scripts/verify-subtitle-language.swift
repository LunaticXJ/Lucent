import Foundation
@main struct Verify {
 static func main() {
  precondition(SubtitleLanguageDisplay.languages(in: "Movie.chs.srt") == ["zh-Hans"])
  precondition(Set(SubtitleLanguageDisplay.languages(in: "简英双语.ass")) == ["zh-Hans", "en"])
  precondition(SubtitleLanguageDisplay.languages(in: "English SDH", declared: "eng") == ["en"])
  precondition(SubtitleLanguageDisplay.languages(in: "繁體中文", declared: "zho") == ["zh-Hant"])
  precondition(SubtitleLanguageDisplay.languages(in: "commentary", declared: "ja") == ["ja"])
  precondition(SubtitleLanguageDisplay.languages(in: "unknown.track.srt", declared: "und").isEmpty)
  let english = SubtitleLanguageDisplay.title("chs", locale: Locale(identifier: "en"))
  let chinese = SubtitleLanguageDisplay.title("eng", locale: Locale(identifier: "zh-Hans"))
  precondition(english.lowercased().contains("chinese"))
  precondition(chinese.contains("英语"))
  precondition(SubtitleLanguageDisplay.title("Unknown track", locale: Locale(identifier: "en")) == "Unknown track")
  precondition(SubtitleLanguageDisplay.title(english, locale: Locale(identifier: "en")) == english)
  print("PASS: subtitle aliases, bilingual scripts, metadata priority, localization and unknown fallback")
 }
}
