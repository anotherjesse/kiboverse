# Kibo UI/UX Redesign — Goal Spec

## Goal

Rebuild the iOS and watchOS view layer around ONE mental model: **choose a
conversation, then talk into it** — with an explicit, immersive push-to-talk
(PTT) mode as the second, deliberate way to use the app. Unify branding (the
coral + white-bunny identity from the app icon) across both platforms, make
the recording state unmistakable, and keep every piece of existing plumbing
(AppStore, WatchStore, AudioCoordinator, WatchAudioCoordinator, spool, API)
working.

A fresh observer given only screenshots and the hint "voice-first personal AI
tool, power-user app, hold-to-talk exists" must be able to correctly describe
how the app works. Power-user means: no tutorial copy (no persistent "Hold
the button while you speak"), but every control's *purpose* must be legible
from its presentation. The UI must match what the code actually does.

## Current problems (verified in simulator, July 2026)

1. iOS Talk tab records into a *globally selected* conversation shown only in
   a tiny header row; no feedback where you talk; two parallel selection
   systems (Talk header menus vs Conversations tab) mutate the same state.
2. Conversation detail's composer pushes a SECOND TalkView (with its own
   selection bar) inside the Conversations stack while the tab bar also says
   "Talk" — two instances, wrong containment.
3. Two "Ask Kibo" buttons with different behavior: TalkView's runs the full
   reply lifecycle with speech autoplay; ConversationDetailView's fires
   `store.submitTurn()` bare — no autoplay, and 409s into a modal alert when
   nothing is pending.
4. Visual hierarchy inverted on Talk tab: giant filled "Ask Kibo" bar ABOVE
   the mic, but the actual flow is record first, then ask.
5. Watch: main screen is a scrolling pile — "Ask Kibo"/Retry are below the
   fold on a 46mm Series 11; PTT button itself can scroll away.
6. Branding: watch UI is `.orange`, iOS is `kiboCoral` (0.94, 0.34, 0.29 —
   matches the app icon's coral). Recording pulse is a barely visible 1.07
   scale wiggle.
7. Status is scattered: green/orange dot + status string + modal error alerts
   + per-message retry + settings-sheet recovery UI.

## Target design

### iOS

- **RootView**: drop the TabView. `NavigationSplitView` with sidebar =
  ConversationListView, detail = ConversationDetailView (or a
  ContentUnavailableView placeholder when nothing selected). Keep the idle
  timer behavior and the single global error alert.
- **ConversationListView** (new file, replaces LibraryView.swift): the home.
  Project switcher as a Menu in the header (current project name + folder
  icon; includes "New project…"). Conversation rows: name + relative last
  activity. Toolbar: settings gear, new conversation. Connection state shown
  subtly (small dot or pill ONLY when not "Live" — no permanent status text).
- **ConversationDetailView**: timeline (keep MessageCard look) + redesigned
  composer: a 56–64pt coral hold-to-talk mic circle + an "Ask Kibo" button
  that shows the pending-clip count (e.g. "Ask Kibo · 2") and is visually
  disabled when there is nothing to ask and no ask in flight. Toolbar gets a
  PTT-mode button (waveform or expand icon). Remove the nested TalkView push
  and the bare `submitTurn()` path — submission goes through the shared
  ReplySession (below) so the spoken reply autoplays here exactly like it
  did on the old Talk tab.
- **TalkModeView** (new file): full-screen cover, immersive dark treatment
  (kiboInk gradient), conversation name displayed prominently at top,
  giant mic button center, "Ask Kibo · N" below the mic (flow reads top →
  bottom: destination → talk → ask), one dynamic status line (states only:
  Listening… / Sending… / Loading reply… / Kibo is speaking / errors — no
  persistent instructions), close (X) top corner. Destination is LOCKED —
  no pickers in this screen. Reply autoplay behavior identical to the old
  TalkView.
- **ReplySession** (new file): extract ReplyLifecycle + ReplyAutoplayGate +
  the submit/autoplay orchestration (startSubmitCommand /
  playAwaitedReplyIfReady / cancellation wiring) out of TalkView.swift into
  one reusable component used by BOTH ConversationDetailView and
  TalkModeView. Then delete TalkView.swift. There must be exactly one submit
  code path. When TalkModeView is presented over the detail view, only the
  top screen may autoplay (reuse the overlay gate).
- **Pending clip count**: add an `[KiboEvent]` extension helper (mirroring
  `pendingTurnIDs` in ios/Shared/Models.swift) that counts clips not claimed
  by any turn; surface server-pending + local `pendingUploadCount` sensibly.
- **Pulse**: recording state = red fill + expanding/fading rings (2–3
  staggered rings) + level-driven scale. A single static frame mid-recording
  must read as "recording" (red + visible rings).
- **App Intents** (ios/Kibo/KiboIntents.swift exists with OpenKiboIntent):
  add `TalkToKiboIntent` that opens the app straight into PTT mode for the
  last-selected conversation (router object, e.g. a small ObservableObject
  set by the intent, observed by RootView once the store has restored
  selection). Both intents in KiboAppShortcuts so both appear in the Action
  button picker.
- **Theme**: move `kiboCoral` / `kiboInk` from KiboApp.swift into
  `ios/Shared/Theme.swift` (both targets compile Shared/).

### watchOS

- **Coral branding**: `.tint(.kiboCoral)` app-wide; replace every `.orange`
  in WatchTalkView.swift with the shared theme coral. (The app icon already
  has a watchos entry in Assets.xcassets — verify it still builds in.)
- **Non-scrolling main screen** that fits a 46mm AND 42mm face with NO
  scrolling: compact tappable conversation name at top (→ selection list),
  mic button sized to dominate the center, bottom compact row: "Ask" button
  with pending count + one-line status text. When
  `store.events.retryableFailure` exists, the Retry button takes the Ask
  slot. No persistent instructional copy; the status line shows dynamic
  states only.
- **Pulse**: same clear recording treatment as iOS (red + rings).
- **Selection screen**: keep the list; title must not truncate (rename
  "Talk to…" as needed); current selection clearly marked.

## Non-negotiables (contracts)

- `KiboWatchUITests/WatchPushToTalkTests` must still pass unchanged: it
  needs `watch-talk-button`, `watch-ask-button` accessibility identifiers, a
  hittable talk button, the "Reply played" status text after playback, and
  the absence-check of "Hold a little longer to record." (that string comes
  from the audio coordinator — do not rename coordinator messages).
  Keep `watch-status` and `watch-retry-button` identifiers too.
- `KiboWatchUITests/WatchScreenshotTests` and
  `KiboUITests/ScreenshotTests` may be UPDATED to drive the new UI (the tab
  bar is gone), but must keep attaching the same coverage: home/list,
  conversation detail, PTT mode (new), watch main + selection.
- Do not change: kibod server code, GeneratedAPI.swift, KiboAPI.swift,
  PendingUploadSpool, AudioRecorder/AudioCoordinator/WatchAudioCoordinator
  internals (view-facing published state may be consumed as-is), AppStore /
  WatchStore semantics (adding small read-only helpers is fine).
- All existing unit tests (KiboTests, KiboWatchTests) keep passing.
- Do NOT git commit, do NOT deploy.

## Environment (already set up, July 2026)

- Repo: /Users/jesse/anotherjesse/kibo (iOS app in ios/).
- Regenerate the project after ANY file add/remove/rename:
  `cd ios && xcodegen generate` (Kibo.xcodeproj is gitignored; sources are
  directory-globbed). A test file added after generation silently isn't
  compiled — regenerate BEFORE xcodebuild.
- Booted sims: iPhone 17 Pro (iOS 26.5) `C9655662-DBCE-45D9-9217-849D5666E9EF`,
  Apple Watch Series 11 46mm (watchOS 26.5) `0D200374-23AA-45DB-BC1E-0A78AB0EE89C`.
- Local kibod (mock AI) running at `http://127.0.0.1:3010/` with seeded data:
  project `kibo` → conversation `general-1a467f7b` ("General", has mock
  turns/replies), plus project `garden-0698bbc9`. The iPhone sim's
  `serverURL` default already points at it. If kibod is down, restart:
  `KIBO_BIND=127.0.0.1:3010 KIBO_DATA_DIR=<scratch>/kibo-data KIBO_AI_MODE=mock ./target/debug/kibod &`
- NEVER grant microphone permission to the iPhone simulator — iOS 26.5 sim
  has a CoreAudio lock-inversion bug that hangs Kibo at launch with mic
  granted. It is currently revoked; leave it revoked (recording paths can't
  be exercised in the iPhone sim — that's expected).
- Screenshots: run the UI test, then
  `xcrun xcresulttool export attachments --path <bundle>.xcresult --output-path <dir>`
  (manifest.json maps names). Host-side AppleScript taps are blocked; drive
  UI only from XCUITest.

## Out of scope

- Server/API changes, audio engine changes, complication redesign,
  onboarding flows, iPad-specific layout work (NavigationSplitView's default
  adaptivity is enough).
