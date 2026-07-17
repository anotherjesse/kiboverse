import SwiftUI

/// The hold-to-talk mic circle used by both the conversation composer and
/// full-screen talk mode. Recording state is unmistakable: the fill turns
/// red, staggered rings expand and fade continuously, and the circle scales
/// with the input level — a single static frame mid-recording still reads as
/// "recording" (red + visible rings).
struct MicButton: View {
    let diameter: CGFloat
    let isRecording: Bool
    let isHolding: Bool
    let level: CGFloat
    let isEnabled: Bool
    let beginHold: () -> Void
    let endHold: () -> Void

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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Hold to talk")
        .accessibilityValue(isRecording ? "Recording" : "Ready")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction {
            if isHolding { endHold() } else { beginHold() }
        }
        .gesture(DragGesture(minimumDistance: 0)
            .onChanged { _ in beginHold() }
            .onEnded { _ in endHold() }
        )
        .allowsHitTesting(isEnabled)
        .accessibilityIdentifier("talk-button")
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
