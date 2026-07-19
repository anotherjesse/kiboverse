import SwiftUI

/// The coral state ring on its own — the constellation's ring language without
/// the surrounding field. Where `ConstellationView` wraps Kibo's face in the
/// full sky, `KiboStateRing` gives the composer's inline creature the same ring
/// that hugs the face: dim at rest, dashed-rotating while listening, breathing
/// while thinking, solid + pulsing while speaking, warm afterglow after a reply.
///
/// It reuses `ConstellationView.drawFaceRing` verbatim, so the composer's ring
/// and the full constellation can never drift. The ring is drawn concentric to
/// the Canvas center at `diameter / 2 + 3` (identical to the field), so the
/// caller sizes the enclosing frame slightly larger than the face disc and
/// centers it on the face. Purely decorative: no gestures, a11y, or hit shapes
/// — the platform wraps the face with those.
struct KiboStateRing: View {
    let state: CenterState
    let level: CGFloat
    let diameter: CGFloat
    let pacing: FramePacing

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { context in
            Canvas { graphics, size in
                ConstellationView.drawFaceRing(
                    graphics,
                    center: CGPoint(x: size.width / 2, y: size.height / 2),
                    faceRadius: diameter / 2,
                    mode: state.constellationMode,
                    level: level,
                    time: context.date.timeIntervalSinceReferenceDate
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The TimelineView is the battery cost, not the trig-only Canvas frame.
    /// The always-visible composer ring also pauses whenever the drawn
    /// treatment is static (`.idle`, `.afterglow` don't read `time`), so at
    /// rest it stops redrawing an unchanging frame ~10×/sec — only the animated
    /// modes keep their cadence.
    private var paused: Bool {
        scenePhase != .active
            || isLuminanceReduced
            || !ConstellationView.faceRingAnimates(state.constellationMode)
    }

    private var frameInterval: TimeInterval {
        pacing.interval(for: state.constellationMode)
    }
}
