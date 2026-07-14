# voiceflow — study notes for kibo

Notes from reading `~/lw/voiceflow`, a voice-first thought-capture app for
iPhone/Mac (Swift/SwiftUI, with an optional Elixir/Phoenix backend). It's the
closest prior art to what kibo's sound pipeline wants to be, and its design
docs — especially `durability.md` — are a manifesto for the principle kibo
should adopt wholesale: **NEVER LOSE USER DATA**.

## What it is

Record a short spoken clip → transcribe it → the clip becomes a "turn" in a
conversation → on explicit request, an LLM replies → the reply is spoken back
via TTS. The docs stress it is *not a chat client*: it's a thought-capture /
rubber-duck tool for moments when a keyboard is inconvenient. That's kibo's
use case too.

## The interaction model (this is kibo's two buttons)

The load-bearing design decision: **capturing a clip and asking the AI are
two different user actions.**

- **Hold to record, release to save.** Each finished clip is durable
  immediately and transcribes in place. Releasing does *not* ask the AI.
- **A separate explicit gesture (swipe-up) means "AI's turn to answer."**
  One ask = one *turn*, and it bundles **all** clips recorded since the last
  assistant reply. Turns are explicit records, never inferred from adjacency.
- Swipe-left while holding = cancel the clip.
- Clips shorter than **0.5 s are discarded** (accidental taps).

Mapped to the 8BitDo Micro:

| voiceflow gesture | kibo button |
|---|---|
| hold button = record, release = save clip | hold button A |
| swipe-up = "AI turn to answer" | press button B |
| swipe-left = cancel clip | (maybe a third button, or hold B) |

Nice subtlety worth copying: when the user asks, the app **snapshots the
system prompt/context onto the turn at ask-time**, so config changes can't
retroactively alter an in-flight answer.

## NEVER LOSE USER DATA — the durability invariants

From `durability.md` (written after one evening of real use lost recordings
and burned trust — "after a recording stops, the user should be able to
assume their thought is safe, even if everything else goes wrong"):

1. **Recording durability** — once stop returns, the clip survives relaunch.
2. **Send durability** — an asked turn survives even if transcription, LLM,
   or TTS never finished.
3. **Processing is replayable** — on startup, scan durable state and decide
   what's complete / waiting / needs retry. Never trust in-memory task state.
4. **Connectivity affects latency, not safety** — network loss never deletes
   captured data.
5. **Errors are durable states**, not transient UI messages
   (`transcription failed`, `reply failed`, `tts failed` are persisted, with
   `retryCount` / `lastAttemptAt` / `nextRetryAt`).
6. **Turn identity is explicit** — real turn records, not array positions.
7. **Deletion is recoverable** — soft-delete / trash, never destructive.

And the persistence rules that implement them:

- **Rule 1: save before async work.** No API call starts until the durable
  record is written. In code: recording stops → file moved to stable name →
  metadata record saved → *only then* is transcription scheduled.
- **Rule 2: persistence errors are surfaced**, never silently swallowed.
- **Rule 3: incremental updates**, not whole-conversation rewrites.
- **Rule 4: coordinate blob + metadata writes.** Finalize the audio file,
  then write metadata; if the metadata write fails, retry or move the file
  to an orphan-recovery bucket — never silently drop it.

Supporting mechanics:

- **UUID minted at stop time**, used as both the record ID and in the
  filename (`recording-<uuid>.m4a`) so blob and metadata cross-link.
- **Atomic writes** for every generated file (TTS output, etc.).
- **Raw audio is kept after transcription** (replayable later; transcripts
  are lossy).
- **Reply text is durable independent of reply audio** — a TTS failure never
  destroys the generated answer; it's a `speechFailed` state on an otherwise
  complete turn.
- **Failed transcriptions never leak sentinels** like "[Transcription
  failed]" into LLM history — history is projected only from
  LLM-eligible states.

## State machine

Three **separate** state enums instead of one overloaded status, so failures
are precise:

- Turn lifecycle: `draft → transcribingDraft → queuedForReply →
  generatingReply → replyTextReady → generatingSpeech → complete`
  (plus `draftFailed / replyFailed / failed / deleted`).
- Clip transcription: `notRequested → queued → transcribing → complete/failed`.
- Reply generation: `notRequested → queued → generating → textReady →
  generatingSpeech → complete` (plus `speechFailed / failed`).

The architecture is four steps: **(1) persist the raw clip immediately,
(2) persist workflow state for the turn, (3) project persisted state into
what the UI shows, (4) on startup/wake, resume unfinished work from storage.**
The UI layer is always a *projection* of durable records — there's no global
mutable "placeholder" state.

Startup/foreground recovery (`resumeDurableWork()`): requeue failed clips,
re-launch transcription for anything found `queued`/`transcribing` in
storage, and process the next pending reply. This is exactly what kibo's
daemon should do on boot.

## AI integration & the mock seam

- Transcription: Gemini `generateContent` with inline base64 m4a, temp 0,
  system instruction "Return only the transcript… If unclear, return
  [inaudible]."
- Reply: OpenAI Responses API or Gemini, selectable; persona prompt tuned
  for being *listened to*: "concise, natural, easy to listen to aloud."
- TTS: OpenAI `audio/speech` → mp3, written atomically.
- **The seam kibo wants for "simulate the AI":** every service first checks
  for an optional `BackendClient` (nil if no base URL configured). All AI
  work can be routed through a tiny JSON HTTP contract
  (`/api/transcriptions`, `/api/replies`, `/api/speech`, `/api/jobs/*`).
  Point that at anything — including a fake server returning canned
  responses — and the whole pipeline runs with no real AI.
- The backend job store is **idempotent, keyed by turn ID, persisted to a
  JSON file**: resubmitting the same turn returns the existing job instead
  of duplicating work. Submit-once / poll-after-reconnect — ideal for a Pi
  with flaky Wi-Fi.

## Audio details

- Format: AAC in `.m4a`, 44.1 kHz mono, high quality. (On the Pi we'll
  likely record WAV via ALSA and optionally compress after the durable save.)
- **Recorder pre-warming**: the next recorder is created and prepared ahead
  of time so pressing record is near-instant. Re-warmed after every
  finish/cancel. kibo equivalent: keep the capture pipeline open or
  pre-opened so button-press latency is ~0.
- If a reply is playing when recording starts, playback pauses with a
  snapshot and resumes afterward, rewound ~1 s.

## What kibo should steal (design commitments)

1. **Persist before async work — inviolable.** Button release → WAV
   finalized under `recording-<uuid>.wav` + metadata row written → only then
   any network call. Kill the process anywhere; the thought survives.
2. **Two buttons, two meanings.** Hold-A records clips (each saved
   immediately); press-B = "AI's turn," bundling all clips since the last
   reply into one explicit turn.
3. **Three state enums** (clip / transcription / reply), errors as durable
   states with retry metadata.
4. **Boot-time recovery loop** that rescans storage and resumes queued or
   half-done work.
5. **Keep raw audio forever** (or until explicit, soft, delete).
6. **Mock-AI seam from day one**: a service interface whose fake
   implementation returns canned transcripts/replies, so the
   record→turn→reply loop is testable with zero API keys.
7. **Idempotent job keys** (turn UUID) on anything sent to a server.
8. **Min-duration discard** (~0.5 s) to eat accidental button taps.

## Also relevant in that repo

- `swift-iphone-m5.md` — an older plan for pairing an **M5StickC hardware
  button over BLE** as a record trigger (presents as a BLE media remote).
  Directly analogous to the 8BitDo-on-Pi idea; its "Phase 0" is the minimal
  no-persistence record→transcribe→TTS loop, a good shape for kibo's first
  spike — just with the durable-save rule added from the start.
- `ConversationStoreDurabilityTests.swift` — ~690 lines of tests that drive
  the state machine and assert the invariants (reply text survives TTS
  failure, no sentinel leaks, soft-delete stops recovery, etc.). The
  durability doc's testing plan enumerates the exact failure drills kibo
  should reproduce: record → kill → relaunch → clip present; ask while
  transcribing → relaunch → turn present; each pipeline stage fails without
  destroying upstream data.
