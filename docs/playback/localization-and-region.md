# Language, region and date preferences

Settings → Language & Region uses independent preferences for:

- Interface: system, Simplified Chinese, Traditional Chinese, English. An unsupported
  system interface language falls back to English. Content may still use that language.
- Artwork/metadata: automatic follows the chosen interface language, or the system's
  first language when interface is system; common languages can be chosen manually.
- Subtitles: independent automatic/manual choice, used by OpenSubtitles search and
  initial AVPlayer, AetherEngine and MPV subtitle selection.
- Audio: preserve source default (default), automatic, or an explicit language.
- Region: system or ISO region; date order: regional, Y/M/D, D/M/Y, M/D/Y;
  clock: regional, 12h, 24h; timezone: system or an IANA zone.

## Data boundaries

TMDB calls carry the chosen language/region, including recognition, catalog, artwork,
credits/videos and episodes. Image/metadata languages remain independent from the app UI.
Title-image caches invalidate on content language/region changes without resetting the
home carousel's selection or progress. Text-free posters remain text-free. Images and
translations still depend on availability at TMDB.

Existing local metadata can be refreshed explicitly from Language & Region by matched
TMDB identity. This does not rematch files, change identity keys or clear watch history.
Metadata and episode records carry optional language stamps; old records remain decodable.
Failed requests retain the previous records and leave untranslated episode records retryable.
A language change during a request prevents stale results from replacing the new language.
Server titles, descriptions, user-defined source names, filenames and raw upstream errors
are not machine-translated; server metadata remains authoritative.

Interface labels use the system string catalog (Chinese source, English and Traditional
Chinese translations). App-owned dynamic labels explicitly opt into localization; media
names are not treated as UI translation keys. Some low-level diagnostic/error text may
remain in its originating language.

Date presentation uses explicit locale and timezone and a bounded thread-safe string
cache. Release dates are parsed as calendar days in the display timezone, so they do not
shift a day when viewing a UTC release date from a western timezone. Protocol ISO dates,
playback positions, durations and stored timestamps are unchanged. System locale and
system timezone notifications update the environment without recreating the root view.

Track preferences apply at playback startup. Explicit selections, imported subtitles and
handover selections retain priority. Original audio is retained unless the user opts into
an audio-language preference. No language setting performs a live track switch.

## References and differences

Uses Apple's native locale environment and string catalogs rather than modifying
AppleLanguages, swizzling Bundle or relaunching the application:
https://developer.apple.com/documentation/swiftui/environmentvalues/locale
https://developer.apple.com/documentation/foundation/bundle/1409418-preferredlocalizations

TMDB regional language codes and translated-data limits:
https://developer.themoviedb.org/docs/languages

Player-native language preference paths (no source copied):
- MPV `slang` / `alang`: https://mpv.io/manual/stable/#options-slang
- AVPlayerMediaSelectionCriteria:
  https://developer.apple.com/documentation/avfoundation/avplayermediaselectioncriteria
- The pinned AetherEngine's PlayerState.swift `LoadOptions.preferredAudioLanguages` /
  `preferredSubtitleLanguages`, and AetherEngine+Subtitles.swift's post-load selection.
  Audio and subtitle settings are passed only on startup, with empty subtitle preferences
  during engine handover to avoid overriding the current user selection.

`python3 scripts/verify-localization.py` executes the production Foundation resolver and
formatters offline. Build/install do not verify touch UI, live TMDB responses or playback
track selection. Those remain manual device checks under the project validation policy.
