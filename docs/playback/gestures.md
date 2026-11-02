# Playback gestures

The iOS gesture surface uses UIKit recognizers below SwiftUI controls and above video.
All engines receive actions through PlaybackSession, with no new playback or audio pipeline.

## Reference

Design study: KSPlayer `Sources/KSPlayerUI/View/IOSVideoPlayerView.swift`,
`panGestureBegan`, `panGestureChanged`, and MPVolumeView slider initialization:
https://github.com/kingslay/KSPlayer/blob/main/Sources/KSPlayerUI/View/IOSVideoPlayerView.swift

No KSPlayer source was copied. Lucent uses its own recognizer adapter and settings.
The same left-brightness/right-volume convention is used. Unlike velocity accumulation,
Lucent derives each change from the initial value and normalized translation, avoiding
frame-rate-dependent sensitivity. Volume uses an attached MPVolumeView and never changes
engine volume (reserved for engine handover).

## Ownership and lifecycle

- Single tap waits for double tap failure. Double tap can pause/play globally, or seek in
  the outer thirds and pause/play in the middle third. Off is available.
- One-finger pan locks direction with a 1.25 dominance ratio. Ambiguous diagonal gestures
  and gestures beginning within 24 points of the screen edge are rejected.
- Horizontal seeking previews a clamped target and submits exactly once on successful
  end; cancellation never seeks. Unknown-duration media cannot gesture-seek.
- Left vertical pan adjusts display brightness; right adjusts system output volume.
- Long press temporarily changes speed only when playback is requested; release,
  cancellation, backgrounding, locking, opening a panel or engine handover restores speed.
- Pinch selects aspect fit/fill. Controls, sliders, sheets and episode panels sit above
  the surface and own their touches. VoiceOver disables multi-touch/custom gestures;
  accessible playback controls remain available.
- Brightness is restored on dismissal by default, configurable. System volume persists.
- Auto-hide waits for gesture completion. Settings live at Settings > Playback > Gestures.

Build checks do not validate physical volume, brightness, touch arbitration or engine
behavior. These require manual verification on the device, following project policy.
