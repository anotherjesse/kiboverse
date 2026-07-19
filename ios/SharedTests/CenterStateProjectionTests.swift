import XCTest
#if canImport(Kibo)
@testable import Kibo
#else
@testable import Kibo_Watch
#endif

/// The `CenterState` projection contract: every case maps to exactly one
/// status line, one accent/text split, one face sprite, and one constellation
/// mode. These are the values the shared renderers (StatusLabel, KiboFace,
/// ConstellationView) read and the screenshot walks depend on — pinned here so
/// a copy edit or a sprite swap is a deliberate, reviewed change rather than a
/// silent drift. Enumerates in both the phone (Kibo) and watch (Kibo_Watch)
/// test targets from Shared.
final class CenterStateProjectionTests: XCTestCase {
    private struct Expectation {
        let state: CenterState
        let statusLine: String
        let accent: String?
        let text: String
        let faceAssetName: String
        let mode: ConstellationMode
        let line: UInt

        init(
            _ state: CenterState,
            statusLine: String,
            accent: String?,
            text: String,
            face: String,
            mode: ConstellationMode,
            line: UInt = #line
        ) {
            self.state = state
            self.statusLine = statusLine
            self.accent = accent
            self.text = text
            self.faceAssetName = face
            self.mode = mode
            self.line = line
        }
    }

    /// One row per case, including the three idle variants (pending, saved,
    /// empty) and an error.
    private let table: [Expectation] = [
        Expectation(
            .noConversation,
            statusLine: "", accent: nil, text: "",
            face: "face-sleepy", mode: .idle
        ),
        Expectation(
            .swipeArmed,
            statusLine: "Release to ask", accent: nil, text: "Release to ask",
            face: "face-excited", mode: .recording
        ),
        Expectation(
            .starting,
            statusLine: "Opening microphone…", accent: nil, text: "Opening microphone…",
            face: "face-neutral", mode: .recording
        ),
        Expectation(
            .recording,
            statusLine: "Listening…", accent: nil, text: "Listening…",
            face: "face-neutral", mode: .recording
        ),
        Expectation(
            .error("Microphone unavailable"),
            statusLine: "Microphone unavailable", accent: nil, text: "Microphone unavailable",
            face: "face-confused", mode: .idle
        ),
        Expectation(
            .sending,
            statusLine: "Sending…", accent: nil, text: "Sending…",
            face: "face-content", mode: .thinking
        ),
        Expectation(
            .thinking,
            statusLine: "Kibo is thinking…", accent: nil, text: "Kibo is thinking…",
            face: "face-thinking", mode: .thinking
        ),
        Expectation(
            .loadingReply,
            statusLine: "Loading reply…", accent: nil, text: "Loading reply…",
            face: "face-content", mode: .thinking
        ),
        Expectation(
            .speaking,
            statusLine: "Kibo is speaking", accent: nil, text: "Kibo is speaking",
            face: "face-happy", mode: .speaking
        ),
        Expectation(
            .replyDone,
            statusLine: "Reply played", accent: nil, text: "Reply played",
            face: "face-serene", mode: .afterglow
        ),
        Expectation(
            .needsReview,
            statusLine: "Recording needs review", accent: nil, text: "Recording needs review",
            face: "face-worried", mode: .idle
        ),
        Expectation(
            .attention,
            statusLine: "", accent: nil, text: "",
            face: "face-worried", mode: .idle
        ),
        Expectation(
            .idle(pendingCount: 2, savedCount: 1),
            statusLine: "2 pending", accent: "2", text: " pending",
            face: "face-neutral", mode: .idle
        ),
        Expectation(
            .idle(pendingCount: 0, savedCount: 2),
            statusLine: "2 saved", accent: nil, text: "2 saved",
            face: "face-neutral", mode: .idle
        ),
        Expectation(
            .idle(pendingCount: 0, savedCount: 0),
            statusLine: "", accent: nil, text: "",
            face: "face-neutral", mode: .idle
        ),
    ]

    func testProjectionContractPerCase() {
        for row in table {
            XCTAssertEqual(
                row.state.statusLine, row.statusLine,
                "statusLine for \(row.state)", line: row.line
            )
            XCTAssertEqual(
                row.state.status, StatusContent(accent: row.accent, text: row.text),
                "status split for \(row.state)", line: row.line
            )
            XCTAssertEqual(
                row.state.faceAssetName, row.faceAssetName,
                "faceAssetName for \(row.state)", line: row.line
            )
            XCTAssertEqual(
                row.state.constellationMode, row.mode,
                "constellationMode for \(row.state)", line: row.line
            )
        }
    }

    /// The table must cover every `CenterState` case, so a new case can't slip
    /// past the contract. This mirrors the enum's shape; a compiler error here
    /// is the reminder to add both the case and its projection row.
    func testTableCoversEveryCase() {
        for state in Self.allCases {
            XCTAssertTrue(
                table.contains { $0.state == state },
                "Projection table is missing a row for \(state)"
            )
        }
        // Each non-idle case appears once; idle appears as its three variants.
        XCTAssertEqual(table.count, Self.allCases.count + 2)
    }

    /// Every enum case, one representative value each. The `switch` below has
    /// no `default`, so adding a `CenterState` case fails to compile until it
    /// is listed here too.
    private static let allCases: [CenterState] = {
        func exhaustive(_ state: CenterState) -> CenterState {
            switch state {
            case .noConversation, .swipeArmed, .starting, .recording, .error,
                 .sending, .thinking, .loadingReply, .speaking, .replyDone,
                 .needsReview, .attention, .idle:
                return state
            }
        }
        return [
            .noConversation, .swipeArmed, .starting, .recording,
            .error("Microphone unavailable"), .sending, .thinking, .loadingReply,
            .speaking, .replyDone, .needsReview, .attention,
            .idle(pendingCount: 2, savedCount: 1),
        ].map(exhaustive)
    }()
}
