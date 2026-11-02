# Percentage-based playback memory

Defaults: remember at 5%, complete at 90%. Settings → Playback → Resume Progress allows
0/1/2/3/5/10% starts and 80/85/90/95/98% completion. Thresholds are sanitized so the start
always precedes completion. The lower and upper boundaries are inclusive.

## Policy and state

- Below the start: persist no resume point.
- Between thresholds: persist the current confirmed position.
- At/above completion: mark watched once, persist position zero, sync immediately.
- Confirmed EOF: mark watched even when duration is unknown or the final periodic save
  has not fired. This is independent of threshold detection.
- Unknown duration: do not create a percentage-based checkpoint or infer completion.
  An existing checkpoint is retained if duration probing fails.
- Invalid clocks are ignored. Startup zeros and pending resume/seek clocks are rejected
  by the existing PlaybackProgressTracker before reaching persistence.
- The live clock used for handover, foreground recovery and seeks is separate from the
  persisted resume position, so marking watched never seeks the current player to zero.
- Replaying a completed item keeps its watched status; manually marking unwatched resets
  it. A completed item starts from zero on the next separate playback session.

A nonmodal, dismissible next-episode suggestion appears at completion (configurable),
without pausing or advancing the current video. Existing next-episode autoplay at actual
EOF is retained. No early autoplay/countdown is introduced.

All engines use the same policy. MediaItem's resume state, movie/episode detail buttons
and the home Continue Watching row use the same normalization. A newer local state wins
over an older server snapshot, including an intentional cleared resume point; taking the
maximum of old server and new local positions would incorrectly resurrect a checkpoint.
Changing thresholds affects checkpoint eligibility; it does not bulk rewrite server history.

## Reference

Design reference, no copied code: Jellyfin UserDataManager.UpdatePlayState, specifically
its minimum/maximum resume percentages, clearing position on completion, and keeping the
played flag independent of live playback:
https://github.com/jellyfin/jellyfin/blob/master/Emby.Server.Implementations/Library/UserDataManager.cs

Lucent differs by preserving previous state when duration is unknown rather than inferring
completion, and by keeping a separate engine handover/recovery position.

`python3 scripts/verify-progress-policy.py` executes the production policy, the production
LibraryStore.updateProgress body with transport stubs and the production live clock tracker.
It covers boundary values, custom settings, invalid/unknown clocks, completion synchronization
and rewatch behavior. No playback or simulator UI regression is run by default.
