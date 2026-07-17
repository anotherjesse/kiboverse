# kibo

A Raspberry Pi voice/AI companion project. This repo is the working notebook:
code pulled off the Pi, hardware setup notes, and the plan for where it's
headed. The core idea is the push-to-talk AI loop (see Roadmap); the robot
embodiment (3D-printed body, servos, animated face) is the current form
factor but may change — the body needs a re-print and the robot part may not
survive long-term.

The Pi is reachable on the local network as `kibo.local` (ssh).

## Phase-one server and web client

`kibod` is the shared Rust server described in `server-design.md`. It stores
projects and conversations, accepts idempotent WAV clip uploads, transcribes
them, creates AI turns, streams reply audio as 24 kHz mono PCM, and serves the
HTMX browser client. Every client selects an explicit project and conversation;
there is no server-global "active conversation."

Start it locally:

```sh
cargo run -p kibod
```

The Rust API models are the source of truth for the iPhone and Watch wire
types. Regenerate the checked-in Swift definitions after changing them:

```sh
just generate-types
```

`just check-generated-types` fails when the generated file is stale.

Then open <http://127.0.0.1:3000>. Without `GEMINI_API_KEY`, kibod deliberately
runs in mock mode so the full record → upload → turn → streamed-audio path can
be exercised without credentials. Set these environment variables as needed:

| Variable | Default | Purpose |
|---|---|---|
| `GEMINI_API_KEY` | unset | Enables Gemini transcription, chat, and TTS |
| `JINA_API_KEY` | unset | Raises Jina Reader limits for project URL ingestion |
| `KIBO_AI_MODE` | automatic | Set to `mock` to force deterministic local AI |
| `KIBO_DATA_DIR` | `~/kibo-data` | Durable projects, logs, clips, and speech |
| `KIBO_BIND` | `127.0.0.1:3000` | Listen address; use `0.0.0.0:3000` on a trusted LAN/tailnet |

The browser records mono WAV, commits each clip to an IndexedDB retry spool
before uploading, and will not submit a turn until its pending uploads are
acknowledged. The server log remains authoritative: live WebSocket events are
paired with cursor-based `GET /events?after=<seq>` recovery.

Projects act as folders and may be empty. The browser's project page starts
unnamed chats without asking for a room name, lists them by recent activity,
and opens each as an independent conversation. New conversations are named
from the first successful transcription. A later
AI-generated title after a few completed turns is intentionally left as a
phase-two TODO; manual names will remain authoritative.

Each project also has a **Knowledge** workspace in the browser. It compiles
changed conversations into Markdown source notes, can force-regenerate one
note, imports or refreshes public webpages and PDFs through Jina Reader, and
renders generated Markdown alongside its raw text. The notes and successful
content-hash checkpoints live under the project's `knowledge/` directory.

This phase has no user authentication and is intended only for localhost or a
trusted tailnet. Browser microphone capture works on localhost; remote browser
access must be placed behind an HTTPS terminator because browsers do not expose
the microphone to ordinary remote HTTP pages. Browser mutations and WebSocket
connections are restricted to the page's own origin.

## Hardware

- **Raspberry Pi 4 Model B Rev 1.4** — Debian 12 (bookworm), Python 3.11.2
- **240×320 ILI9341 SPI display** — renders the animated face
  (backlight on GPIO18, CS on CE0, DC on GPIO25, RST on GPIO24)
- **USB speaker + microphone** — enumerates as `AIRHUG 01` (`2f9d:320a`),
  ALSA card name `A01`; both playback and capture on the one device
- **Servos** — driven via `servo_controller.py` / WiringPi on the Pi
- **ReSpeaker Lite + XIAO ESP32-S3** — standalone Wi-Fi client prototype in
  `respeaker/`; 2-mic XMOS front end, onboard speaker, PSRAM-only recording
- 1.28" round touch LCD (Waveshare) — on the Pi but not wired into the face
  scripts yet
- Happy Hacking Keyboard Lite2 plugged in for local console use

## Audio setup (done 2026-07-14, the hard way)

Our code addresses the USB speaker/mic **explicitly** as `plughw:A01,0`
(override with `KIBO_AUDIO_DEV`). By name, not card number, so it survives
reboot renumbering; `plughw` gives automatic rate/format conversion (the
device is natively 48 kHz stereo only).

**Never use the ALSA `default` device on this box.** Pi OS routes `default`
through the pulse plugin into PipeWire, which ignores `~/.asoundrc` in
practice and can silently record pure zeros while returning success. We lost
an afternoon to this — always verify recordings by content (peak/rms),
never by exit code. ptt logs a peak% per clip for exactly this reason.

PipeWire is told to leave the card alone via
`~/.config/wireplumber/main.lua.d/51-disable-airhug.lua` (device.disabled).
Without it, the desktop holds the playback stream open permanently, and on
this full-speed USB device the idle reservation starves the mic: capture
wants 512 bytes/frame — the single biggest reservation on the Pi 4's shared
internal USB2 hub — so capture is always what fails when bandwidth runs out
(`dmesg`: "Not enough bandwidth for altsetting"). Keep low-speed devices
like the DragonRise joystick off the bus or behind another hub if the mic
goes silent, and note the errors are rate-limited: absence from dmesg
proves nothing.

Quick tests (music playing or speaking near the puck):

```sh
aplay -D plughw:A01,0 test.wav
arecord -D plughw:A01,0 -d 4 -f S16_LE -r 44100 /tmp/t.wav
python3 - <<'EOF'   # verify content, not exit code
import wave, audioop
w = wave.open("/tmp/t.wav"); f = w.readframes(w.getnframes())
print("peak:", audioop.max(f, 2), "rms:", audioop.rms(f, 2))
EOF
aplay -D plughw:A01,0 /tmp/t.wav
```

## Repo layout

- `original/` — snapshot of the face-animation scripts as they existed on the
  Pi (`f2.py`–`f9.py` are iterations; `face.py` is the largest/most complete).
  Kept as-is for reference before any refactoring happens here.
- `recplay/` — Rust package, two binaries. `recplay`: chime, record N
  seconds, chime, play back. `ptt`: joystick push-to-talk — hold button 0 to
  record (raw PCM streamed from `arecord` through Rust, WAV written by us,
  live peak metering), release to save durably (timestamped file +
  `turns.jsonl`, blob before metadata), button 1 plays back everything since
  the last reply (simulated AI turn). No audio C libraries; `arecord`/`aplay`
  are used only as thin device shims.
- `respeaker/` — PlatformIO firmware for the ReSpeaker Lite/XIAO ESP32-S3.
  It records processed 16 kHz audio through a bounded PSRAM buffer ring,
  uploads idempotent 20-second parts to `kibod` over LAN HTTP, commits one
  logical clip on release, and separately asks Kibo to answer all waiting
  clips while resampling streamed 24 kHz replies for the onboard speaker. See
  its README for the USR=record and MUTE=ask solder bridges and provisioning.
- `pi-config/` — files that live on the Pi, kept here so it's reproducible:
  the WirePlumber rule (→ `~/.config/wireplumber/main.lua.d/`) and the ptt
  systemd unit (→ `/etc/systemd/system/`).
- `deploy.sh` — build + push binary and config + (re)start the `ptt`
  service, all in one. Logs on the Pi: `journalctl -u ptt -f`.

## Rust cross-compile (Mac → Pi)

The Pi is aarch64 / glibc 2.36. Build on the Mac with `cargo-zigbuild`
(zig is the cross-linker; no VM or Docker needed) and copy the binary over:

```sh
cargo zigbuild --release --target aarch64-unknown-linux-gnu.2.36
scp target/aarch64-unknown-linux-gnu/release/recplay kibo.local:
ssh kibo.local ./recplay
```

This stays trivial as long as dependencies are pure Rust (`evdev`, `hound`,
`reqwest` with `rustls-tls`, …). Crates that link Linux C libraries
(`alsa`/`cpal`, `openssl-sys`) would need a real cross-sysroot — avoid them.

## Roadmap

**Current focus: the sound pipeline.** The goal is a push-to-talk loop
between kibo and an AI:

1. **Bluetooth joystick as trigger** — pair a BT gamepad with the Pi; a button
   press (via `evdev`/`/dev/input`) starts and stops recording.
2. **Record** — capture mic audio through the default ALSA device
   (`arecord` or `pyaudio`/`sounddevice`) into a WAV per press.
3. **Transcribe** — ✓ done. Each saved clip goes to Gemini
   (`gemini-3.5-flash` via the interactions API, curl as HTTP shim) and the
   transcript lands in `turns.jsonl` as a durable record; failures are
   durable `transcript_error` records and retry on next startup. Silent
   (peak-0) clips are never sent — Gemini hallucinates speech from silence.
   Needs `GEMINI_API_KEY` in `.env` (gitignored; deploy.sh pushes it to the
   Pi, systemd loads it).
4. **Respond** — ✓ done. Press the AI button and all transcripts since the
   last reply become one user turn; `gemini-3.5-flash` writes the reply
   (conversation memory is server-side via `previous_interaction_id`, with
   fresh-conversation fallback if the chain expires), the reply text is
   durable in `turns.jsonl` *before* TTS runs, then
   `gemini-3.1-flash-tts-preview` (voice Kore, 24kHz PCM — little-endian
   despite the `audio/l16` label) speaks it. Voiceflow-style playback:
   holding record pauses speech instantly and resumes from the same position
   after the clip saves; pressing the AI button while kibo talks skips the speech.
   Future: streaming TTS (`"stream": true`, `step.delta` events) for lower
   latency on long replies.

Later / maybe: face animation on the display and servo motion synced to the
conversation, depending on where the embodiment lands after the re-print.

## Notes

- Nothing on the Pi is under version control yet; this repo is the source of
  truth going forward. Other scripts still only on the Pi: `body.py`,
  `reactive.py`, `bouncer.py`, `choreograph.py`, `servo_controller.py`, and
  the audio-choreography files (`*.choreo.json`).
