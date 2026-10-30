# Playback handover diagnosis (2026-10-27)

## Reproduced evidence

A real-device audit on jiangyi's iPhone reproduced the pause after the first
AetherEngine → MPV handover. Immediately before the request, AetherEngine reported
`seeking` while AVPlayer's rate was `1`. The previous code classified every state
except `playing` as a user pause. Three seconds after committing, MPV reported
`paused=true` and its time had stopped advancing. This was an explicit host pause,
not proof that the source or the decoder had failed.

The pre-fix capture is `/tmp/lucent-audit-console.log` on the development Mac.
The final targeted audits below passed after the lifecycle fixes. Earlier
intermediate passes are retained here to explain why those were insufficient.

## References consulted

- Sodalite `PlayerViewModel.swift` and `PlayerHostController.swift`, revision
  `31799bde53e2d93384216b3f9b2523600896ef2b`: engine loading and AVKit surface ownership.
- AetherEngine `PlayerState.swift`, `AetherEngine.swift`, and
  `NativeAVPlayerHost.swift`, revision `61250c9f9fe1624d4ac4b2d069fb0bdaca2cc213`:
  transient seeking states, `autoplay`, volume range, source-time mapping, and
  shared audio-session lifecycle.
- mpv official manual, `loadfile`: start/pause are per-file options and the
  load command returns before the new file has finished opening.
  https://mpv.io/manual/stable/#command-interface-loadfile
- mpv iOS audio outputs: teardown releases the process-wide AVAudioSession.
  https://github.com/mpv-player/mpv/blob/master/audio/out/ao_audiounit.m
  https://github.com/mpv-player/mpv/blob/master/audio/out/ao_avfoundation.m
- mpv `player/command.c:mp_property_idle` reads only `stop_play == PT_STOP`.
  `player/loadfile.c:play_current_file` emits END_FILE after `uninit_audio_out`.
  An idle property reading is therefore not an audio teardown completion fence.
  https://github.com/mpv-player/mpv/blob/master/player/loadfile.c

These references informed Lucent's own coordination code. Sodalite does not
implement Lucent's AetherEngine/MPV handover and is not evidence that a cross-engine
transition is seamless on this device.

## Coordination rules

- User playback intent is stored independently of decoder states such as loading,
  buffering, or seeking. Those states never implicitly request a pause.
- One task owns each entire handover, from warming through commit or rollback.
  A generation invalidates callbacks after close/replacement.
- The outgoing engine stays active during target warm-up. Both render surfaces
  keep their identity. The target renders at full opacity behind the old surface;
  the old surface fades only after target readiness and seek alignment.
- The final source position is frozen once. Neither source timer overwrites the
  session's progress with a teardown/reset clock during that short interval.
- MPV loads with `start` set before decoding. It does not render frame zero and
  rely on a later periodic tick to restore progress.
- A successfully handed-over MPV is paused and muted, retaining one file/AO
  until reuse or playback exit. Full retirement (cold replacement/failure) must
  emit END_FILE and release `current-ao` before reactivating another route.
  An idle property alone never establishes that barrier.
- A failed pre-commit transition restores the outgoing engine. Cleanup always
  releases the transition task. A queued selection is handled after cleanup.

## Opt-in device audit

Only a DEBUG build launched with `LUCENT_PLAYBACK_AUDIT=1` enters the audit UI.
It uses an already configured Emby account selected by `LUCENT_AUDIT_SOURCE_ID`
(the local connection UUID), and an item specified by `LUCENT_AUDIT_ITEM`.
Both environment variables are required. No credentials are embedded in the code.
The audit starts at 180 seconds and executes three native → MPV → native cycles,
checking task completion, progress advancement, pause state, and native volume.

`Documents/PlaybackAudit.log` records timestamped state snapshots.
`Documents/AetherRouting.log` records engine-redacted diagnostics. No media URLs
are part of the state snapshots. Normal launches do not run the audit.

A passing audit proves the measured time/transport conditions. It does not prove
that every visible frame or every audible sample is continuous, nor that every
codec, output device, or server behaves identically.

## Additional real-device observations

- The continuous-source version completed three round trips in
  `/tmp/lucent-audit-continuous-console.log` with both clocks advancing after
  each commit. Sources continued playing while the target was positioned ahead
  and waited for the source clock, instead of pausing the source for a slow seek.
- Starting directly in MPV produced a first `PLAYBACK_RESTART` time reading of
  180.43 seconds for a requested 180-second resume, not a zero-second reading.
- That run then exposed another race: a native target's `load()` returned while
  its state was still `loading`. An immediate seek was stashed as a pre-ready
  seek and replayed after commit; its old paused transport intent later paused
  the new session. Capture: `/tmp/lucent-audit-mpv-resume-console.log`.
- The readiness gate waits for `isSessionReady` and for `loading`/`seeking`
  to settle before treating any seek as complete. This removed the deferred-seek
  race, but the next run exposed a separate audio-retirement race.
- A new run was blocked by iOS device locking. PlaybackView now preserves and
  temporarily disables the system idle timer while the player is presented,
  including MPV playback, and restores the previous setting on exit.
- The session-ready run still paused in its third reverse transition
  (`/tmp/lucent-audit-ready-final-console.log`). A follow-up trace showed a native
  rate-zero edge after every reverse commit. `idle-active` had permitted the host
  to reactivate audio before the old AO's teardown completed. The stop barrier
  now consumes END_FILE, checks that `current-ao` is absent, and has a bounded
  deadline. Final regression results are recorded below.
- `LUCENT_TRANSPORT_TRACE=1` additionally traces AVPlayer pause/rate-zero call
  stacks and mirrors engine diagnostics to the debug console. This is disabled
  in normal launches and in the final timing regression to avoid perturbing it.

## Final targeted device regression

Build: Debug iOS, MPVKit `d9194243bdc68b87d8989376ab52aee7da6c8e0b`,
AetherEngine `61250c9f9fe1624d4ac4b2d069fb0bdaca2cc213` in the dynamic
LucentAether wrapper. Installed on `jiangyi的 iPhone`; no simulator was used.
Test item: the configured Emby account's 《后室》, MKV / Dolby Vision P5 /
E-AC-3 JOC, resume target 180 seconds.

| Run (2026-10-27 CST) | Result |
| --- | --- |
| MPV startup, 20:30–20:31 | First PLAYBACK_RESTART time reading 180.472s. Initial MPV → native handover and three further native → MPV → native cycles completed. Each settled target advanced over the following 3 seconds, with native rate 1, volume 1, unmuted; MPV unpaused, volume 100. PASS. |
| Native startup, 20:31–20:32 | Player loading cover released at sourceTime 179.999s for requested 180s. Three native → MPV → native cycles completed with the same transport/progress/volume assertions. PASS. |

Captures on the development Mac:
`/tmp/lucent-audit-endfile-mpv-console.log` and
`/tmp/lucent-audit-endfile-native-console.log`.

These are two startup paths and six complete round trips (12 switches), plus
the initial MPV → native handover. Full transport tracing was off in both runs.
No failed or rolled-back transition was reported. Native delivery remained
`loopback` / `streamCopy`; the fix does not reroute Dolby Vision to MPV.

The test does not directly record the physical screen or microphone output.
It verifies readiness, resume coordinates, lifecycle completion and continuing
transport, rather than claiming pixel-perfect or acoustically gapless handover.

## Playback settings selection (2026-10-27)

The user's follow-up exposed a separate UI gap. The old nested Menu called
`selectEnginePreference` without closing the parent settings overlay. It showed
neither the active engine nor handover progress, and the overlay hid the footer
that carries failures. The device capture at 1793104671.441–1793104674.852 shows
that the reported selection did reach the coordinator and committed the native
route in about 3.4 seconds (rate 1, volume 1), despite the settings remaining open.
That capture establishes this attempt, not every subsequent tap.

Settings now uses directly selectable rows: selection closes the panel, the
active engine is shown separately from the preference checkmark, and the footer
reports warming and completion. Initialization failures are explicit. An error
brings controls forward instead of remaining hidden under an overlay. Status
state is cleared on commit, rollback, replacement, and close; it does not hold
the engine's transition task.

Design reference: Sodalite's `PlayerTrackDropdown.swift` active/highlighted rows
and `PlayerNoticeBanner.swift` transport notices, same revision cited above.
Lucent implements its own controls; no upstream code was copied. This UI change
is build/install checked only. The earlier automated transport regression called
the coordinator directly and did not verify tapping these settings controls.

Manual check: while playing in MPV, open playback settings and select AVPlayer.
The panel should close immediately, show a switching status, then a completion
notice. Reopening settings should show `当前：AVPlayer`. Repeat in the reverse
direction; errors should remain visible with the original engine preserved.

## Audible discontinuity follow-up

The next user report identified a perceptible audio gap, especially MPV → native.
Recent captures (`/tmp/lucent-audio-gap-audit.log`) show about 0.94–1.08 seconds
between the final alignment and native commit. This measures the complete commit
stage, not microphone-measured silence. The code paused the source **before**
starting its volume ramp, so the apparent crossfade did not overlap two running
outputs. MPV's subsequent stop uninitialized RemoteIO and deactivated the shared
AVAudioSession. The ordering fix prevented a permanent pause, but still required
an output teardown/reactivation inside the audible transition.

Revised coordination:

- Keep the source rolling at full volume while the muted target starts. Wait
  for target clock advancement and native `timeControlStatus == playing` (or MPV
  non-buffering/non-seeking playback) before fading. A paused ready frame is
  insufficient. If clocks differ by more than the bounded tolerance, reposition
  the muted target while the source continues, up to three attempts.
- Read native's live item clock through Aether's public `presentationAxisMap`
  when available, folding out its presentation origin. The UI's ~10 Hz clock
  is too coarse for this alignment. Other routes retain the public engine clock.
- Run one 200ms compositor fade and a matching volume ramp while both transports
  roll. Pause the outgoing transport only after its volume reaches zero.
- Park the single outgoing MPV paused/muted. `pause` stops RemoteIO without the
  AO uninit's process-wide deactivation. Re-entering the same file seeks that
  parked instance, retaining its AO/Metal context. A successful handover no longer
  calls the audio category/activation helper; recovery still can.
- iOS/tvOS MPV AO is initialized with `audio-exclusive=yes`: in the mobile
  AudioUnit backend this selects the same non-mixing playback session policy as
  AVKit. It does not claim desktop hardware exclusivity. The handover no longer
  toggles `.mixWithOthers` as a side effect of recreating/activating audio output.
- On cold source replacement, cancel older retirement work and await complete
  MPV retirement before opening the next route. Close destroys the parked core.
  A user pause during the actual overlap pauses both transports.

References: pinned Aether `PresentationAxisMap.swift`/`PlaybackClock.swift` and
mpv `ao_audiounit.m` (`stop` versus `uninit`), `playloop.c:idle_loop` (STOP state
uninitializes AO even with gapless enabled), and the official pause command.
https://github.com/mpv-player/mpv/blob/master/audio/out/ao_audiounit.m
https://github.com/mpv-player/mpv/blob/master/player/playloop.c
https://mpv.io/manual/stable/#property-list-pause
This is Lucent's coordination design, not copied upstream hybrid-player code.

Tradeoff: one inactive MPV decoder, its bounded cache and GPU resources remain
allocated during native playback after a handover. They are not multiplied per
switch, and are released on source replacement or exit. This avoids adding a
global audio-session swizzle or rebuilding MPV's AO merely to bypass deactivation.

Status: latest code builds for the physical iPhone. No automatic runtime test
was run for this follow-up, in accordance with the user's verification preference.
The earlier passing transport audits predate this optimization. Physical audible
continuity, visual fade smoothness and behavior on Bluetooth/AirPlay/HDMI remain
manual checks; renderer clocks are not proof of a gapless audio waveform.

## Resume checkpoint protection follow-up

The next report mentioned a rare red switching failure and occasional playback
from the beginning. Reading both files from the device found only a later
successful native/MPV round trip (native commit at 1793107352.572, MPV commit at
1793107360.062). No failure is present in those captures. The user explicitly
deferred further investigation of the rare failure; the switching algorithm was
not changed in this follow-up.

Code inspection found a concrete resume-loss path: `close()` cleared the reverse
handover flag and then preferred native's clock whenever `useAether` was true.
During MPV → native warm-up both flags are true, but native may still read zero.
That zero could be written to the library and reported to the server as stopped
progress. Cold loads could similarly report their provisional zero before resume
had actually landed. A stale direct-AVPlayer time-observer callback could also
reach a later route.

Changes:

- `PlaybackProgressTracker` separates a requested resume target from confirmed
  decoder progress. A not-ready clock or one before the requested position cannot
  establish a checkpoint. A real rewind can replace the old checkpoint; values
  are not merged with `max(old,new)`.
- Stop captures the actual source owner **before** clearing handover flags. If
  startup has not established a checkpoint, it leaves library/server progress
  unchanged. Invalid/reset decoder clocks fall back to the confirmed checkpoint.
  Closing is idempotent and late progress samples are ignored after close.
- Engine retries retain the requested/confirmed position. Native resume loading
  cannot drop the cover after its deadline and silently expose a zero-position
  picture; it surfaces a positioning failure with the original target retained.
- A newer local playback state supersedes the detail screen's stale item snapshot.
  AVPlayer time-observer callbacks are bound to their exact current player item.
- Every load logs its requested resume and measured landing. Every failure message
  is logged through engine redaction. Before the next session overwrites the two
  latest log files, they are archived under `Documents/PlaybackHistory/`, retaining
  ten prior sessions and at most 1 MiB per file.

Reference: pinned Sodalite `PlayerViewModel.startPlayback` distinguishes a requested
resume from outage recovery, and `stopPlayback` suppresses a stop report when
`hasReportedStart` is false, specifically to avoid writing zero over saved progress.
Lucent applies that lifecycle rule to its own multiple-engine ownership model.

Verification: a small Swift harness compiled the production tracker and checked
cold resume, retry, unready zero, genuine rewind, invalid clocks, explicit restart
at zero, and bidirectional handover ownership. All passed. The iOS build passed.
There was no simulator/device playback run for this follow-up. The rare switching
failure remains unclassified until a future archived failure is available.

## MPV -13 load failure and recovery

The next screenshot reports `MPV 播放失败（-13）` for 重返天南 18. Device
captures `/tmp/lucent-mpv13-audit.log` and `/tmp/lucent-mpv13-aether.log`
show no initialized MPV audio/video output. A subsequent native request enters
warm-up, then rolls back because `check()` reads the **already failed source's**
MPV error. Selecting MPV again was a no-op because it was still the active flag.

The pinned libmpv `client.h` defines -13 as `MPV_ERROR_LOADING_FAILED`, an
approximate opening/loading failure. It is distinct from AO initialization (-14),
VO initialization (-15), and unknown format (-17). The captures do not include
libmpv warning messages, so they cannot identify an expired URL, HTTP status,
network failure or bad media bytes as the original cause.

Changes:

- An explicitly failed current transport is reopened when choosing an engine,
  including reselecting the same engine. It does not enter a warm handover with
  a dead source. Healthy playing transports retain the existing handover flow.
- Error recovery and the error row's retry button retain the tracker checkpoint,
  close the old session, then negotiate the source again. For Emby this fetches
  the item's MediaSources again and starts a new range listener instead of reusing a dead
  URL. The requested position remains visible during source negotiation.
- Range-read failures no longer trigger the legacy hard-coded 8 Mbps Emby
  transcode request. The server used here has transcoding disabled. Explicit
  user-selected transcoding remains separate. Automatic direct reconnects are
  still bounded to two and retain the tracker position.
- Emby source-generation checks reject old read-failure callbacks and cancelled
  source tasks after recovery, preventing them from changing the new session.
- On a cold restart, SwiftUI surfaces are keyed by their engine objects. A newly
  created MPV instance must get its own Metal view; the old representable's empty
  update method cannot attach a new engine. Identities stay stable across healthy
  warm handovers. Native loading-cover flags are reset on replacement/close.
- Subscribe with `mpv_request_log_messages(handle, "warn")`, immediately copy
  `MPV_EVENT_LOG_MESSAGE` data before the next wait call, and persist it with
  END_FILE codes and synchronous load-command failures. These join the existing
  archived logs. All complete media URLs are removed before logging third-party
  messages, in addition to EngineLog's credential redaction.

References, reviewed as designs/APIs rather than copied implementation:

- Pinned Sodalite `PlayerViewModel.retryAfterOutage` drops cached PlaybackInfo,
  preserves the outage position, stops the host and runs source negotiation again.
  Lucent adapts this to its tracker, local range server and two engine instances.
  Its direct route refreshes item MediaSources through the user item endpoint;
  it does not call the transcode-oriented PlaybackInfo path for this recovery.
  https://github.com/superuser404notfound/Sodalite
- The libmpv API documents load errors as approximate; LOG_MESSAGE carries the
  detailed explanation and its event-owned strings expire at the next wait call.
  https://github.com/mpv-player/mpv/blob/master/include/mpv/client.h

The final build passed and was installed to jiangyi's physical iPhone
(`devicectl` installation database sequence 5968). No Lucent process was running
at the pre-install query, and the application was not launched after installation.

Verification: iOS compilation plus a pure Swift check of production checkpoint
and diagnostic URL removal code. These checks do not open any media. The original
source-opening cause remains unconfirmed; fresh warning logs and manual playback
are needed to establish it. No automatic device/simulator playback is run.
