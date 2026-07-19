import SwiftUI

/// Kibo's bunny face at the center of the constellation, on every device. The
/// sprite is a cut-out on transparency — it sits directly inside the state
/// ring wherever the backdrop is already dark (OLED black on the watch, the
/// ink vignette in phone talk mode), no backing disc.
///
/// Sprite swaps are instant: a crossfade reads as a glitch at this size. The
/// face pulses with mic level only while recording, and the gate is the state
/// machine itself (`constellationMode == .recording`), not a separate
/// `isRecording` flag — pixel-equivalent, since `level` is 0 whenever nothing
/// is recording. No gestures, a11y, or hit shapes live here; platforms wrap.
struct KiboFace: View {
    let state: CenterState
    let level: CGFloat
    let diameter: CGFloat

    var body: some View {
        Image(state.faceAssetName)
            .resizable()
            .scaledToFit()
            .frame(width: diameter * 0.92, height: diameter * 0.92)
            .scaleEffect(state.constellationMode == .recording ? 1 + level * 0.10 : 1)
            .animation(.easeOut(duration: 0.08), value: level)
            .frame(width: diameter, height: diameter)
    }
}
