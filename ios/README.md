# Kibo for iPhone and Apple Watch

The SwiftUI clients use the existing `kibod` HTTP API. The iPhone app has a
large hold-to-talk surface, durable on-device recording before upload, an
explicit Ask Kibo action, project/conversation navigation, a live timeline,
and streaming reply playback. The Watch app fetches projects and conversations from the
same server and remembers its most recently selected project.

## iPhone audio design

The iPhone does not wait for a complete reply file. It opens the turn's speech
endpoint as an HTTP byte stream, decodes 24 kHz mono signed 16-bit little-endian
PCM as bytes arrive, begins playing after a 300 ms prebuffer, and keeps at most
one second of decoded audio scheduled in `AVAudioEngine`. Ordinary recorded
clips still download completely before `AVAudioPlayer` starts; the Watch reply
path also remains download-then-play.

The design follows the separation in Rich Hickey's *Simple Made Easy*:

- `AudioCoordinator` is the one UI-facing policy owner. Views request actions;
  they never sequence recording, playback, or `AVAudioSession` themselves.
- `AudioRecorder`, the HTTP transport, `PCMStreamLedger`, and
  `EngineSpeechRenderer` are separate, replaceable mechanisms.
- The reply path keeps three different facts explicit: samples received from
  HTTP, samples scheduled on the engine, and samples actually played.
- Recording owns audible hardware immediately, but does not cancel the reply
  download. On release, playback uses a fresh engine and resumes one second
  before the last played sample.
- A failed stream discards an unmatched byte and reconnects from the last
  complete decoded sample. Format changes are terminal rather than retried.
- Reply retention has a ten-minute safety cap; scheduled engine buffers remain
  bounded to one second even while the append-only rewind ledger grows.
- Route changes, interruptions, and media-service resets discard audio objects
  instead of attempting to preserve potentially invalid engine state.

These are invariants, not UI conventions: stale task/completion callbacks are
rejected by generation IDs, repeated hold events are idempotent, and only the
coordinator's session controller mutates the production `AVAudioSession`.

Generate the Xcode project and run the checks:

```sh
cd ios
xcodegen generate
xcodebuild -project Kibo.xcodeproj -scheme Kibo \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
xcodebuild -project Kibo.xcodeproj -scheme KiboWatch \
  -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm)' build
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

## Physical-device audio verification

Simulator tests cover byte boundaries, reconnect offsets, prebuffering,
received/scheduled/played cursor behavior, recording interruption and rewind,
stale completions, and coordinator ordering. They cannot validate real audio
routes or interruption timing. Before shipping, run this matrix on an iPhone
against `KIBO_AI_MODE=mock` and then once with live TTS:

| Scenario | Expected result |
|---|---|
| Built-in microphone and speaker | Reply starts before synthesis completes; holding talk silences it immediately; release resumes from about one second earlier. |
| Hold while reply is still buffering | Capture begins without waiting for the network; reply data continues arriving and plays only after release. |
| Wi-Fi loss and recovery during reply | Playback uses already received audio; transport reconnects from the last complete sample without a click caused by byte misalignment or duplicated prefix. |
| AirPods connected before playback | Reply uses the selected route; push-to-talk switches safely into capture and returns to a fresh playback engine. |
| Connect a Bluetooth or wired route mid-reply | Playback rebuilds from the played cursor without a stale completion stopping the replacement engine. |
| Remove the active headset mid-reply | Private playback stops instead of unexpectedly moving speech to the phone speaker; recording is cancelled safely. |
| Phone call or Siri interruption | Recording is cancelled and playback stops; returning to Kibo allows a new hold or play action with no stuck session. |
| Lock/background and return | Audio stops and the session deactivates; foreground preparation restores push-to-talk. |
| Media services reset | Recorder and renderer objects are discarded; the next user action creates working replacements. |
| Repeated rapid press/release | Exactly one recording is produced per hold and there is no overlapping recorder/player hardware use. |

Physical verification recorded 2026-07-15 on `ij` (iPhone Air, iOS 26.5.1):
the 29-test unit suite passed on-device, and the built-in microphone/speaker
stream → interrupt with push-to-talk → rewind/resume sequence passed an audible
user check without an observed playback problem. Bluetooth, wired-headset,
call/Siri, background, and media-reset rows still require explicit execution.

For every row, listen for duplicated words, missing audio, clicks at reconnects,
unexpected speaker fallback, and a stuck recording indicator. Verify audible
content, not just successful API calls or UI state. Record the phone model,
iOS version, route, server commit, and pass/fail result when executing the
matrix.
