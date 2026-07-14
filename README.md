# kibo

A Raspberry Pi voice/AI companion project. This repo is the working notebook:
code pulled off the Pi, hardware setup notes, and the plan for where it's
headed. The core idea is the push-to-talk AI loop (see Roadmap); the robot
embodiment (3D-printed body, servos, animated face) is the current form
factor but may change — the body needs a re-print and the robot part may not
survive long-term.

The Pi is reachable on the local network as `kibo.local` (ssh).

## Hardware

- **Raspberry Pi 4 Model B Rev 1.4** — Debian 12 (bookworm), Python 3.11.2
- **240×320 ILI9341 SPI display** — renders the animated face
  (backlight on GPIO18, CS on CE0, DC on GPIO25, RST on GPIO24)
- **USB speaker + microphone** — enumerates as `AIRHUG 01` (`2f9d:320a`),
  ALSA card name `A01`; both playback and capture on the one device
- **Servos** — driven via `servo_controller.py` / WiringPi on the Pi
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
3. **Transcribe** — ship each recording to a speech-to-text API and log the
   transcript.
4. **Respond** — feed transcripts to an LLM and speak the reply back through
   the USB speaker (TTS).

Later / maybe: face animation on the display and servo motion synced to the
conversation, depending on where the embodiment lands after the re-print.

## Notes

- Nothing on the Pi is under version control yet; this repo is the source of
  truth going forward. Other scripts still only on the Pi: `body.py`,
  `reactive.py`, `bouncer.py`, `choreograph.py`, `servo_controller.py`, and
  the audio-choreography files (`*.choreo.json`).
