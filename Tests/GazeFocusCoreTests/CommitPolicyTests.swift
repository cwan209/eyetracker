import XCTest
@testable import GazeFocusCore

// U4: commit policy fail-safe gate chain + armed undo.
final class CommitPolicyTests: XCTestCase {

    /// A fully-passing input (would switch from window 1 to window 2). Override
    /// one field per test to exercise a single gate.
    private func happyInput(
        now: Instant = 0.7,
        fixation: FixationDetector.Output = .fixation(point: Point2D(x: 600, y: 300), since: 0.0),
        confidence: Double = 1.0,
        target: WindowID? = 2,
        liveTargetCount: Int = 2,
        typingSuppressed: Bool = false,
        dwellThreshold: Instant = 0.6,
        requireFreshGaze: Bool = false,
        currentFocused: WindowID? = 1,
        targetStillLive: Bool = true
    ) -> CommitPolicy.Input {
        CommitPolicy.Input(now: now, fixation: fixation, confidence: confidence, target: target,
                           liveTargetCount: liveTargetCount, typingSuppressed: typingSuppressed,
                           dwellThreshold: dwellThreshold, requireFreshGaze: requireFreshGaze,
                           currentFocused: currentFocused, targetStillLive: targetStillLive)
    }

    func testHappyPathSwitches() {              // AE1
        var p = CommitPolicy()
        XCTAssertEqual(p.evaluate(happyInput()).decision, .switchTo(2))
    }

    func testTypingSuppressionHolds() {         // AE2
        var p = CommitPolicy()
        XCTAssertEqual(p.evaluate(happyInput(typingSuppressed: true)).decision, .hold)
    }

    func testGlanceUnderThresholdHolds() {      // AE3
        var p = CommitPolicy()
        // dwell elapsed = 0.3 < 0.6 threshold
        XCTAssertEqual(p.evaluate(happyInput(now: 0.3)).decision, .hold)
    }

    func testAlreadyFocusedIsNoOp() {           // AE5
        var p = CommitPolicy()
        let r = p.evaluate(happyInput(target: 1, currentFocused: 1))
        XCTAssertEqual(r.decision, .hold)
        XCTAssertNil(p.armedUndo)
    }

    func testTargetVanishedHolds() {            // AE4
        var p = CommitPolicy()
        XCTAssertEqual(p.evaluate(happyInput(targetStillLive: false)).decision, .hold)
    }

    func testFewerThanTwoTargetsHolds() {       // AE6 logic-side
        var p = CommitPolicy()
        XCTAssertEqual(p.evaluate(happyInput(liveTargetCount: 1)).decision, .hold)
    }

    func testLowConfidenceHolds() {
        var p = CommitPolicy()
        XCTAssertEqual(p.evaluate(happyInput(confidence: 0.2)).decision, .hold)
    }

    func testNoFixationHolds() {
        var p = CommitPolicy()
        XCTAssertEqual(p.evaluate(happyInput(fixation: .none)).decision, .hold)
    }

    func testPostWakeGateEmitsFreshGazeAndHolds() {
        var p = CommitPolicy()
        let r = p.evaluate(happyInput(requireFreshGaze: true))
        XCTAssertEqual(r.decision, .hold)
        XCTAssertEqual(r.effects, [.freshGazeSeen])
        // Once the flag is cleared, the next evaluation switches.
        XCTAssertEqual(p.evaluate(happyInput(requireFreshGaze: false)).decision, .switchTo(2))
    }
}

final class ArmedUndoTests: XCTestCase {
    private func happyInput(now: Instant) -> CommitPolicy.Input {
        CommitPolicy.Input(now: now, fixation: .fixation(point: Point2D(x: 600, y: 300), since: now - 0.7),
                           confidence: 1.0, target: 2, liveTargetCount: 2, typingSuppressed: false,
                           dwellThreshold: 0.6, requireFreshGaze: false, currentFocused: 1, targetStillLive: true)
    }

    func testRecoverWithinWindowRestoresPrevious() {   // AE9 logic-side
        var p = CommitPolicy(config: .init(recoveryWindow: 3.0))
        XCTAssertEqual(p.evaluate(happyInput(now: 10.0)).decision, .switchTo(2))
        XCTAssertEqual(p.recover(now: 12.0), .switchTo(1))   // within 3s, restores prev focus
    }

    func testRecoverAfterWindowIsNoOp() {
        var p = CommitPolicy(config: .init(recoveryWindow: 3.0))
        _ = p.evaluate(happyInput(now: 10.0))
        XCTAssertEqual(p.recover(now: 14.0), .hold)          // past the window
    }
}
