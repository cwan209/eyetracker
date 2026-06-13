import XCTest
@testable import GazeFocusCore

// U14: lifecycle reducer.
final class LifecycleTests: XCTestCase {
    private let r = LifecycleReducer()

    private func snap(_ s: LifecycleState, fresh: Bool = false, resume: LifecycleState? = nil) -> LifecycleSnapshot {
        LifecycleSnapshot(state: s, requireFreshGaze: fresh, resumeState: resume)
    }

    func testColdStartPath() {
        var s = LifecycleSnapshot()                                   // idle
        s = r.reduce(s, .startCollecting);          XCTAssertEqual(s.state, .collecting)
        s = r.reduce(s, .learning(.graduated));     XCTAssertEqual(s.state, .ready)
        s = r.reduce(s, .learning(.enabled));       XCTAssertEqual(s.state, .calibrating)
        s = r.reduce(s, .learning(.calibrated));    XCTAssertEqual(s.state, .active)
    }

    func testPauseResume() {
        XCTAssertEqual(r.reduce(snap(.active), .pause).state, .paused)
        XCTAssertEqual(r.reduce(snap(.paused), .resume).state, .active)
    }

    func testSleepSuspendsAndWakeRequiresFreshGaze() {
        let suspended = r.reduce(snap(.active), .system(.sleep))
        XCTAssertEqual(suspended.state, .suspended)
        XCTAssertEqual(suspended.resumeState, .active)
        let woke = r.reduce(suspended, .system(.wake))
        XCTAssertEqual(woke.state, .active)
        XCTAssertTrue(woke.requireFreshGaze)
    }

    func testFreshGazeSeenClearsFlag() {
        let cleared = r.reduce(snap(.active, fresh: true), .learning(.freshGazeSeen))
        XCTAssertEqual(cleared.state, .active)
        XCTAssertFalse(cleared.requireFreshGaze)
    }

    func testRaceSafetyNeverActiveWhileLocked() {
        // Lock then a stray graduation event must not resurrect Active.
        let locked = r.reduce(snap(.active), .system(.lock))
        XCTAssertEqual(locked.state, .suspended)
        let afterStrayGraduation = r.reduce(locked, .learning(.graduated))
        XCTAssertEqual(afterStrayGraduation.state, .suspended)        // identity, still safe
        // Unlock returns to the remembered state.
        let unlocked = r.reduce(afterStrayGraduation, .system(.unlock))
        XCTAssertEqual(unlocked.state, .active)
        XCTAssertTrue(unlocked.requireFreshGaze)
    }

    func testGraduateThenLockReturnsToReady() {
        let ready = r.reduce(snap(.collecting), .learning(.graduated))
        XCTAssertEqual(ready.state, .ready)
        let suspended = r.reduce(ready, .system(.lock))
        XCTAssertEqual(suspended.resumeState, .ready)
        let unlocked = r.reduce(suspended, .system(.unlock))
        XCTAssertEqual(unlocked.state, .ready)
        XCTAssertFalse(unlocked.requireFreshGaze)                     // only active arms the gate
    }

    func testUndefinedTransitionsAreIdentity() {
        XCTAssertEqual(r.reduce(snap(.idle), .learning(.graduated)).state, .idle)
        XCTAssertEqual(r.reduce(snap(.active), .system(.displayChanged)).state, .active)
        XCTAssertEqual(r.reduce(snap(.idle), .resume).state, .idle)
    }
}
