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

## Audio setup (done 2026-07-14)

The USB speaker/mic is the **default ALSA device** via `~/.asoundrc` on the Pi.
The card is referenced by name (`A01`) rather than number so it survives
reboot renumbering. `defaults.pcm.card "A01"` fails on this alsa-lib
("card is not a string"), so the config uses an explicit default:

```
pcm.!default {
    type asym
    playback.pcm "plughw:A01,0"
    capture.pcm "plughw:A01,0"
}
ctl.!default {
    type hw
    card A01
}
```

`plughw` gives automatic sample-rate/format conversion. The built-in headphone
jack (`bcm2835 Headphones`, card 0) is still available if addressed explicitly.

Quick tests:

```sh
aplay test.wav                                    # speaker (default device)
arecord -d 4 -f S16_LE -r 44100 /tmp/t.wav        # mic, 4 seconds
aplay /tmp/t.wav                                  # play it back
```

Both directions verified working.

## Repo layout

- `original/` — snapshot of the face-animation scripts as they existed on the
  Pi (`f2.py`–`f9.py` are iterations; `face.py` is the largest/most complete).
  Kept as-is for reference before any refactoring happens here.

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
