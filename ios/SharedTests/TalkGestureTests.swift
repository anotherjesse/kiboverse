import XCTest
#if canImport(Kibo)
@testable import Kibo
#else
@testable import Kibo_Watch
#endif

/// The shared hold-to-talk gesture: one truth table and one release event
/// sequence, exercised as pure functions (the DragGesture layer is a thin
/// shell over them). No UI-gesture synthesis — `WatchPushToTalkTests` is the
/// real-hit-testing drift alarm.
final class TalkGestureTests: XCTestCase {

    // MARK: - Outcome truth table

    func testResolveDiscard() {
        // Sub-second, no swipe: capture discarded.
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 0.5, swiped: false), .discard)
    }

    func testResolveSave() {
        // 1s+, no swipe: clip saved.
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 1.5, swiped: false), .save)
    }

    func testResolveSaveAndAsk() {
        // 1s+ with a swipe: clip saved and Kibo asked.
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 1.5, swiped: true), .saveAndAsk)
    }

    func testResolveAskPending() {
        // Sub-second flick up: ask with what's already pending.
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 0.5, swiped: true), .askPending)
    }

    // MARK: - Record threshold boundary (exactly 1.0s)

    func testExactThresholdIsARecording() {
        // The boundary belongs to "recorded": heldFor == recordThreshold saves.
        XCTAssertEqual(TalkGestureOutcome.recordThreshold, 1.0)
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 1.0, swiped: false), .save)
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 1.0, swiped: true), .saveAndAsk)
    }

    func testJustBelowThresholdDiscards() {
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 0.999, swiped: false), .discard)
        XCTAssertEqual(TalkGestureOutcome.resolve(heldFor: 0.999, swiped: true), .askPending)
    }

    // MARK: - Release event sequences (normal case: wasArmed == final swiped)

    func testDiscardEmitsCanceledOnly() {
        // Not armed: no `.armedChanged(false)`, no ask.
        XCTAssertEqual(TalkGestureEvent.release(heldFor: 0.5, swiped: false, wasArmed: false), [.canceled])
    }

    func testSaveEmitsSavedOnly() {
        XCTAssertEqual(TalkGestureEvent.release(heldFor: 1.5, swiped: false, wasArmed: false), [.saved])
    }

    func testSaveAndAskDisarmsThenSavesThenAsks() {
        XCTAssertEqual(
            TalkGestureEvent.release(heldFor: 1.5, swiped: true, wasArmed: true),
            [.armedChanged(false), .saved, .askRequested]
        )
    }

    func testAskPendingDisarmsThenCancelsThenAsks() {
        XCTAssertEqual(
            TalkGestureEvent.release(heldFor: 0.5, swiped: true, wasArmed: true),
            [.armedChanged(false), .canceled, .askRequested]
        )
    }

    // MARK: - Tracked-armed disarm (edge case: sample gap at release)

    /// The last change sample armed the gesture, but the terminal sample
    /// crosses back below the threshold with no intervening change sample. The
    /// terminal outcome resolves from the final (un-swiped) translation — save
    /// or discard, never an ask — yet the caller MUST still be disarmed, or its
    /// `swipeArmed` stays stuck true forever (the modifier's own state already
    /// reset). Disarm therefore keys on the tracked `wasArmed`, not on `swiped`.
    func testTrackedArmedButFinalNotSwipedStillDisarmsSavesNoAsk() {
        let events = TalkGestureEvent.release(heldFor: 1.5, swiped: false, wasArmed: true)
        XCTAssertEqual(events, [.armedChanged(false), .saved])
        XCTAssertFalse(events.contains(.askRequested))
    }

    func testTrackedArmedButFinalNotSwipedShortHoldDisarmsCancelsNoAsk() {
        let events = TalkGestureEvent.release(heldFor: 0.5, swiped: false, wasArmed: true)
        XCTAssertEqual(events, [.armedChanged(false), .canceled])
        XCTAssertFalse(events.contains(.askRequested))
    }

    /// The mirror gap: never tracked-armed, but the final sample is past the
    /// threshold. The ask fires (terminal keys on `swiped`) and no disarm is
    /// emitted — the caller was never armed, so nothing is stuck.
    func testFinalSwipedButNeverArmedAsksWithoutDisarm() {
        let events = TalkGestureEvent.release(heldFor: 1.5, swiped: true, wasArmed: false)
        XCTAssertEqual(events, [.saved, .askRequested])
        XCTAssertFalse(events.contains(.armedChanged(false)))
    }

    // MARK: - Ordering invariants

    func testArmedReleaseDisarmsBeforeAnyTerminal() {
        // On every tracked-armed release, `.armedChanged(false)` is first.
        for heldFor in [0.5, 1.0, 1.5] {
            for swiped in [true, false] {
                let events = TalkGestureEvent.release(heldFor: heldFor, swiped: swiped, wasArmed: true)
                XCTAssertEqual(events.first, .armedChanged(false),
                               "tracked-armed release held \(heldFor)s (swiped \(swiped)) must disarm before terminals")
            }
        }
    }

    func testNonArmedReleaseNeverDisarms() {
        for heldFor in [0.5, 1.0, 1.5] {
            for swiped in [true, false] {
                let events = TalkGestureEvent.release(heldFor: heldFor, swiped: swiped, wasArmed: false)
                XCTAssertFalse(events.contains(.armedChanged(false)),
                               "non-tracked-armed release held \(heldFor)s (swiped \(swiped)) must not emit disarm")
            }
        }
    }

    func testTerminalPrecedesAskRequested() {
        // `.saved`/`.canceled` always precede `.askRequested`.
        let saveAndAsk = TalkGestureEvent.release(heldFor: 1.5, swiped: true, wasArmed: true)
        XCTAssertLessThan(saveAndAsk.firstIndex(of: .saved)!,
                          saveAndAsk.firstIndex(of: .askRequested)!)

        let askPending = TalkGestureEvent.release(heldFor: 0.5, swiped: true, wasArmed: true)
        XCTAssertLessThan(askPending.firstIndex(of: .canceled)!,
                          askPending.firstIndex(of: .askRequested)!)
    }

    func testAskRequestedOnlyOnFinalSwipe() {
        // The ask keys on the final translation, independent of tracked arming.
        for wasArmed in [true, false] {
            XCTAssertFalse(TalkGestureEvent.release(heldFor: 0.5, swiped: false, wasArmed: wasArmed).contains(.askRequested))
            XCTAssertFalse(TalkGestureEvent.release(heldFor: 1.5, swiped: false, wasArmed: wasArmed).contains(.askRequested))
            XCTAssertTrue(TalkGestureEvent.release(heldFor: 0.5, swiped: true, wasArmed: wasArmed).contains(.askRequested))
            XCTAssertTrue(TalkGestureEvent.release(heldFor: 1.5, swiped: true, wasArmed: wasArmed).contains(.askRequested))
        }
    }
}
