# ReSpeaker Lite Kibo client

This is a bounded-memory standalone client for the ReSpeaker Lite Voice
Assistant Kit with its pre-soldered XIAO ESP32-S3. It records processed
microphone audio, streams independently acknowledged WAV parts to `kibod`,
commits them as one pending note on release, and lets a separate ASK action
submit all waiting notes and play Kibo's streamed reply.

The current bench defaults are:

- `http://192.168.86.27:3003`
- project `kibo`
- conversation `general`

They can be changed over serial and persist in ESP32 NVS. Tailscale is not
needed while the Mac and device are on the same LAN.

## Safety and current scope

- The original 8 MiB XIAO flash should be backed up before uploading this
  firmware. The full image can be restored at address `0x0` with `esptool.py`.
- Capture rotates through four 20-second PSRAM buffers. A background task sends
  each full WAV part while the microphone continues filling another buffer, so
  total recording duration is not capped by PSRAM. There is intentionally no
  offline queue or SD-card spool yet.
- An acknowledged part is durable but hidden on the Mac until release commits
  the complete recording. If all four buffers fill before uploads catch up, the
  device reports an overflow, plays a distinct descending failure cue, and does
  not commit a silently truncated clip.
- Once completion succeeds, the pending clip survives an ESP32 reset. The ID
  of an ASK whose reply has not played is RAM-only.
- Nothing records automatically at boot. A serial command or button press is
  required.
- The XMOS firmware is not changed. This board is already known to work with
  its 16 kHz I2S image: XU316 clock master, 32-bit stereo, processed ASR audio
  in channel 0.

## Build, upload, and monitor

From the repository root:

```sh
pio run -d respeaker
pio run -d respeaker -t upload --upload-port /dev/cu.usbmodem1101
pio device monitor --port /dev/cu.usbmodem1101 --baud 115200
```

If upload cannot connect, hold BOOT, tap RESET, release BOOT, and retry.

## First-time provisioning and bench test

In the serial monitor:

```text
wifi YOUR_SSID YOUR_PASSWORD
status
mic
chime
volume 25
record
record 60
ask
```

The password is stored in the ESP32's NVS and is never echoed or present in a
tracked file. `status` GETs `/v1/projects`; `mic` records for three seconds and
only reports its level; `chime` plays a speaker-volume test; `record` captures for
four seconds and queues only that note; `record 60` captures an exact 60-second
hardware-test sample; `ask` submits every note waiting in the selected
conversation and plays the reply. `test` remains an end-to-end
shortcut which does `record` followed by `ask`.

Speaker output defaults to 25% (about -12 dB relative to the unscaled stream).
Use `volume` to show it or `volume 0` through `volume 100` to change it. The
setting is stored in ESP32 NVS and applies to Kibo speech and local cues.

Other commands:

```text
server http://192.168.86.27:3003
target kibo general
xmos
test
forget
play 65efb508-8e04-4ece-96cc-b85a4244a570
tone
clearwifi
help
```

The simple `wifi` parser expects an SSID without spaces. This is sufficient for
the current bench network; a captive portal or quoted parser can replace it.
If a turn contains no recognizable speech, `kibod` currently leaves its speech
endpoint at `425`; the client gives up after 60 seconds instead of waiting
forever. It retains that turn ID in RAM so another ASK retries the same reply;
`forget` intentionally abandons it.

## Buttons

The intended controls use both existing ReSpeaker buttons:

- Hold **USR** to record. Full 20-second parts upload while the button remains
  held; release commits them as one pending note. Repeat this as
  many times as desired; recording does not ask Kibo. A rising two-note cue
  finishes before capture begins, and a falling cue sounds just after release,
  while the final upload drains and before completion.
- Tap **MUTE** to ASK. On release, the firmware submits all pending notes in the
  selected conversation and plays the answer.
- XIAO **BOOT/GPIO0** remains a no-solder hold-to-record fallback.

The two button signals are not connected to the XIAO at the factory. Add the
two bridges shown in [Seeed's solder-pad photo](https://files.seeedstudio.com/wiki/SenseCAP/respeaker/usr.png):

1. Bridge `USR/BUT_A` to `D2` (ESP32-S3 GPIO3).
2. Separately bridge `MUTE` to `D3` (ESP32-S3 GPIO4).

Do not bridge D2 and D3 to each other. Short insulated wires are also fine if
that is easier than forming solder blobs.

MUTE is still hard-wired to the XMOS chip, so a physical tap briefly toggles
the hardware microphone mute. The firmware waits for release, reads the XMOS
mute register, and if it is now muted pulls GPIO4 low **open-drain** for 300 ms
to toggle it back. The microphone is therefore left unmuted and this firmware
treats the key as ASK, not as a privacy control. Its red mute indication may
flash briefly. A GPIO interrupt also latches a quick ASK tap made during a
recording, upload, or playback; multiple such taps coalesce into one ASK. During
capture, a timed open-drain state machine restores each hardware-mute toggle
while I2S capture keeps running, then the latched ASK runs after completion. The
`xmos` command reports the final mute state.

## Audio and API path

Capture is 16 kHz mono signed-16 WAV derived from the left/ASR slot of the
XMOS 32-bit stereo stream. Each known-length part is sent to
`/recordings/{id}/parts/{sequence}` with `X-Content-SHA256`, `X-Sample-Count`,
and `X-Peak-Pct`; failed uploads retry three times with identical bytes, ID,
and sequence. Release waits for acknowledgements and posts one completion with
the part count and exact total sample count. ASK uses one idempotent turn ID and
retains it in RAM across ambiguous request or playback failures. Kibo's 24 kHz
mono signed-16 chunked reply is decoded by ESP-IDF's HTTP client, resampled to
16 kHz, expanded to 32-bit stereo I2S, and sent to the onboard speaker codec.

The server is authoritative about what is pending. ASK claims every unclaimed
clip in the selected conversation at that instant, including clips uploaded by
another client using the same project/conversation. After three unconfirmed
upload attempts, the recording is aborted without completion; an ambiguous
attempt may leave invisible staged parts on the server. There is no
reboot-persistent device-side retry yet—that is the deliberate pre-SD-card
limitation.

An unconfirmed completion is also ambiguous: the server may already have
committed the recording, or it may still have only the invisible staged parts.

## Restore the saved XIAO image

With the XIAO USB-C connected and the board in download mode if necessary:

```sh
python /Users/jesse/.platformio/packages/tool-esptoolpy/esptool.py \
  --chip esp32s3 --port /dev/cu.usbmodem1101 --baud 921600 \
  write_flash 0x0 /path/to/respeaker-xiao-factory.bin
```

The XMOS image is a separate device on the other USB-C connector and is not
touched by either the upload or restore commands above.
