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

    // MARK: - Release event sequences

    func testDiscardEmitsCanceledOnly() {
        // Not armed: no `.armedChanged(false)`, no ask.
        XCTAssertEqual(TalkGestureEvent.release(heldFor: 0.5, swiped: false), [.canceled])
    }

    func testSaveEmitsSavedOnly() {
        XCTAssertEqual(TalkGestureEvent.release(heldFor: 1.5, swiped: false), [.saved])
    }

    func testSaveAndAskDisarmsThenSavesThenAsks() {
        XCTAssertEqual(
            TalkGestureEvent.release(heldFor: 1.5, swiped: true),
            [.armedChanged(false), .saved, .askRequested]
        )
    }

    func testAskPendingDisarmsThenCancelsThenAsks() {
        XCTAssertEqual(
            TalkGestureEvent.release(heldFor: 0.5, swiped: true),
            [.armedChanged(false), .canceled, .askRequested]
        )
    }

    // MARK: - Ordering invariants

    func testArmedReleaseDisarmsBeforeAnyTerminal() {
        // On every armed (swiped) release, `.armedChanged(false)` is first.
        for heldFor in [0.5, 1.0, 1.5] {
            let events = TalkGestureEvent.release(heldFor: heldFor, swiped: true)
            XCTAssertEqual(events.first, .armedChanged(false),
                           "armed release held \(heldFor)s must disarm before terminals")
        }
    }

    func testNonArmedReleaseNeverDisarms() {
        for heldFor in [0.5, 1.0, 1.5] {
            let events = TalkGestureEvent.release(heldFor: heldFor, swiped: false)
            XCTAssertFalse(events.contains(.armedChanged(false)),
                           "non-armed release held \(heldFor)s must not emit disarm")
        }
    }

    func testTerminalPrecedesAskRequested() {
        // `.saved`/`.canceled` always precede `.askRequested`.
        let saveAndAsk = TalkGestureEvent.release(heldFor: 1.5, swiped: true)
        XCTAssertLessThan(saveAndAsk.firstIndex(of: .saved)!,
                          saveAndAsk.firstIndex(of: .askRequested)!)

        let askPending = TalkGestureEvent.release(heldFor: 0.5, swiped: true)
        XCTAssertLessThan(askPending.firstIndex(of: .canceled)!,
                          askPending.firstIndex(of: .askRequested)!)
    }

    func testAskRequestedOnlyOnSwipe() {
        XCTAssertFalse(TalkGestureEvent.release(heldFor: 0.5, swiped: false).contains(.askRequested))
        XCTAssertFalse(TalkGestureEvent.release(heldFor: 1.5, swiped: false).contains(.askRequested))
        XCTAssertTrue(TalkGestureEvent.release(heldFor: 0.5, swiped: true).contains(.askRequested))
        XCTAssertTrue(TalkGestureEvent.release(heldFor: 1.5, swiped: true).contains(.askRequested))
    }
}
