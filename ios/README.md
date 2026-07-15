# Kibo for iPhone and Apple Watch

The SwiftUI clients use the existing `kibod` HTTP API. The iPhone app has a
large hold-to-talk surface, durable on-device recording before upload, an
explicit Ask Kibo action, project/conversation navigation, a live timeline,
and streaming reply playback. The Watch app uses the same resumable PCM stream,
fetches projects and conversations from the same server, and remembers its most
recently selected project.

## Shared streaming design

Neither client waits for a complete reply file. Each opens the turn's speech
endpoint as an HTTP byte stream, decodes 24 kHz mono signed 16-bit little-endian
PCM as bytes arrive, begins playing after a 300 ms prebuffer, and keeps at most
one second of decoded audio scheduled in `AVAudioEngine`. Ordinary iPhone
recorded clips still download completely before `AVAudioPlayer` starts.

The design follows the separation in Rich Hickey's *Simple Made Easy*:

- `PCMStreamingPlayer`, `PCMStreamLedger`, `SpeechRendering`, and
  `EngineSpeechRenderer` are shared mechanisms. They know nothing about Watch
  scene policy, haptics, recording files, or route choices.
- The HTTP transport remains in `KiboAPI`; both clients call
  `speechStream(...fromSample:)`, now marked as `.avStreaming` network traffic.
- The reply path keeps three different facts explicit: samples received from
  HTTP, samples scheduled on the engine, and samples actually played.
- Recording owns audible hardware immediately, but does not cancel the reply
  download. On release, playback uses a fresh engine and resumes one second
  before the last played sample.
- A failed stream discards an unmatched byte and reconnects from the last
  complete decoded sample. Format changes are terminal rather than retried.
- Reply retention is injected policy: iPhone keeps its ten-minute cap; Watch
  uses a three-minute cap (4,320,000 samples, about 8.64 MB raw PCM). Scheduled
  engine buffers remain bounded to one second.
- Route changes, interruptions, and media-service resets discard audio objects
  instead of attempting to preserve potentially invalid engine state.

Transport generations reject replaced requests, renderer epochs reject old
buffer callbacks, and incomplete bytes are discarded before a retry begins at
the last complete decoded sample.

## Watch audio policy

`WatchAudioCoordinator` is the Watch view's only audio object. `WatchTalkView`
requests semantic actions such as begin/end hold, play reply, conversation
change, and stop for inactivity; it does not sequence recorder, renderer, task,
or session operations. `WatchAudioRecorder` owns only the recording file,
metering, and recorder identity. `WatchAudioSessionController` is the only
production Watch code that mutates `AVAudioSession`.

Capture switches the session to `.playAndRecord`/`.spokenAudio`, stops the
renderer immediately, and leaves HTTP transport running. Release creates a
fresh renderer under `.playback`/`.spokenAudio` and starts about one second
before the confirmed playhead. If release occurs before the 300 ms prebuffer,
the shared player retains a semantic rebuild intent so the eventual first
renderer still performs the required post-capture transition. Capture-start,
route, notification, task, and renderer replacements use hold IDs, lifecycle
epochs, transport generations, and renderer epochs rather than reset flags.

Route removal and interruption-began notifications tear down capture and reply
without automatic resume, preventing private headphone audio from moving to
the Watch speaker. Route and engine-configuration notifications replace the
renderer only when capture is not active. Media-service reset discards recorder
and renderer objects and waits for a new user action. Scene inactivity
invalidates queued work and prepared audio objects, stops
capture/transport/rendering, then deactivates the session; no background audio
mode is enabled.

## Watch-face complication

The Watch app includes a static WidgetKit complication named **Kibo** for the
small circular accessory slot used by information-dense watch faces. It shows a
waveform inside the system complication background and opens the Watch app when
tapped. In the Watch face editor, choose a circular complication position and
select Kibo. The complication has no timeline refreshes or network work.
Physical Watch verification confirmed that it appears in the circular slot and
opens Kibo when tapped.

This foreground short-form policy is deliberate. Apple documents incremental
buffer scheduling on [`AVAudioPlayerNode`](https://developer.apple.com/documentation/avfaudio/avaudioplayernode)
and engine playback on [`AVAudioEngine`](https://developer.apple.com/documentation/avfaudio/avaudioengine).
Apple's [Watch background-audio guidance](https://developer.apple.com/documentation/watchkit/playing-background-audio)
requires a Bluetooth route for long-form playback, which conflicts with Kibo's
built-in-speaker requirement. Apple's guidance also says to pause on
[`oldDeviceUnavailable`](https://developer.apple.com/documentation/avfaudio/avaudiosession/routechangereason/olddeviceunavailable),
observe [interruptions](https://developer.apple.com/documentation/avfaudio/handling-audio-interruptions),
and recreate audio objects after a [media-services reset](https://developer.apple.com/documentation/avfaudio/avaudiosession/mediaserviceswereresetnotification).

Generate the Xcode project and run the checks:

```sh
cd ios
xcodegen generate
xcodebuild -project Kibo.xcodeproj -scheme Kibo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project Kibo.xcodeproj -scheme KiboWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (42mm)' \
  -only-testing:KiboWatchTests test
```

Start the server from the repository root with `KIBO_AI_MODE=mock cargo run -p
kibod`. Both apps default to `https://wideboi.stingray-nominal.ts.net/` and
Settings can point them at another URL. For local integration testing, use
`http://127.0.0.1:3000`. Plain HTTP is enabled only for the current trusted
local-network server phase and should not be used on a public network.

## Deploy to Jesse's iPhone

With the paired phone available, build, sign, install, and launch the app with:

```sh
ios/deploy
```

The default device name is `ij`. To use another paired device, pass its name or
identifier:

```sh
ios/deploy 'My iPhone'
```

The script defaults to development team `NR57ZU358K`. Override it with the
`DEVELOPMENT_TEAM` environment variable if the signing account changes. If the
phone is locked, installation still succeeds but automatic launch does not;
unlock the phone and open Kibo normally.

## Automated verification

| Check | Environment | Result |
|---|---|---|
| Existing iPhone unit suite (including shared stream regression tests) | iPhone 17 Pro Max simulator, iOS 26.5 | PASS — 29/29 |
| Watch streaming/coordinator unit suite | Apple Watch Series 11 42 mm simulator, watchOS 26.5 | PASS — 14/14 |
| Watch application build | Apple Watch Series 11 42 mm simulator, watchOS 26.5 | PASS |
| Signed generic Watch device build | watchOS 26.5 SDK, team `NR57ZU358K` | PASS |
| Existing iPhone UI screenshot test | iPhone 17 Pro Max simulator, iOS 26.5 | PASS — 1/1 |
| Watch push-to-talk upload/stream/play UI integration | Watch Series 11 simulator + local `kibod` mock server | PASS — 1/1 |

The deterministic suites cover arbitrary byte boundaries, clean and failed odd
truncation, resume offsets, 300 ms prebuffering, bounded scheduling, transport
during capture, one-second rewind, stale renderer callbacks, capture-session
and recorder-start failures, release before prebuffer, route/interruption
teardown, inactivity cancellation, a non-cooperative stale loader, suspended
recorder preparation across inactivity/media reset, completion after audible
drain, and the Watch memory bound.

## Independent reviews

The initial architecture review recommended sharing the pure stream state
machine and renderer boundary while leaving session, route, lifecycle, and
capture policy on Watch. It also identified the recorder's hidden session
writes/preparation task, lack of a Watch test target, and the need for a smaller
Watch memory cap. The implementation follows those recommendations: one Watch
coordinator owns policy, the HTTP/ledger/renderer mechanisms remain separate,
the Watch has deterministic tests, and retained PCM is capped at three minutes.

The final concurrency/audio review found two stale-work races. A canceled but
non-cooperative loader could validate against and mutate a replacement reply,
and a recorder preparation suspended in the permission request could install an
audio object after inactivity or media reset. Both now use generation checks;
teardown invalidates prepared objects, and regression tests reproduce both
timings. The reviewer also called out engine-only configuration changes and
prepared-recorder validity after route loss. The Watch now observes
`AVAudioEngineConfigurationChange`, and every route/interruption teardown
invalidates recorder objects. The remaining speaker/Bluetooth timing,
`.dataPlayedBack` audibility, wrist-down behavior, interruptions, and energy
questions are retained as physical-only rows below rather than claimed as
automated passes.

## Physical-device audio verification

Simulator tests cannot validate real Watch speaker routing, Bluetooth profile
changes, interruption timing, wrist-down suspension, network handoff, energy,
or the meaning of `.dataPlayedBack` on physical hardware. Run this matrix on a
paired Apple Watch against `KIBO_AI_MODE=mock` and then once with live TTS:

| Scenario | Expected result | Status |
|---|---|---|
| Build, sign, install, and launch on paired Watch | App launches with the selected conversation and no stuck audio session. | PASS — device-specific build/sign, install, and launch succeeded |
| Built-in Watch microphone and speaker | Reply starts before synthesis completes; hold silences it immediately; release resumes about one second earlier. | Unexecuted — app could not be installed |
| Hold before reply prebuffer | Capture begins immediately; received audio waits and starts under a fresh playback session after release. | Unexecuted — app could not be installed |
| Repeated rapid holds | One recording per completed hold; no overlapping recorder/renderer hardware ownership. | Unexecuted — app could not be installed |
| Network loss and recovery | Cached audio drains; reconnect uses the last complete sample without duplicated prefix or alignment click. | Unexecuted — app could not be installed |
| AirPods connected before playback | Selected route plays; capture transition and fresh-renderer return work. | Unexecuted — app could not be installed; AirPods availability not established |
| Remove active AirPods/headset | Reply and capture stop; speech never falls through to the Watch speaker. | Unexecuted — app could not be installed; AirPods availability not established |
| Wrist down / app background | Audio stops under current policy and return restores the next explicit action; no queued work reactivates the session. | Unexecuted — app could not be installed |
| Call or Siri interruption | Capture/reply stop and require explicit user action afterward. | Unexecuted — app could not be installed |
| Media-services reset | Objects are discarded and the next explicit action rebuilds them. | No Watch reset control identified; unexecuted |

Physical verification recorded 2026-07-15 on `ij` (iPhone Air, iOS 26.5.1):
the 29-test unit suite passed on-device, and the built-in microphone/speaker
stream → interrupt with push-to-talk → rewind/resume sequence passed an audible
user check without an observed playback problem. Bluetooth, wired-headset,
call/Siri, background, and media-reset rows still require explicit execution.

For every executed Watch row, listen for duplicated words, missing audio,
clicks at reconnects, unexpected speaker fallback, and a stuck recording
indicator. Record Watch model, watchOS version, paired phone, route, server
mode/commit, and result. The existing iPhone physical results above remain
separate evidence and do not count as Watch passes.

Paired-Watch deployment recorded 2026-07-15: after pairing completed and Xcode
mounted the developer disk image, `Jesse’s Apple Watch` (`Watch7,11`, watchOS
26.5) became an eligible arm64 destination. Xcode registered the Watch, created
a device-specific provisioning profile, and the signed app installed and
launched successfully. This validates deployment only; every audible Watch row
above remains genuinely unexecuted until a person performs and records it.
