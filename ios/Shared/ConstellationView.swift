import SwiftUI

/// Geometry the layout projection consumes: how much history stays individual
/// before it compresses, and the text keep-out arcs. A separately-`Equatable`
/// value so the view can key its layout rebuild on it — a window resize that
/// crosses a style boundary must re-derive compression and keep-out geometry.
struct ConstellationLayoutMetrics: Equatable {
    /// Oldest history beyond this many markers compresses into a faint inner
    /// band so the most recent events stay legible.
    var maxIndividual: Int
    var recentKept: Int
    /// Text keep-outs, in radians of arc removed around 12 and 6 o'clock.
    var topGap: Double
    var bottomGap: Double
}

/// Frame pacing per mode. Data, not a closure — a closure-valued field cannot
/// be `Equatable` and would lie about pacing; the fps table is already data.
struct FramePacing: Equatable {
    var idle: TimeInterval
    var afterglow: TimeInterval
    var thinking: TimeInterval
    var recording: TimeInterval
    var speaking: TimeInterval

    /// Watch pacing verbatim from the pre-unification renderer: battery-aware,
    /// never faster than 30fps.
    static let watch = FramePacing(
        idle: 1.0 / 8.0, afterglow: 1.0 / 10.0, thinking: 1.0 / 15.0,
        recording: 1.0 / 30.0, speaking: 1.0 / 30.0
    )
    /// Phone pacing: a bigger sky buys a higher frame rate (60fps in the
    /// active states on ProMotion), still gentle at rest.
    static let phone = FramePacing(
        idle: 1.0 / 10.0, afterglow: 1.0 / 12.0, thinking: 1.0 / 20.0,
        recording: 1.0 / 60.0, speaking: 1.0 / 60.0
    )

    func interval(for mode: ConstellationMode) -> TimeInterval {
        switch mode {
        case .idle: idle
        case .afterglow: afterglow
        case .thinking: thinking
        case .recording: recording
        case .speaking: speaking
        }
    }
}

/// Everything a container hands the renderer to scale the same organism to the
/// hand: layout geometry, frame pacing, and rendering scale — three
/// separately-`Equatable` concerns composed into one value. `.watch` holds
/// every pre-unification constant verbatim (`dustDepthStrength` 0 ⇒
/// byte-identical dust), so the watch render path is unchanged.
struct ConstellationStyle: Equatable {
    var layout: ConstellationLayoutMetrics
    var pacing: FramePacing
    /// Fixed dim specks scattered behind the field.
    var dustCount: Int
    /// Deep-layer parallax: a per-speck depth dims and slows the far dust.
    /// 0 (watch) multiplies by exactly 1 — no depth, byte-identical output.
    var dustDepthStrength: Double
    /// Rendering scales — a bigger screen buys a richer, not different, look.
    var markerScale: Double
    var lineScale: Double
    var driftScale: Double
    var rippleCount: Int
    var tickCount: Int
    /// Points trimmed from the outer orbit band so the field clears platform
    /// chrome (the watch's clock/toolbar).
    var outerInset: CGFloat

    /// Every field = today's watch constant.
    static let watch = ConstellationStyle(
        layout: ConstellationLayoutMetrics(
            maxIndividual: 14, recentKept: 12, topGap: 1.7, bottomGap: 1.05
        ),
        pacing: .watch,
        dustCount: 18,
        dustDepthStrength: 0,
        markerScale: 1.0,
        lineScale: 1.0,
        driftScale: 1.0,
        rippleCount: 3,
        tickCount: 36,
        outerInset: 16
    )

    /// The phone sky: more orbiting history, deeper star field, larger marks,
    /// farther ripples, finer amplitude ticks — same renderer, no new modes.
    static let phone = ConstellationStyle(
        layout: ConstellationLayoutMetrics(
            maxIndividual: 22, recentKept: 18, topGap: 1.7, bottomGap: 1.05
        ),
        pacing: .phone,
        dustCount: 44,
        dustDepthStrength: 0.5,
        markerScale: 1.6,
        lineScale: 1.4,
        driftScale: 1.5,
        rippleCount: 4,
        tickCount: 48,
        outerInset: 8
    )

    /// The iPad/Mac seam: a small container gets the watch's tight look, a
    /// large one the phone's richer field. `.expansive` lands here later.
    static func fitting(minDimension: CGFloat) -> ConstellationStyle {
        minDimension < 260 ? .watch : .phone
    }

    /// Deep dust is dimmer: strength 0 (watch) returns exactly 1.
    func dustOpacityFactor(depth: Double) -> Double {
        1 - depth * dustDepthStrength
    }

    /// Deep dust twinkles slower: strength 0 (watch) returns exactly 1.
    func dustSpeedFactor(depth: Double) -> Double {
        1 - depth * dustDepthStrength * 0.5
    }
}

/// Deterministic placement of constellation markers. Pure function of the
/// marker list and layout metrics — no clocks, no randomness — so an event
/// keeps its spot across polls, relaunches, and the spool-to-server identity
/// handoff.
struct ConstellationLayout: Equatable {
    struct Placed: Equatable {
        let event: ConstellationEvent
        /// Base angle in radians; 0 points up, positive is clockwise.
        let angle: Double
        /// 0…1 position across the usable band (face edge → screen edge).
        /// Newer events sit farther out and brighter.
        let radiusFactor: Double
        /// Stable 0…1 offset that staggers twinkle/drift timing.
        let phase: Double
        /// Base marker radius in points.
        let size: Double
        /// 0 = oldest kept marker, 1 = newest. History dims with age.
        let age: Double
    }

    let placed: [Placed]
    let compressedCount: Int

    init(markers: [ConstellationEvent], metrics: ConstellationLayoutMetrics) {
        let kept: [ConstellationEvent]
        if markers.count > metrics.maxIndividual {
            compressedCount = markers.count - metrics.recentKept
            kept = Array(markers.suffix(metrics.recentKept))
        } else {
            compressedCount = 0
            kept = markers
        }
        // At least 8 slots so a young conversation doesn't smear two events
        // across opposite sides of the screen. Markers live on two side
        // arcs: wedges at 12 o'clock (clock + title) and 6 o'clock (status
        // caption) stay permanently marker-free.
        let arcs = Self.sideArcs(topGap: metrics.topGap, bottomGap: metrics.bottomGap)
        let slots = Double(max(kept.count, 8))
        let slotWidth = arcs.total / slots
        placed = kept.enumerated().map { index, event in
            let angleJitter = (Self.hash01(event.id, salt: 0xA11CE) - 0.5) * slotWidth * 0.6
            let radiusJitter = (Self.hash01(event.id, salt: 0xB0B) - 0.5) * 0.05
            let age = kept.count <= 1 ? 1.0 : Double(index) / Double(kept.count - 1)
            let along = (Double(index) + 0.5) * slotWidth + angleJitter
            return Placed(
                event: event,
                angle: arcs.angle(at: along),
                radiusFactor: Self.orbit(for: event) + radiusJitter,
                phase: Self.hash01(event.id, salt: 0xFACE),
                size: Self.baseSize(for: event),
                age: age
            )
        }
    }

    /// Two clean orbits, like the concept art's drafting: history (seen
    /// thoughts and settled replies) rides the inner line; live items
    /// (unseen, in-flight, failed) ride the outer.
    static let historyOrbit = 0.38
    static let activeOrbit = 0.88

    static func orbit(for event: ConstellationEvent) -> Double {
        onActiveOrbit(event) ? activeOrbit : historyOrbit
    }

    static func onActiveOrbit(_ event: ConstellationEvent) -> Bool {
        switch event.phase {
        case .unseen, .working, .failed: true
        case .seen: false
        }
    }

    /// The two marker-bearing side arcs, derived from the text keep-outs.
    /// Maps a distance along the concatenated arcs to a screen angle
    /// (0 = up, clockwise positive).
    struct SideArcs: Equatable {
        let rightStart: Double, rightLength: Double
        let leftStart: Double, leftLength: Double
        var total: Double { rightLength + leftLength }

        func angle(at distance: Double) -> Double {
            let clamped = min(max(distance, 0), total)
            return clamped < rightLength
                ? rightStart + clamped
                : leftStart + (clamped - rightLength)
        }
    }

    static func sideArcs(topGap: Double, bottomGap: Double) -> SideArcs {
        let sideLength = .pi - topGap / 2 - bottomGap / 2
        return SideArcs(
            rightStart: topGap / 2, rightLength: sideLength,
            leftStart: .pi + bottomGap / 2, leftLength: sideLength
        )
    }

    private static func baseSize(for event: ConstellationEvent) -> Double {
        switch event.kind {
        case .reply: event.phase == .failed ? 5.2 : 4.5
        case .voice, .image:
            switch event.phase {
            case .unseen, .working, .failed: 5.2
            case .seen: 2.8
            }
        }
    }

    /// FNV-1a, not `hashValue`: Swift seeds hashing per launch, and layout
    /// must survive relaunch without every star jumping.
    static func hash01(_ value: String, salt: UInt64) -> Double {
        var hash: UInt64 = 0xcbf29ce484222325 &+ salt
        for byte in value.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return Double(hash % 100_003) / 100_003
    }
}

/// The living constellation behind Kibo's face: conversation history as
/// stars/dots/rings, plus mode-driven ambience (amplitude ticks while
/// recording, inward pull while thinking, ripples while speaking).
///
/// Purely decorative — hit testing stays with the face button above it.
struct ConstellationView: View {
    let markers: [ConstellationEvent]
    let state: CenterState
    let level: CGFloat
    let faceDiameter: CGFloat
    let style: ConstellationStyle

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced
    @State private var layout = ConstellationLayout(
        markers: [], metrics: ConstellationStyle.watch.layout
    )

    var body: some View {
        TimelineView(.animation(minimumInterval: frameInterval, paused: paused)) { context in
            Canvas { graphics, size in
                Self.draw(
                    graphics,
                    size: size,
                    layout: layout,
                    state: state,
                    level: level,
                    faceDiameter: faceDiameter,
                    style: style,
                    time: context.date.timeIntervalSinceReferenceDate
                )
            }
        }
        // Projection runs when the conversation OR the layout geometry changes,
        // never per frame — the frame closure above does trig only. Keying on
        // both means a window resize that crosses a style boundary can never
        // retain stale compression or keep-out geometry.
        .onChange(of: markers, initial: true) { _, newMarkers in
            layout = ConstellationLayout(markers: newMarkers, metrics: style.layout)
        }
        .onChange(of: style.layout) { _, newLayout in
            layout = ConstellationLayout(markers: markers, metrics: newLayout)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// An unpaused TimelineView is the battery cost here, not Canvas work.
    private var paused: Bool {
        scenePhase != .active || isLuminanceReduced
    }

    private var frameInterval: TimeInterval {
        style.pacing.interval(for: state.constellationMode)
    }

    // MARK: - Drawing

    private static func draw(
        _ graphics: GraphicsContext,
        size: CGSize,
        layout: ConstellationLayout,
        state: CenterState,
        level: CGFloat,
        faceDiameter: CGFloat,
        style: ConstellationStyle,
        time: TimeInterval
    ) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let maxRadius = min(size.width, size.height) / 2 - 4
        let faceRadius = faceDiameter / 2
        // Stars stay inside the chrome: the outer inset keeps the orbit
        // clear of the clock and toolbar buttons (sizes are points). Clamped
        // so a constrained container can never invert the band.
        let inner = faceRadius + 10
        let band = (inner: inner, outer: max(inner + 8, maxRadius - style.outerInset))
        let mode = state.constellationMode

        // While a reply is being generated, its context markers get pulled
        // toward Kibo — the constellation shows what Kibo is reading.
        let pulledIDs: Set<String> = {
            guard let working = layout.placed.last(where: {
                $0.event.kind == .reply && $0.event.phase == .working
            }) else { return [] }
            return Set(working.event.contextIDs)
        }()

        func position(of placed: ConstellationLayout.Placed) -> CGPoint {
            let driftAmplitude = (mode == .idle || mode == .afterglow ? 0.02 : 0.04)
                * style.driftScale
            let angle = placed.angle - .pi / 2
                + sin(time * 0.06 + placed.phase * 2 * .pi) * driftAmplitude
            var radius = band.inner + placed.radiusFactor * (band.outer - band.inner)
            if pulledIDs.contains(placed.event.id) {
                let pull = 0.42 + 0.05 * sin(time * 1.6 + placed.phase * 2 * .pi)
                radius = band.inner + (radius - band.inner) * pull
            }
            return CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
        }

        // ID-keyed positions exist only for thread-line targets; markers draw
        // at their own placement so duplicate IDs never collapse onto one
        // point.
        let positions = Dictionary(
            layout.placed.map { ($0.event.id, position(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )

        drawAmbient(
            graphics, center: center, band: band, faceRadius: faceRadius,
            mode: mode, level: level, style: style, time: time
        )
        drawCompressedHistory(graphics, layout: layout, center: center, band: band)
        drawHistoryChain(graphics, layout: layout, center: center, band: band)
        drawThreadLines(
            graphics, layout: layout, state: state,
            positions: positions, center: center,
            faceRadius: faceRadius, style: style, time: time
        )
        for placed in layout.placed {
            drawMarker(
                graphics, placed: placed, at: position(of: placed),
                mode: mode, style: style, time: time
            )
        }

        switch mode {
        case .recording:
            drawAmplitudeTicks(
                graphics, center: center, faceRadius: faceRadius,
                level: level, style: style, time: time
            )
        case .speaking:
            drawSpeechRipples(
                graphics, center: center, faceRadius: faceRadius,
                maxRadius: maxRadius, style: style, time: time
            )
        case .idle, .thinking, .afterglow:
            break
        }

        drawFaceRing(
            graphics, center: center, faceRadius: faceRadius,
            mode: mode, level: level, time: time
        )
    }

    /// The quiet layer that makes the screen feel alive even when empty: a
    /// soft coral glow behind Kibo, a dotted near orbit, a hairline outer
    /// orbit, and a scatter of dim star dust. All deterministic, all far
    /// dimmer than any real marker.
    private static func drawAmbient(
        _ graphics: GraphicsContext,
        center: CGPoint,
        band: (inner: CGFloat, outer: CGFloat),
        faceRadius: CGFloat,
        mode: ConstellationMode,
        level: CGFloat,
        style: ConstellationStyle,
        time: TimeInterval
    ) {
        // Tight, quiet halo — at full-field size the gradient reads as a
        // muddy disc instead of light.
        let glowStrength: Double = switch mode {
        case .idle: 0.08
        case .afterglow: 0.10
        case .recording: 0.12 + 0.16 * level
        case .thinking: 0.09 + 0.03 * sin(time * 1.5)
        case .speaking: 0.11 + 0.03 * sin(time * 5)
        }
        // Long fade from deep inside the face: no perceptible rim.
        let glowRadius = faceRadius * 1.5
        graphics.fill(
            Path(ellipseIn: CGRect(
                x: center.x - glowRadius, y: center.y - glowRadius,
                width: glowRadius * 2, height: glowRadius * 2
            )),
            with: .radialGradient(
                Gradient(colors: [Color.kiboCoral.opacity(glowStrength), .clear]),
                center: center,
                startRadius: faceRadius * 0.3,
                endRadius: glowRadius
            )
        )

        // The orbit guides are the marker orbits themselves — dotted for the
        // history line, hairline for the active rim — so markers visibly
        // ride fine drafting instead of floating in speckle.
        let historyRadius = band.inner
            + (band.outer - band.inner) * ConstellationLayout.historyOrbit
        graphics.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - historyRadius, y: center.y - historyRadius,
                width: historyRadius * 2, height: historyRadius * 2
            )),
            with: .color(.white.opacity(0.09)),
            style: StrokeStyle(lineWidth: 0.8, dash: [1, 4.5])
        )
        let activeRadius = band.inner
            + (band.outer - band.inner) * ConstellationLayout.activeOrbit
        graphics.stroke(
            Path(ellipseIn: CGRect(
                x: center.x - activeRadius, y: center.y - activeRadius,
                width: activeRadius * 2, height: activeRadius * 2
            )),
            with: .color(.white.opacity(0.06)),
            lineWidth: 0.6
        )

        // Star dust: tiny fixed specks, each on its own slow twinkle phase.
        // A per-speck depth (a new salt off the same FNV helper) dims and
        // slows the far layer — parallax without a parallax system. At
        // `dustDepthStrength` 0 both factors are exactly 1, so the watch's
        // specks are byte-identical.
        for index in 0..<style.dustCount {
            let key = "dust-\(index)"
            let angle = ConstellationLayout.hash01(key, salt: 0xD5) * 2 * .pi
            let spread = ConstellationLayout.hash01(key, salt: 0xD6)
            let radius = faceRadius + 8 + spread * (band.outer - faceRadius - 4)
            let phase = ConstellationLayout.hash01(key, salt: 0xD7)
            let depth = ConstellationLayout.hash01(key, salt: 0xD8)
            let twinkleSpeed = 0.8 * style.dustSpeedFactor(depth: depth)
            let twinkle = 0.5 + 0.5 * sin(time * twinkleSpeed + phase * 2 * .pi)
            let size: CGFloat = spread > 0.7 ? 1.4 : 1.0
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            graphics.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - size / 2, y: point.y - size / 2,
                    width: size, height: size
                )),
                with: .color(.white.opacity(
                    (0.05 + 0.11 * twinkle) * style.dustOpacityFactor(depth: depth)
                ))
            )
        }
    }

    /// Old history: a faint arc of tiny dots hugging the face. Presence over
    /// detail — the spec avoids numeric "+N" badges.
    private static func drawCompressedHistory(
        _ graphics: GraphicsContext,
        layout: ConstellationLayout,
        center: CGPoint,
        band: (inner: CGFloat, outer: CGFloat)
    ) {
        guard layout.compressedCount > 0 else { return }
        let dots = min(layout.compressedCount, 12)
        let radius = band.inner + 0.12 * (band.outer - band.inner)
        for index in 0..<dots {
            let angle = -Double.pi / 2 + 2 * .pi * Double(index) / Double(dots)
            let point = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            graphics.fill(
                Path(ellipseIn: CGRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)),
                with: .color(.kiboSeenThought.opacity(0.35))
            )
        }
    }

    /// The conversation thread: consecutive history markers joined by faint
    /// arc segments along their shared orbit — a drawn constellation, not a
    /// fan of straight cracks. Segments never bridge the text keep-outs.
    private static func drawHistoryChain(
        _ graphics: GraphicsContext,
        layout: ConstellationLayout,
        center: CGPoint,
        band: (inner: CGFloat, outer: CGFloat)
    ) {
        let chain = layout.placed.filter {
            !ConstellationLayout.onActiveOrbit($0.event)
        }
        guard chain.count > 1 else { return }
        let radius = band.inner
            + (band.outer - band.inner) * ConstellationLayout.historyOrbit
        for (from, to) in zip(chain, chain.dropFirst()) {
            let sameArc = (from.angle < .pi) == (to.angle < .pi)
            guard sameArc, to.angle - from.angle < 1.4 else { continue }
            var path = Path()
            path.addArc(
                center: center, radius: radius,
                startAngle: .radians(from.angle - .pi / 2),
                endAngle: .radians(to.angle - .pi / 2),
                clockwise: false
            )
            graphics.stroke(path, with: .color(.white.opacity(0.12)), lineWidth: 0.8)
        }
    }

    /// Straight connector lines exist only while they mean something live:
    /// the armed gather (what an ask will send) and a thinking reply's
    /// ingest fan. Settled states carry no lines — at wrist size they read
    /// as scratches.
    private static func drawThreadLines(
        _ graphics: GraphicsContext,
        layout: ConstellationLayout,
        state: CenterState,
        positions: [String: CGPoint],
        center: CGPoint,
        faceRadius: CGFloat,
        style: ConstellationStyle,
        time: TimeInterval
    ) {
        if state == .swipeArmed {
            for placed in layout.placed
            where placed.event.phase == .unseen || placed.event.phase == .working {
                guard let point = positions[placed.event.id] else { continue }
                // The line starts at the ring edge, not the center — the
                // ring is the intake aperture; nothing skewers the face.
                let dx = point.x - center.x
                let dy = point.y - center.y
                let distance = max(sqrt(dx * dx + dy * dy), 1)
                let edge = CGPoint(
                    x: center.x + dx / distance * (faceRadius + 4),
                    y: center.y + dy / distance * (faceRadius + 4)
                )
                var path = Path()
                path.move(to: edge)
                path.addLine(to: point)
                graphics.stroke(
                    path,
                    with: .color(.kiboCoralBright.opacity(0.5)),
                    lineWidth: 1.5 * style.lineScale
                )
            }
            return
        }
        guard let reply = layout.placed.last(where: {
            $0.event.kind == .reply && $0.event.phase == .working
        }), let replyPoint = positions[reply.event.id] else { return }
        let opacity = 0.5 + 0.25 * sin(time * 1.8)
        for contextID in reply.event.contextIDs {
            guard let point = positions[contextID] else { continue }
            var path = Path()
            path.move(to: replyPoint)
            path.addLine(to: point)
            graphics.stroke(
                path,
                with: .color(.kiboCoralDim.opacity(opacity)),
                lineWidth: 1.5 * style.lineScale
            )
        }
    }

    private static func drawMarker(
        _ graphics: GraphicsContext,
        placed: ConstellationLayout.Placed,
        at point: CGPoint,
        mode: ConstellationMode,
        style: ConstellationStyle,
        time: TimeInterval
    ) {
        let event = placed.event
        let markerSize = placed.size * style.markerScale
        let twinkleSpeed: Double = switch mode {
        case .idle: 1.0
        case .afterglow: 1.2
        case .thinking: 1.6
        case .speaking: 2.2
        case .recording: 3.5
        }
        let twinkle = 0.82 + 0.18 * sin(time * twinkleSpeed + placed.phase * 2 * .pi)
        let boost = mode == .recording ? 1.15 : 1.0

        // History recedes: seen thoughts and settled replies dim with age,
        // so the newest turn always owns the eye.
        let ageDim = 0.45 + 0.55 * placed.age

        switch (event.kind, event.phase) {
        // A FAILED reply falls through to the filled-star branch below: a
        // tiny hollow amber ring is indistinguishable from coral rings at
        // wrist size, and finding the failed item is the whole point.
        case (.reply, .working), (.reply, .seen), (.reply, .unseen):
            let color: Color = event.phase == .working ? .kiboCoralDim : .kiboCoral
            let radius = markerSize
            // The newest settled reply is the resting hero: a faint bloom
            // keeps the eye on the latest turn even when nothing moves.
            if event.phase == .seen && placed.age >= 0.999 {
                graphics.stroke(
                    Path(ellipseIn: CGRect(
                        x: point.x - radius, y: point.y - radius,
                        width: radius * 2, height: radius * 2
                    )),
                    with: .color(color.opacity(0.22)),
                    lineWidth: 4.5
                )
            }
            graphics.stroke(
                Path(ellipseIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(color.opacity(0.85 * twinkle * ageDim)),
                lineWidth: 1.1
            )
            // A hollow ring is the settled celestial form; the center spark
            // appears only while the reply is being worked or needs help.
            if event.phase != .seen {
                graphics.fill(
                    Path(ellipseIn: CGRect(
                        x: point.x - 1.1, y: point.y - 1.1, width: 2.2, height: 2.2
                    )),
                    with: .color(color.opacity(0.9))
                )
            }
            if event.phase == .working {
                drawOrbitArc(graphics, at: point, radius: radius + 3.5, time: time, color: .kiboCoral)
            }

        case (_, .seen):
            let radius = markerSize
            graphics.fill(
                Path(ellipseIn: CGRect(
                    x: point.x - radius, y: point.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(.kiboSeenThought.opacity(0.8 * twinkle * ageDim))
            )

        default:
            let color: Color = event.phase == .failed ? .kiboAmber : .kiboCoralBright
            let pulse = event.phase == .failed ? 0.65 + 0.3 * sin(time * 2.0) : twinkle
            // Diamonds cover less area than stars at equal radius; scale up
            // so a pending image carries the same luminance as a pending
            // thought.
            let unit = event.kind == .image ? markerSize * 1.2 : markerSize
            let shape = event.kind == .image
                ? diamondPath(at: point, radius: unit * boost)
                : starPath(at: point, radius: unit * boost)
            // Soft halo first so bright marks glow without a blur filter.
            let halo = event.kind == .image
                ? diamondPath(at: point, radius: unit * boost * 2.2)
                : starPath(at: point, radius: unit * boost * 2.2)
            graphics.fill(halo, with: .color(color.opacity(0.18 * pulse)))
            graphics.fill(shape, with: .color(color.opacity(pulse)))
            if event.phase == .working {
                drawOrbitArc(graphics, at: point, radius: markerSize + 4, time: time, color: color)
            }
        }
    }

    /// The in-flight indicator: a short arc orbiting the marker.
    private static func drawOrbitArc(
        _ graphics: GraphicsContext,
        at point: CGPoint,
        radius: CGFloat,
        time: TimeInterval,
        color: Color
    ) {
        let start = Angle(radians: time * 2.4)
        var path = Path()
        path.addArc(
            center: point, radius: radius,
            startAngle: start, endAngle: start + .radians(1.9), clockwise: false
        )
        graphics.stroke(path, with: .color(color.opacity(0.9)), lineWidth: 1.2)
    }

    /// Recording: radial ticks around the face driven by mic amplitude.
    private static func drawAmplitudeTicks(
        _ graphics: GraphicsContext,
        center: CGPoint,
        faceRadius: CGFloat,
        level: CGFloat,
        style: ConstellationStyle,
        time: TimeInterval
    ) {
        let ticks = style.tickCount
        let innerRadius = faceRadius + 7
        for index in 0..<ticks {
            let angle = 2 * .pi * Double(index) / Double(ticks)
            let wave = 0.35 + 0.65 * abs(sin(time * 6 + Double(index) * 1.31))
            let length = 1.5 + level * 13 * wave
            let direction = CGPoint(x: cos(angle), y: sin(angle))
            var path = Path()
            path.move(to: CGPoint(
                x: center.x + direction.x * innerRadius,
                y: center.y + direction.y * innerRadius
            ))
            path.addLine(to: CGPoint(
                x: center.x + direction.x * (innerRadius + length),
                y: center.y + direction.y * (innerRadius + length)
            ))
            graphics.stroke(
                path,
                with: .color(.kiboCoral.opacity(0.30 + 0.55 * level)),
                lineWidth: 1.2
            )
        }
    }

    /// Speaking: concentric ripples radiating from the face.
    private static func drawSpeechRipples(
        _ graphics: GraphicsContext,
        center: CGPoint,
        faceRadius: CGFloat,
        maxRadius: CGFloat,
        style: ConstellationStyle,
        time: TimeInterval
    ) {
        let rings = style.rippleCount
        for ring in 0..<rings {
            let progress = (time * 0.45 + Double(ring) / Double(rings))
                .truncatingRemainder(dividingBy: 1)
            let radius = faceRadius + 4 + progress * (maxRadius - faceRadius) * 0.85
            graphics.stroke(
                Path(ellipseIn: CGRect(
                    x: center.x - radius, y: center.y - radius,
                    width: radius * 2, height: radius * 2
                )),
                with: .color(.kiboCoral.opacity((1 - progress) * 0.30)),
                lineWidth: 1.2
            )
        }
    }

    /// The coral ring hugging the face — dim at rest, hot while recording,
    /// breathing while thinking, pulsing while speaking.
    private static func drawFaceRing(
        _ graphics: GraphicsContext,
        center: CGPoint,
        faceRadius: CGFloat,
        mode: ConstellationMode,
        level: CGFloat,
        time: TimeInterval
    ) {
        let radius = faceRadius + 3
        let ring = Path(ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius,
            width: radius * 2, height: radius * 2
        ))
        // Each state owns a ring *treatment*, not just a brightness:
        // whisper at rest, rotating dashes while listening, a breathing ring
        // that never goes dark while thinking, solid + ripples while
        // speaking, and a warm afterglow once the reply has played.
        switch mode {
        case .idle:
            graphics.stroke(ring, with: .color(.kiboCoral.opacity(0.16)), lineWidth: 1.0)
        case .afterglow:
            graphics.stroke(ring, with: .color(.kiboCoral.opacity(0.12)), lineWidth: 5)
            graphics.stroke(ring, with: .color(.kiboCoral.opacity(0.45)), lineWidth: 1.6)
        case .recording:
            let width = 2 + level * 3
            graphics.stroke(
                ring,
                with: .color(.kiboCoral.opacity(0.25 * (0.5 + level))),
                lineWidth: width + 5
            )
            graphics.stroke(
                ring,
                with: .color(.kiboCoral.opacity(0.95)),
                style: StrokeStyle(
                    lineWidth: width, lineCap: .round,
                    dash: [7, 5], dashPhase: -time * 16
                )
            )
        case .thinking:
            graphics.stroke(
                ring,
                with: .color(.kiboCoral.opacity(0.55 + 0.15 * sin(time * 1.5))),
                lineWidth: 2
            )
        case .speaking:
            graphics.stroke(
                ring,
                with: .color(.kiboCoral.opacity(0.9)),
                lineWidth: 2 + 0.8 * (1 + sin(time * 5))
            )
        }
    }

    /// Four-point sparkle star (the app's visual language for a thought).
    private static func starPath(at point: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        let short = radius * 0.36
        for spike in 0..<4 {
            let angle = Double(spike) * .pi / 2 - .pi / 2
            let tip = CGPoint(
                x: point.x + cos(angle) * radius,
                y: point.y + sin(angle) * radius
            )
            let left = CGPoint(
                x: point.x + cos(angle - .pi / 4) * short,
                y: point.y + sin(angle - .pi / 4) * short
            )
            let right = CGPoint(
                x: point.x + cos(angle + .pi / 4) * short,
                y: point.y + sin(angle + .pi / 4) * short
            )
            if spike == 0 { path.move(to: left) } else { path.addLine(to: left) }
            path.addLine(to: tip)
            path.addLine(to: right)
        }
        path.closeSubpath()
        return path
    }

    private static func diamondPath(at point: CGPoint, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: point.x, y: point.y - radius))
        path.addLine(to: CGPoint(x: point.x + radius * 0.72, y: point.y))
        path.addLine(to: CGPoint(x: point.x, y: point.y + radius))
        path.addLine(to: CGPoint(x: point.x - radius * 0.72, y: point.y))
        path.closeSubpath()
        return path
    }
}
