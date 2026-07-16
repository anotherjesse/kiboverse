# kibo server design: turns as a service

*Research + design doc, 2026-07-14. Produced by a Fable research agent with a
codex (GPT-5.6) cross-check. Sources: `recplay/src/bin/ptt.rs`, `voiceflow.md`,
`~/lw/voiceflow/VoiceFlowBackend` (job store, watch-companion notes),
iroh.computer / n0-computer GitHub (verified via web research July 2026).*

## 1. Recommended architecture

> **Current deployment boundary:** this section describes the target
> architecture, not what `deploy.sh` installs today. Its fixed target is the
> office development Pi; that hardware has not moved to the bedroom and is not
> a production deployment. Its service is still the legacy `recplay`/`ptt`
> binary, whose local flat `turns.jsonl` is its authority. It does not upload to
> or coordinate with `kibod`. `kibod` is a separate local/server runtime until
> the Pi-client migration below is shipped.

**A transport-agnostic turn protocol served by a boring Rust server (`kibod`:
axum + tokio, pure-Rust stack), reachable over a Tailscale tailnet. Thin
clients: Pi (Rust), iPhone/iPad (Swift/URLSession), Watch (via the iPhone).
iroh becomes an optional second transport adapter later, not the foundation.**

### What runs where

| Component | Owns |
|---|---|
| **kibod** (Rust server; starts on the Pi, later a Mac mini/VPS) | `turns.jsonl` (sole writer), `clips/`, `tts/`, all Gemini calls (transcribe / chat / streaming TTS), startup recovery scan, retry, event fan-out |
| **Pi client** (slimmed ptt.rs) | joystick, arecord/aplay shims, chimes, **local durable spool**, upload/playback over HTTP |
| **iPhone/iPad app** (Swift) | record (AVAudioRecorder), gestures, local durable spool, playback with pause/rewind/skip |
| **Watch app** | record locally, ship via WatchConnectivity to the iPhone, which proxies (voiceflow's watch-companion design) |

### Durability: the invariant moves to two places

- **Edge invariant (unchanged):** a client finalizes the clip on its own disk
  *before any network work* and keeps it until the server acknowledges.
  Connectivity affects latency, not safety — a dead server never loses a
  thought.
- **Server invariant (today's rules, relocated):** blob fsync'd + renamed
  before its metadata record; `reply` record appended before TTS starts;
  `transcript_error`/`tts_error` are durable records; on boot kibod rescans
  `turns.jsonl` and resumes unfinished work (exactly `untranscribed_clips()`
  today).

### Storage mapping

```
kibo-data/
  turns.jsonl                  # same append-only log, same record kinds; kibod is the ONLY writer
  clips/recording-<clip_id>.wav
  tts/tts-<turn_id>.wav        # + .part while synthesis streams in
```

The server assigns each appended record a monotonic `seq` (line index works).
`seq` is the replay cursor. Existing records/files migrate as-is; clip IDs
become client-minted UUIDs (voiceflow rule: UUID minted at stop time, shared
by blob and record).

### Protocol sketch (HTTP/1.1 + one WebSocket, all idempotent)

- **`PUT /v1/clips/{clip_id}`** — WAV body; headers `X-Duration-Ms`,
  `X-Peak-Pct`, `X-Recorded-At`, `X-Content-Sha256`. Server: temp write →
  fsync → verify hash → rename → append `clip` record → schedule
  transcription. Re-PUT of the same id+hash returns 200 (client retry-safe);
  same id different hash → 409. Whole-file upload; clips are ≤ a few MB, no
  resumable-range machinery needed.
- **`POST /v1/turns`** — `{turn_id}` = the "AI's turn" gesture. Idempotent by
  `turn_id` (the VoiceFlowBackend `create_or_get` job-store pattern, ported).
  Server bundles clips-since-last-reply, waits briefly for transcripts,
  chats, **appends `reply` before TTS**, then synthesizes.
- **`GET /v1/events?after=<seq>`** — authoritative catch-up: all records with
  `seq > cursor`. This is how an offline Watch/phone resyncs; the log *is*
  the API.
- **`WS /v1/events`** — same records pushed live to all connected clients
  (transcript ready, reply text, speech ready). Notification-grade only:
  client persists its cursor after applying, and any gap falls back to the
  GET. Duplicates harmless.
- **`GET /v1/turns/{turn_id}/speech?from_sample=N`** — chunked-transfer
  **raw PCM** (24 kHz mono s16le; headers carry rate/format). While synthesis
  is in flight, the response streams deltas as they arrive from Gemini
  (server adds ~one tailnet RTT to today's ~1s time-to-first-sound); after
  completion it serves the saved WAV. **Pause/rewind/skip stay entirely
  client-side** — today's `AudioStream` + `Player` move to the client
  verbatim, reading HTTP chunks instead of an in-process `Vec<i16>`; rewind
  is a local position decrement, reconnect resumes `from_sample`.
- **`GET /v1/clips/{clip_id}/audio`** — fetch any clip (other clients
  replaying history).
- Later, optional: `WS /v1/clips/{clip_id}/stream` for live mic streaming
  with an explicit final commit `{ms, peak, sha256}` — an optimization, never
  the durability path. The Pi's save-then-upload already meets the doctrine.

Keeping audio on chunked HTTP (not the event WS) means audio backpressure can
never delay state events.

Auth: none needed on the tailnet initially; add a bearer device-token when/if
a public endpoint appears (Watch-direct requires this).

## 2. The iroh verdict

**Can it do the streaming stuff? Yes — unambiguously.** As of iroh 1.0.0
(June 2026; wire-stable across v1), connections expose quinn-style
`open_bi`/`accept_bi`/`open_uni` plus unreliable datagrams. TTS at 24 kHz s16
is 48 KB/s (120 KB/s at 2.5× delivery) — trivial for a QUIC stream; n0 itself
ships RTP-over-QUIC (iroh-roq) and Media-over-QUIC (iroh-live) as iroh
protocols. A persistent kibod endpoint dialed by EndpointId from clients is a
supported, standard pattern.

**What it buys:** dial-by-ed25519-key with ~90% direct hole-punched
connections and free (rate-limited, no-SLA) public relays — i.e., NAT
traversal *without Tailscale on every device*, e2e encryption by
construction, self-hostable relay/DNS control plane, and content-addressed
audio via iroh-blobs (BLAKE3 verified streaming, range requests — genuinely
nice fit for immutable clips/TTS).

**What it costs:**

- **iroh-blobs 0.103 and iroh-gossip 0.101 are explicitly "not production
  quality" per their own READMEs — and neither is in the Swift FFI.** So on
  iOS you'd hand-roll blob transfer and event fan-out over raw streams
  anyway, which is… the protocol above, minus HTTP's tooling.
- **watchOS: zero support.** iroh-ffi 1.0 (UniFFI Swift bindings, June 2026)
  targets iOS 17.5+/macOS 14.5+ only; no watchOS slice. The Watch is a
  phone-proxy client in *every* design, so iroh can't cover the full client
  matrix.
- Gossip is best-effort, online-only, no persistence, 4 KB caps — wrong tool
  for durable turn events regardless.
- Ecosystem/learning-curve risk, plus a heavier dependency on the Pi client
  (verify `zigbuild` still cross-compiles cleanly with iroh's crypto stack —
  today's build is four pure-Rust crates).
- It doesn't remove the server. You still need an always-on node owning the
  durable store; iroh only changes how you address it.

**Recommendation: against iroh as the foundation, for iroh as a phase-4
adapter.** The medium bias is not misplaced — iroh 1.0 is real, streams fit,
Delta Chat ships it on iOS in production — but its two distinctive components
for this design (blobs, gossip) are the two immature ones, and the platform
that most needs help (watchOS) is the one it can't reach. Tailscale already
delivers the NAT story for Pi/iPhone/iPad/Mac. Because the protocol above is
transport-agnostic (idempotent messages + byte streams), mapping it onto one
versioned ALPN with `open_bi` later is a contained experiment, not a rewrite
— that's the honest on-ramp for the bias.

## 3. codex's opinion (GPT-5.6, high reasoning)

*Process note: the first consult timed out mid-web-research; interim notes
already read "Swift bindings iOS/macOS only, no watchOS; blobs/gossip missing
from FFI; QUIC streams fine." Re-run once with the verified iroh facts
inlined; it converged.*

**codex's verdict:** HTTP+WebSocket as the durable baseline; "HTTP/WS is the
system architecture; iroh is an optional optimized transport, not the durable
substrate." Do not put iroh-blobs/gossip in the correctness path. Protocol:
idempotent `PUT` clips with hash verification, submit-once turns by
`turn_id`, cursor-tagged events with `GET /events?after=` as authoritative,
TTS as chunked PCM indexed by sample offset with all pause/rewind/skip
client-side, audio never multiplexed with events.

**codex's top 3 risks:** (1) turns.jsonl becomes a concurrent database —
serialize to one writer now, plan SQLite/Postgres; (2) streaming recovery is
deceptively complex — explicit offsets, hashes, commit records, client
retention until ack; (3) two transports split semantics — define one protocol
+ test suite first, treat HTTP and iroh as adapters.

**watchOS (codex):** URLSession (incl. WebSocket) works but only with
foreground/extended-runtime execution; no durable background connections;
phone owns the long-lived connection when reachable, watch falls back to
direct foreground HTTPS; never treat WatchConnectivity `sendMessage` as a
durable transport.

**Fable agent's agree/disagree:** agrees with everything structural — codex
independently landed on the same architecture, and risks 2 and 3 are the
sharpest content (risk 3 is the strongest argument for writing the protocol
down before any iroh experiment). Differs on: (a) SQLite urgency — at kibo's
scale (one user, single-writer server) append-only JSONL *is* the design
doctrine, not a liability; revisit only if querying/compaction needs appear.
(b) Content-Range resumable uploads are over-engineering for ≤5 MB clips;
idempotent whole-file PUT + retry suffices. (c) The "separate WebSocket for
TTS" concern is better solved by not using a WebSocket for audio at all
(chunked GET, above).

## 4. Migration path (each phase ships)

**Phase 1 — split in place (small).** Carve ptt.rs into `kibod` (axum, owns
`kibo-data/` + the whole AI pipeline — `gemini()`, `transcribe`, `chat`,
`tts_stream`, recovery scan move over nearly verbatim) and a thin `ptt`
client (joystick, arecord/aplay, local spool, HTTP). Both run on the Pi over
localhost. Zero new infra, behavior identical, protocol proven end-to-end.
Client stays dependency-light (`ureq` w/ rustls; events via long-poll) so the
zigbuild cross-compile stays trivial.

**Phase 2 — server leaves the Pi.** Move kibod + `kibo-data/` to an always-on
box on the tailnet; add `WS /v1/events` + cursor catch-up; Pi client gains
offline spool-and-retry (it already saves locally first, so this is a retry
loop, not a redesign). Kill-the-wifi drills from voiceflow's test plan become
the acceptance tests.

**Phase 3 — iPhone/iPad app.** SwiftUI push-to-talk client: hold-to-record →
local save → PUT; AI button → POST turn; event stream renders the
conversation; TTS playback ports the Player semantics (pause on record,
resume rewound 1s, skip). Mock seam: point it at kibod in a canned-responses
mode.

**Phase 4 — Watch + (optionally) iroh.** Watch companion via WatchConnectivity
through the iPhone (design already exists in the voiceflow repo). Separately,
if tailnet friction or sharing-beyond-the-tailnet motivates it: an iroh ALPN
adapter speaking the same protocol over `open_bi` for Pi↔server and
iPhone↔server, measured against the HTTP path before adopting.

## 5. Open questions

1. **Where does kibod live long-term** — the Pi itself, a Mac mini at home,
   or a $5 VPS? (Decides whether the Watch can ever talk direct-HTTPS, and
   whether real auth is needed.)
2. **Is Tailscale-on-every-device acceptable**, or is "no VPN, dial by key" a
   real goal? That's the one requirement that would justify promoting iroh
   from phase 4.
3. **Who speaks?** When the iPhone asks a question, does the robot also play
   the reply, or only the asking device? (Affects whether `speech ready`
   events auto-trigger playback per device.)
4. **Should conversation memory move into kibod** (rebuild context from
   turns.jsonl) instead of Gemini's `previous_interaction_id`, making the
   store the single source of truth and the provider swappable?
5. **Watch ambition:** phone-proxy companion (cheap, designed already) or
   standalone-capable over public HTTPS (auth + hosting work)?
   → *Answered same day: companion app (see addendum).*

---

# Addendum (2026-07-14): two proposals, Watch as companion

Follow-up after Jesse's push-back. Two decisions reframe the analysis:

**Decision 1 — the Watch is a companion app.** The iPhone does the
streaming/sending/receiving on the Watch's behalf over WatchConnectivity.
This was verified to be forced anyway: Tailscale has no watchOS client
([platforms](https://tailscale.com/kb/1020/install-ios) cover macOS/iOS/tvOS
only), and Watch traffic proxied through the paired iPhone does **not**
traverse the phone's VPN tunnel (a known gap — e.g.
[plappa #276](https://github.com/LeoKlaus/plappa/issues/276) hits exactly
this with a tailnet media server). So no design gets a tailnet Watch;
standalone Watch would require a public HTTPS endpoint (Tailscale Funnel or
VPS) regardless of transport.

**Consequence:** watchOS coverage stops being an argument against iroh — the
platform iroh can't reach was never reachable directly anyway. The remaining
iroh costs are real but smaller: iroh-ffi maturity on iOS (shipping in Delta
Chat, so viable) and hand-rolling blob/event patterns over raw streams.

Both proposals share everything from §1: the same idempotent turn protocol,
the same storage layout, the same durability invariants, the same thin
clients, and an identical Phase 1 (split kibod out of ptt.rs over localhost).
The choice is *transport and reachability only*, and it can be deferred until
the end of Phase 1.

## Proposal A — tailnet-first (boring core)

- kibod serves HTTP/1.1 + WS on the tailnet. Pi, iPhone, iPad, Mac join the
  tailnet and speak plain HTTPS/URLSession — zero exotic dependencies.
- Watch companion: the iPhone app proxies — forwards Watch clips up
  (WatchConnectivity `transferFile`, which is queued/durable, never
  `sendMessage`), pushes transcripts/replies down, and can hand the Watch
  short TTS audio files for local playback.
- Optional later: Tailscale Funnel exposes kibod as public HTTPS with a
  device bearer token → standalone-Watch and share-with-friends both become
  possible without a VPS.
- Cost: Tailscale required on every non-Watch device. Risk: near zero.

## Proposal B — iroh-first with an HTTP gateway sidecar

- kibod's core is transport-agnostic; it mounts **two front doors in one
  process**: an iroh endpoint (one versioned ALPN; each protocol message /
  audio stream maps to an `open_bi` stream) and a thin axum HTTP gateway
  exposing the identical §1 endpoints.
- Pi client and iPhone/iPad (iroh-ffi Swift) dial kibod by EndpointId — no
  VPN anywhere, ~90% direct hole-punched connections, e2e encrypted, works
  from any network.
- The HTTP gateway serves everything iroh can't: the Watch path (via the
  iPhone companion — which may itself choose either transport), curl/browser
  debugging, and any future client without iroh bindings. Bound to
  localhost/tailnet initially; Funnel-able later.
- Cost: two front doors to keep in sync (mitigated: both are thin adapters
  over one core because the protocol is transport-agnostic — codex's risk #3
  says build the shared protocol test suite first, which applies doubly
  here), iroh-ffi Swift on iOS as a load-bearing dependency, heavier Pi
  binary (verify zigbuild × iroh's crypto stack early).
- Buys: no Tailscale on phones/iPads, dial-by-key identity, and the iroh
  itch scratched properly rather than as a bolt-on.

## Choosing

| | A: tailnet | B: iroh + gateway |
|---|---|---|
| New moving parts | ~0 | iroh endpoint + FFI + gateway |
| VPN required | every device but Watch | none |
| Works off-tailnet (friend's house, LTE) | only via Funnel | yes, natively |
| Watch story | identical (companion) | identical (companion) |
| Risk if iroh ecosystem shifts | none | contained to adapters |
| Phase 1 | identical | identical |

### Client stack note: Tauri (2026-07-14)

If Proposal B wins, the iPhone/iPad app can be **Tauri 2** (stable iOS
support: Rust core + WKWebView UI). That changes B's economics: the app's
Rust core compiles directly for iOS, so the `iroh` crate is used natively
and **iroh-ffi/UniFFI drops out of the design entirely** (Delta Chat ships
exactly this shape — Rust core with iroh, on the App Store). The Pi client
and the phone app can share one Rust client crate: protocol client,
spool-then-upload durability, AudioStream + Player pause/rewind/skip.

The risk moves from networking to audio: mic capture and streamed-PCM
playback go through either WKWebView web APIs (getUserMedia / AudioWorklet),
`cpal` (CoreAudio) on the Rust side, or a small Swift Tauri plugin over
AVFoundation — spike this first, it's the Tauri analog of "can iroh
stream?". Background/lock-screen audio needs the usual AVAudioSession +
entitlement work via plugin. The Watch companion stays native SwiftUI either
way (no Tauri for watchOS): a watchOS target added to the Tauri-generated
Xcode project plus a WatchConnectivity Swift plugin on the iOS side.

Recommendation: still start with A's shape — but B is now a legitimate
endgame rather than a consolation phase-4 experiment. Concretely: Phase 1
unchanged; build the protocol test suite against the HTTP front door; decide
A-vs-B at Phase 2 by answering one question — *"do I actually mind installing
Tailscale on the phones?"* If yes, B; if no, A and keep B's adapter as the
someday-option. Either way the Watch companion work (Phase 4) is unaffected.
