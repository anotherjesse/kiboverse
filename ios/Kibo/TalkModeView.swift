import SwiftUI

/// The phone's living constellation. Same organism as the watch — Kibo's face
/// dead center inside a coral state ring, the conversation orbiting as stars,
/// diamonds, and rings — given a bigger sky. Full-screen, ink-dark, immersive:
/// the constellation is the hero and every other element stays quiet.
///
/// One `CenterState` derivation drives all three renderers (status label,
/// face sprite, constellation animation). Hold the face to talk, swipe up to
/// ask — the same shared gesture the watch and composer use.
struct TalkModeView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: AppStore
    @EnvironmentObject private var audio: AudioCoordinator
    @EnvironmentObject private var router: KiboRouter
    @StateObject private var session = ReplySession()

    /// Fed by the shared gesture's `.armedChanged`; drives the excited face,
    /// the "Release to ask" copy, and the armed haptic.
    @State private var swipeArmed = false
    /// Entry animation gate: a quick fade + 0.96→1 canvas scale on appear.
    @State private var appeared = false

    /// Swiping up past this arms release-to-ask — a hand-size fact, larger
    /// than the watch's 30.
    private static let swipeThreshold: CGFloat = 55

    var body: some View {
        // One derivation; the status label, face, and constellation all read
        // it. The old statusLine chain is gone.
        let state = centerState
        return ZStack {
            backdrop
            GeometryReader { geometry in
                let minDim = min(geometry.size.width, geometry.size.height)
                let faceDiameter = min(max(minDim * 0.44, 150), 240)
                ZStack {
                    livingConstellation(
                        geometry: geometry, faceDiameter: faceDiameter, state: state
                    )
                    chrome(geometry: geometry, faceDiameter: faceDiameter, state: state)
                }
            }
        }
        .preferredColorScheme(.dark)
        // Swipe-up-to-ask starts on the face; without this the home indicator
        // claims upward swipes near the bottom of the screen.
        .defersSystemGestures(on: .bottom)
        .replySessionDriver(session)
        .opacity(appeared ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { appeared = true }
        }
        .onDisappear {
            // Errors that occurred here were already shown in the status
            // label; clearing them on the way out prevents the global and
            // detail alerts from re-surfacing them, stale, after dismissal.
            store.errorMessage = nil
            audio.playbackErrorMessage = nil
        }
    }

    // MARK: - Backdrop

    /// Radial ink vignette: `kiboInk` at the center falling to near-black at
    /// the edges. The star field needs true dark to read; the phone keeps its
    /// ink identity in the warm middle.
    private var backdrop: some View {
        GeometryReader { geometry in
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(red: 0.10, green: 0.12, blue: 0.18), location: 0.0),
                    .init(color: Color(red: 0.05, green: 0.06, blue: 0.10), location: 0.45),
                    .init(color: Color(red: 0.012, green: 0.014, blue: 0.024), location: 1.0)
                ]),
                center: .center,
                startRadius: 0,
                endRadius: max(geometry.size.width, geometry.size.height) * 0.72
            )
        }
        .ignoresSafeArea()
    }

    // MARK: - Constellation + face

    /// The face and the constellation Canvas share one centered coordinate
    /// space (the ring/tick geometry is drawn around the Canvas center), lifted
    /// slightly above geometric center so the bottom carries status + actions
    /// with room to breathe. Exactly how the watch composes it, more sky.
    private func livingConstellation(
        geometry: GeometryProxy, faceDiameter: CGFloat, state: CenterState
    ) -> some View {
        let lift = geometry.size.height * 0.055
        return ZStack {
            ConstellationView(
                markers: store.constellationMarkers,
                state: state,
                level: renderLevel,
                faceDiameter: faceDiameter,
                style: .phone
            )
            face(diameter: faceDiameter, state: state)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        .offset(y: -lift)
        // The canvas grows into place on appear (fade lives on the whole view).
        .scaleEffect(appeared ? 1 : 0.96)
    }

    /// The face is the press target. The sprite/pulse is `KiboFace`; the hit
    /// shape, gesture, a11y, and swipe hint are the platform wrapper here.
    private func face(diameter: CGFloat, state: CenterState) -> some View {
        KiboFace(state: state, level: renderLevel, diameter: diameter)
            .opacity(store.selectedConversationID != nil ? 1 : 0.4)
            .contentShape(Circle())
            .overlay(alignment: .top) { swipeHint(faceDiameter: diameter) }
            .sensoryFeedback(.impact(weight: .medium), trigger: swipeArmed)
            .accessibilityElement(children: .ignore)
            .accessibilityIdentifier("talk-button")
            .accessibilityLabel("Hold to talk")
            .accessibilityValue(audio.isRecording ? "Recording" : "Ready")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction {
                if audio.isHolding { session.endHold() } else { session.beginHold() }
            }
            // With no separate Ask button, the swipe gesture needs an
            // accessibility equivalent.
            .accessibilityAction(named: "Ask Kibo") { askKibo() }
            // Shared hold-to-talk semantics; the armed state (feeding the hint
            // and `.sensoryFeedback`) and the askable guard stay here.
            .holdToTalkGesture(swipeThreshold: Self.swipeThreshold) { event in
                switch event {
                case .began:
                    session.beginHold()
                case let .armedChanged(armed):
                    swipeArmed = armed
                case .canceled:
                    session.cancelHold()
                case .saved:
                    session.endHold()
                case .askRequested:
                    askKibo()
                }
            }
            .allowsHitTesting(store.selectedConversationID != nil)
    }

    /// Whether the swipe hint shows, and whether it reads as armed. Live
    /// hold/armed state normally; under the presentation-only UITest override
    /// both derive from the forced state so the screenshots render faithfully:
    /// forced `.recording` shows the "Swipe up to ask" hint, forced
    /// `.swipeArmed` the "Release to ask" armed capsule — neither of which the
    /// mic-revoked sim can produce for real. No audio/store mutation.
    private var hintVisible: Bool {
        #if DEBUG
        if let forced = Self.uiTestOverrideState {
            return forced == .recording || forced == .swipeArmed
        }
        #endif
        return audio.isHolding || audio.isRecording
    }

    private var hintArmed: Bool {
        #if DEBUG
        if let forced = Self.uiTestOverrideState {
            return forced == .swipeArmed
        }
        #endif
        return swipeArmed
    }

    /// Transient, hold-only affordance for the release gesture — appears while
    /// the finger is down and highlights once the swipe is armed. Small and
    /// quiet, riding just above the face so the eye stays on the thumb.
    @ViewBuilder
    private func swipeHint(faceDiameter: CGFloat) -> some View {
        if hintVisible {
            HStack(spacing: 5) {
                Image(systemName: hintArmed ? "sparkles" : "chevron.up")
                Text(hintArmed ? "Release to ask" : "Swipe up to ask")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(hintArmed ? Color.white : Color.white.opacity(0.7))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                hintArmed ? AnyShapeStyle(Color.kiboCoral) : AnyShapeStyle(.ultraThinMaterial),
                in: Capsule()
            )
            .offset(y: -(faceDiameter * 0.5 + 34))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: hintArmed)
            .transition(.opacity)
        }
    }

    // MARK: - Chrome (title, close, status, actions)

    private func chrome(geometry: GeometryProxy, faceDiameter: CGFloat, state: CenterState) -> some View {
        // The status zone hangs off the constellation band, not the screen
        // bottom — status hugging the orbit is the watch's rhythm, and pinning
        // it low left a dead belt under the field. `+ 24` puts the status ~24pt
        // below the drawn outer orbit; the belt now lives below the zone.
        let statusTop = outerOrbitLowerEdge(geometry: geometry, faceDiameter: faceDiameter) + 24
        return VStack(spacing: 0) {
            header
                .padding(.top, 6)
            Spacer(minLength: 0)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
        // The status zone rides a top-anchored overlay padded down to the band,
        // not the VStack bottom — so it hugs the orbit instead of the home bar.
        .overlay(alignment: .top) {
            bottomControls(state: state)
                .padding(.top, statusTop)
        }
        .overlay(alignment: .topLeading) { closeButton }
    }

    /// Screen-y (in the chrome's own coordinate space) of the constellation's
    /// outer orbit lower edge. Mirrors `ConstellationView.draw`'s band math and
    /// `livingConstellation`'s 5.5% lift so the status zone tracks the drawn
    /// orbit on every screen size instead of the home indicator.
    private func outerOrbitLowerEdge(geometry: GeometryProxy, faceDiameter: CGFloat) -> CGFloat {
        let lift = geometry.size.height * 0.055
        let bandCenterY = geometry.size.height / 2 - lift
        let maxRadius = min(geometry.size.width, geometry.size.height) / 2 - 4
        let inner = faceDiameter / 2 + 10
        let outer = max(inner + 8, maxRadius - ConstellationStyle.phone.outerInset)
        let orbitRadius = inner + (outer - inner) * ConstellationLayout.activeOrbit
        return bandCenterY + orbitRadius
    }

    /// The conversation name in the watch's serif small-caps header language,
    /// scaled up, with the project name quiet below it. Dimmed so the
    /// constellation stays the subject.
    private var header: some View {
        VStack(spacing: 5) {
            Text(conversationName)
                .font(.system(size: 17, weight: .semibold, design: .serif).smallCaps())
                .kerning(1.4)
                .foregroundStyle(.white.opacity(0.5))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let project = store.selectedProject {
                Text(project.name)
                    .font(.system(size: 13, weight: .medium))
                    .kerning(0.3)
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        // Clear the close disc so a long name never slides under it.
        .padding(.horizontal, 64)
    }

    private var closeButton: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
                .frame(width: 40, height: 40)
                // The brightest non-face element was too loud: a whisper disc,
                // no material — the constellation stays the subject.
                .background(Color.white.opacity(0.07), in: Circle())
                // 40pt disc, but keep a ≥44pt tap target.
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .accessibilityLabel("Close talk mode")
        .accessibilityIdentifier("talk-mode-close")
        .padding(.leading, 14)
        .padding(.top, 2)
    }

    /// The sole error surface on this screen (talk mode has no alert), so the
    /// status label is allowed to wrap; recovery affordances replace dead-end
    /// text with the same Retry/Review semantics the watch ships.
    private func bottomControls(state: CenterState) -> some View {
        VStack(spacing: 14) {
            StatusLabel(
                state: state,
                style: .onDark,
                font: .system(size: 15, weight: .medium),
                kerning: 0.6
            )
            .multilineTextAlignment(.center)
            .lineLimit(2)
            // A one-line floor keeps the pill ~14pt below the status and stops
            // it riding up when the status is empty (`.attention`); `lineLimit(2)`
            // still lets an error wrap down into the belt below — the 2-line
            // headroom the watch keeps.
            .frame(maxWidth: .infinity, minHeight: 20)
            .padding(.horizontal, 32)
            .accessibilityIdentifier("talk-mode-status")

            actionPill(state: state)
                .frame(height: 44)
        }
    }

    /// Retry a failed turn, or jump to the saved-recording review — driven off
    /// the rendered `CenterState` so the pill is present exactly when the state
    /// machine says attention/review is the resting truth (and so the UITest
    /// override can show it without a live failure).
    @ViewBuilder
    private func actionPill(state: CenterState) -> some View {
        switch state {
        case .attention:
            CoralActionPill(
                title: "Retry",
                systemImage: "arrow.clockwise",
                isBusy: store.isRetryingFailedWork
            ) {
                retryFailedWork()
            }
            .disabled(store.isRetryingFailedWork)
            .accessibilityIdentifier("talk-mode-retry")
        case .needsReview:
            CoralActionPill(
                title: "Review saved",
                systemImage: "exclamationmark.arrow.circlepath"
            ) {
                reviewSaved()
            }
            .accessibilityIdentifier("talk-mode-review")
        default:
            // Reserve nothing visible, but keep the slot's height stable so the
            // status label doesn't jump when a pill appears/disappears.
            Color.clear.frame(width: 1, height: 1)
        }
    }

    // MARK: - Derivation + actions

    private var centerState: CenterState {
        #if DEBUG
        if let forced = Self.uiTestOverrideState { return forced }
        #endif
        return CenterState.derive(
            store: store, audio: audio, session: session, swipeArmed: swipeArmed
        )
    }

    private var conversationName: String {
        store.selectedConversation?.name ?? "Conversation"
    }

    /// Amplitude fed to the face pulse and the constellation's amplitude ticks.
    /// The real mic level in the running app; the mic-open UITest overrides
    /// (`.recording` and `.swipeArmed`) inject a synthetic level, so the ticks
    /// and face pulse actually render in screenshots — both collapse at level 0,
    /// which the mic-revoked simulator always reports. Presentation-only, like
    /// the state override.
    private var renderLevel: CGFloat {
        #if DEBUG
        // Both mic-open states inject a synthetic level so the amplitude ticks
        // and face pulse render in screenshots — the mic-revoked sim always
        // reports 0. `.swipeArmed` animates the same recording constellation
        // (ticks visible), so it needs the level too.
        if let forced = Self.uiTestOverrideState, forced == .recording || forced == .swipeArmed {
            return 0.35
        }
        #endif
        return audio.level
    }

    private func askKibo() {
        // The askable guard lives here — the release just ended (or discarded)
        // the hold by our own hand, so `startSubmit` skips the capture-state
        // guards whose published values may not have settled this tick.
        if store.askableItemCount > 0 {
            session.startSubmit(afterCaptureEnded: true)
        }
    }

    private func retryFailedWork() {
        guard let target = store.events.retryableFailure else { return }
        Task { await store.retryFailedWork(target) }
    }

    /// Saved-recording review lives in Settings, which is a sheet on the
    /// conversation list beneath this cover: dismiss the cover, then present it.
    private func reviewSaved() {
        dismiss()
        router.isSettingsPresented = true
    }

    // MARK: - UITest presentation override

    #if DEBUG
    /// Presentation-only test seam: with `KIBO_UITEST_CENTER_STATE` set, talk
    /// mode renders the named `CenterState` regardless of live audio/store
    /// values — it never touches audio or the store. It exists because the iOS
    /// simulator must run with the mic revoked (CoreAudio deadlock), so
    /// mic-dependent states cannot be driven for real, and plain mock kibod can
    /// neither produce a terminal failure nor hold a >0.6s "speaking" window.
    /// Compiled out of release builds.
    private static var uiTestOverrideState: CenterState? {
        guard let name = ProcessInfo.processInfo.environment["KIBO_UITEST_CENTER_STATE"] else {
            return nil
        }
        switch name {
        case "noConversation": return .noConversation
        case "swipeArmed": return .swipeArmed
        case "starting": return .starting
        case "recording": return .recording
        case "error": return .error("Microphone unavailable")
        case "sending": return .sending
        case "thinking": return .thinking
        case "loadingReply": return .loadingReply
        case "speaking": return .speaking
        case "replyDone": return .replyDone
        case "needsReview": return .needsReview
        case "attention": return .attention
        case "idle": return .idle(pendingCount: 2, savedCount: 1)
        default: return nil
        }
    }
    #endif
}
