import SwiftUI

/// The hold-to-talk mic circle used by both the conversation composer and
/// full-screen talk mode. Recording state is unmistakable: the fill turns
/// red, staggered rings expand and fade continuously, and the circle scales
/// with the input level — a single static frame mid-recording still reads as
/// "recording" (red + visible rings).
///
/// Release gestures (Telegram-style):
/// - hold, release in place → save the clip
/// - hold 1s+, swipe up, release → save the clip and ask Kibo with it
/// - press and flick up within 1s → ask Kibo with what's already pending
struct MicButton: View {
    let diameter: CGFloat
    let isRecording: Bool
    let isHolding: Bool
    let level: CGFloat
    let isEnabled: Bool
    let beginHold: () -> Void
    let endHold: () -> Void
    let cancelHold: () -> Void
    let askKibo: () -> Void

    /// Swiping up past this arms release-to-ask.
    private static let swipeThreshold: CGFloat = 55
    /// Sub-second releases never produce a recording: with a swipe they ask
    /// with what's already pending, without one the capture is silently
    /// discarded. Only holds of 1s+ are real recordings.
    private static let recordThreshold: TimeInterval = 1.0

    @State private var holdStartedAt: Date?
    @State private var swipeArmed = false

    var body: some View {
        ZStack {
            if isRecording {
                RecordingRing(diameter: diameter, delay: 0.0)
                RecordingRing(diameter: diameter, delay: 0.45)
                RecordingRing(diameter: diameter, delay: 0.9)
            }
            Circle()
                .fill(isRecording ? Color.red : Color.kiboCoral)
                .frame(width: diameter, height: diameter)
                .shadow(
                    color: (isRecording ? Color.red : Color.kiboCoral).opacity(0.35),
                    radius: diameter * 0.11,
                    y: diameter * 0.045
                )
                .scaleEffect(isRecording ? 1 + level * 0.12 : 1)
                .animation(.easeOut(duration: 0.08), value: level)
            Image(systemName: isRecording ? "waveform" : "mic.fill")
                .font(.system(size: diameter * 0.4, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: diameter, height: diameter)
        .opacity(isEnabled ? 1 : 0.4)
        .overlay(alignment: .top) { swipeHint }
        .sensoryFeedback(.impact(weight: .medium), trigger: swipeArmed)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if isHolding { endHold() } else { beginHold() }
        }
        // With no separate Ask button, the swipe gesture needs an
        // accessibility equivalent.
        .accessibilityAction(named: "Ask Kibo") { askKibo() }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if holdStartedAt == nil {
                        holdStartedAt = value.time
                        beginHold()
                    }
                    let armed = value.translation.height <= -Self.swipeThreshold
                    if armed != swipeArmed { swipeArmed = armed }
                }
                .onEnded { value in
                    let startedAt = holdStartedAt
                    holdStartedAt = nil
                    swipeArmed = false
                    let heldFor = startedAt.map { value.time.timeIntervalSince($0) } ?? 0
                    let swiped = value.translation.height <= -Self.swipeThreshold
                    if heldFor < Self.recordThreshold {
                        cancelHold()
                        if swiped { askKibo() }
                    } else {
                        endHold()
                        if swiped { askKibo() }
                    }
                }
        )
        .allowsHitTesting(isEnabled)
        .accessibilityIdentifier("talk-button")
    }

    /// Transient, hold-only affordance for the release gesture — appears
    /// while the finger is down and highlights once the swipe is armed.
    @ViewBuilder
    private var swipeHint: some View {
        if isHolding || isRecording {
            HStack(spacing: 5) {
                Image(systemName: swipeArmed ? "sparkles" : "chevron.up")
                Text(swipeArmed ? "Release to ask" : "Swipe up to ask")
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(swipeArmed ? Color.white : Color.secondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                swipeArmed ? AnyShapeStyle(Color.kiboCoral) : AnyShapeStyle(.thinMaterial),
                in: Capsule()
            )
            .offset(y: -(diameter * 0.24 + 44))
            .allowsHitTesting(false)
            .animation(.easeOut(duration: 0.15), value: swipeArmed)
            .transition(.opacity)
        }
    }
}

private struct RecordingRing: View {
    let diameter: CGFloat
    let delay: Double
    @State private var expanded = false
    @State private var faded = false

    var body: some View {
        // Rings start at 1.15x so a fresh ring immediately clears the fill
        // (which grows to 1.12x with level), and opacity fades linearly
        // while scale eases out — a static frame at any phase shows 2–3
        // visible staggered rings.
        Circle()
            .stroke(Color.red.opacity(faded ? 0 : 0.6), lineWidth: 3)
            .frame(width: diameter, height: diameter)
            .scaleEffect(expanded ? 1.8 : 1.15)
            .onAppear {
                withAnimation(
                    .easeOut(duration: 1.35)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    expanded = true
                }
                withAnimation(
                    .linear(duration: 1.35)
                        .repeatForever(autoreverses: false)
                        .delay(delay)
                ) {
                    faded = true
                }
            }
    }
}
