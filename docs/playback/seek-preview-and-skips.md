# Scrub preview and intro/credits skipping

## Preview

The progress slider presents a fixed-size card above the finger, clamped within its track.
It is an overlay and does not change footer layout. Horizontal seek gestures share the
same preview source. A setting at Settings → Playback enables/disables frame extraction.

PlaybackSession coalesces input into one in-flight decode and one latest pending target;
continuous input does not indefinitely postpone work. Results have a gesture generation
so cleared/superseded sessions cannot publish late frames. Forty two-second buckets bound
the image cache. A keyframe thumbnail is approximate: the image carries an ≈ time badge,
while the target timestamp is updated with the finger. Intermediate results can therefore
remain useful during continuous dragging without pretending they are the latest target.

Source order: Aether's existing segment-cache thumbnail, then a reusable FrameExtractor
for the authenticated playback source/loopback URL (including MKV/MPV sources). This uses
the existing LucentAether dynamic dependency; no second playback engine or audio output is
started. Session-coupled Aether extraction yields to a starved playback pipeline. Other
routes also suppress new extraction while preparing, buffering, seeking or handing over.

Commit/cancel/background/source replacement/close cancel the UI worker and shut down its
isolated extractor. The library's FFmpeg read deadline bounds stalled reads; shutdown may
need to wait for an outstanding read to return. Sources that reject extra reads or cannot
extract a frame retain the time-only fallback. Seek and playback errors are independent
of thumbnail errors. Previews may consume additional network data while actively scrubbing.

## Skip rules

One resolver combines server markers/chapters and local manual markers. Manual intro end
and relative credits duration override their respective kinds. Relative tail duration means
applying a 2-minute tail to different episode runtimes produces different start positions.
The setting can be applied to already-imported episodes of the same season and source;
Emby/Jellyfin/Plex accounts are scoped by their separate source IDs.

Playback Settings → Intro & Credits edits markers, supports seconds or MM:SS/HH:MM:SS,
and can use the current position. Empty fields revert to server/chapter markers. Automatic
skipping remains separately configurable. With auto-skip off, a button is shown in the
valid segment even when normal controls are hidden. Invalid/full-film intervals are rejected;
repeat jumps into the same segment are suppressed for the session. No audio/video fingerprint
analysis or guessed intro duration is performed when markers are unavailable.

Jellyfin MediaSegments and Plex Marker are retained. Emby now honors explicit IntroStart,
IntroEnd and CreditsStart markers even when chapter names are generic. Named chapters are
available from AVPlayer, Aether mediaChapters and MPV chapter-list on their playback axes.

## Reference and validation

Design study only; no third-party implementation copied:
https://github.com/superuser404notfound/Sodalite/blob/main/Sodalite/Player/ScrubPreviewProvider.swift
https://github.com/superuser404notfound/Sodalite/blob/main/Sodalite/Player/SkipSegmentResolver.swift

Sodalite's provider prioritizes resident cache bytes, bounds image work and guards generations;
Lucent coalesces input instead of continuously debouncing, and shuts down extraction when
scrubbing ends. Current pinned AetherEngine FrameExtractor and AetherEngine+ScrubThumbnail
provide isolated FFmpeg extraction and cache-backed thumbnails directly.

`python3 scripts/verify-playback-skip.py` executes production time parsing, marker parsing and
resolution with invalid inputs and different episode runtimes. Build checks do not validate
network thumbnail responsiveness, picture colors or actual seek/skip playback. These remain
manual checks; no simulator playback/UI regression is run by default.
