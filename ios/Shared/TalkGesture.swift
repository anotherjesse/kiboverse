import SwiftUI

/// The Telegram-style hold-to-talk gesture, unified across phone and watch.
///
/// One truth table (`TalkGestureOutcome`) plus one modifier
/// (`holdToTalkGesture`) emitting one typed event stream to one sink. The
/// semantics that must not drift live here; every platform difference —
/// haptics, hints, hit shapes, accessibility, the askable-count guard — lives
/// in each platform's `onEvent` handler.
///
/// Release gestures:
/// - hold <1s, release in place → capture discarded (`.canceled`)
/// - hold 1s+, release in place → clip saved (`.saved`)
/// - hold 1s+, swipe up, release → clip saved and Kibo asked (`.saved`, `.askRequested`)
/// - press + flick up within 1s → ask Kibo with what's pending (`.canceled`, `.askRequested`)
enum TalkGestureEvent: Equatable {
    /// Finger down: the platform begins the hold (record).
    case began
    /// The swipe crossed (true) or re-crossed back below (false) the ask threshold.
    case armedChanged(Bool)
    /// Released before the record threshold: the capture is discarded.
    case canceled
    /// Released at or past the record threshold: finalize and save the clip.
    case saved
    /// Follows the terminal event when the release was armed: ask Kibo.
    case askRequested
}

/// The pure release truth table, unit-tested once. Deliberately free of any
/// UI or platform state so both the modifier and the tests resolve identically.
enum TalkGestureOutcome: Equatable {
    case discard, save, saveAndAsk, askPending

    /// Sub-second releases never produce a recording; only holds of 1s+ are
    /// real captures.
    static let recordThreshold: TimeInterval = 1.0

    static func resolve(heldFor: TimeInterval, swiped: Bool) -> TalkGestureOutcome {
        let recorded = heldFor >= recordThreshold
        switch (recorded, swiped) {
        case (false, false): return .discard
        case (true, false): return .save
        case (true, true): return .saveAndAsk
        case (false, true): return .askPending
        }
    }

    /// The terminal events this outcome emits, in order.
    var terminalEvents: [TalkGestureEvent] {
        switch self {
        case .discard: return [.canceled]
        case .save: return [.saved]
        case .saveAndAsk: return [.saved, .askRequested]
        case .askPending: return [.canceled, .askRequested]
        }
    }
}

extension TalkGestureEvent {
    /// The full, ordered event sequence a release emits.
    ///
    /// The disarm is keyed on `wasArmed` — the tracked armed state the caller
    /// last observed — NOT on the final translation: if the terminal sample
    /// crosses back below the threshold without an intervening change sample,
    /// the caller must still be told to disarm, or its `swipeArmed` stays stuck
    /// true forever. The terminal outcome (`saved`/`canceled`/`askRequested`)
    /// resolves from the final translation (`swiped`). When `.armedChanged(false)`
    /// is emitted it always precedes the terminal events.
    static func release(heldFor: TimeInterval, swiped: Bool, wasArmed: Bool) -> [TalkGestureEvent] {
        var events: [TalkGestureEvent] = []
        if wasArmed { events.append(.armedChanged(false)) }
        events.append(contentsOf: TalkGestureOutcome.resolve(heldFor: heldFor, swiped: swiped).terminalEvents)
        return events
    }
}

private struct HoldToTalkGesture: ViewModifier {
    let swipeThreshold: CGFloat
    let onEvent: (TalkGestureEvent) -> Void

    @State private var holdStartedAt: Date?
    @State private var armed = false

    func body(content: Content) -> some View {
        content.gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if holdStartedAt == nil {
                        holdStartedAt = value.time
                        onEvent(.began)
                    }
                    // Edge-triggered arm/disarm: no hysteresis, disarm the
                    // moment translation re-crosses the same threshold.
                    let nowArmed = value.translation.height <= -swipeThreshold
                    if nowArmed != armed {
                        armed = nowArmed
                        onEvent(.armedChanged(nowArmed))
                    }
                }
                .onEnded { value in
                    let startedAt = holdStartedAt
                    holdStartedAt = nil
                    // Capture the tracked armed state before resetting: the
                    // disarm event must key on what the caller last saw, not on
                    // the final translation (which may cross back below the
                    // threshold with no change sample to disarm the caller).
                    let wasArmed = armed
                    armed = false
                    let heldFor = startedAt.map { value.time.timeIntervalSince($0) } ?? 0
                    let swiped = value.translation.height <= -swipeThreshold
                    for event in TalkGestureEvent.release(heldFor: heldFor, swiped: swiped, wasArmed: wasArmed) {
                        onEvent(event)
                    }
                }
        )
    }
}

extension View {
    /// Attach the shared hold-to-talk gesture. `swipeThreshold` is a hand-size
    /// fact (55 phone, 30 watch); everything else is fixed product semantics.
    func holdToTalkGesture(swipeThreshold: CGFloat,
                           onEvent: @escaping (TalkGestureEvent) -> Void) -> some View {
        modifier(HoldToTalkGesture(swipeThreshold: swipeThreshold, onEvent: onEvent))
    }
}
