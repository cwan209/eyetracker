import XCTest
@testable import GazeFocusCore

// U3: I-DT fixation detection + zone mapping.
final class FixationTests: XCTestCase {
    private func sample(_ t: Instant, _ x: Double, _ y: Double, _ c: Double = 1.0) -> GazeSample {
        GazeSample(t: t, point: Point2D(x: x, y: y), confidence: c)
    }

    func testStableClusterEmitsFixation() {
        var d = FixationDetector(config: .init(dispersionThreshold: 40, minDuration: 0.1))
        XCTAssertEqual(d.add(sample(0.0, 100, 100)), .none)        // duration 0
        XCTAssertEqual(d.add(sample(0.05, 105, 98)), .none)        // < minDuration
        let out = d.add(sample(0.12, 102, 101))                    // spans 0.12s, tight
        guard case let .fixation(point, since) = out else { return XCTFail("expected fixation") }
        XCTAssertEqual(since, 0.0, accuracy: 1e-9)
        XCTAssertEqual(point.x, (100 + 105 + 102) / 3.0, accuracy: 1e-9)
        XCTAssertEqual(point.y, (100 + 98 + 101) / 3.0, accuracy: 1e-9)
    }

    func testSaccadeProducesNoFixation() {
        var d = FixationDetector(config: .init(dispersionThreshold: 40, minDuration: 0.1))
        XCTAssertEqual(d.add(sample(0.0, 0, 0)), .none)
        XCTAssertEqual(d.add(sample(0.05, 400, 0)), .none)         // big jump → window shrinks
        XCTAssertEqual(d.add(sample(0.10, 800, 0)), .none)         // still moving, no stable run
    }

    func testLowConfidenceBreaksFixation() {
        var d = FixationDetector(config: .init(dispersionThreshold: 40, minDuration: 0.1, minConfidence: 0.5))
        _ = d.add(sample(0.0, 100, 100))
        _ = d.add(sample(0.06, 101, 100))
        XCTAssertEqual(d.add(sample(0.12, 100, 101, 0.2)), .none)  // low confidence resets
        XCTAssertEqual(d.add(sample(0.13, 100, 101, 0.2)), .none)
    }

    func testSilentGapDoesNotInflateDwell() {
        // A silent stream gap (no low-confidence sample) at the same spot must NOT
        // be read as one continuous 10s fixation — that would cause a wrong switch.
        var d = FixationDetector(config: .init(dispersionThreshold: 40, minDuration: 0.1, maxGap: 0.3))
        _ = d.add(sample(1.00, 100, 100))
        _ = d.add(sample(1.05, 101, 100))
        XCTAssertEqual(d.add(sample(11.00, 101, 100)), .none)      // gap > maxGap → fresh run
        // A fresh stable run after the gap still works.
        _ = d.add(sample(11.06, 101, 100))
        guard case let .fixation(_, since) = d.add(sample(11.12, 100, 101)) else {
            return XCTFail("expected a fresh fixation after the gap")
        }
        XCTAssertEqual(since, 11.00, accuracy: 1e-9)              // since the gap, not 1.00
    }

    func testNonMonotonicSampleIsIgnored() {
        var d = FixationDetector(config: .init(dispersionThreshold: 40, minDuration: 0.1))
        _ = d.add(sample(0.0, 100, 100))
        _ = d.add(sample(0.06, 101, 100))
        let stable = d.add(sample(0.12, 100, 101))
        guard case .fixation = stable else { return XCTFail("expected fixation") }
        // An out-of-order sample must not corrupt the fixation's start instant.
        guard case let .fixation(_, since) = d.add(sample(0.04, 999, 999)) else {
            return XCTFail("expected the fixation to persist")
        }
        XCTAssertEqual(since, 0.0, accuracy: 1e-9)
    }
}

final class ZoneMapTests: XCTestCase {
    private let left = WindowSnapshot(id: 1, ownerPID: 10, ownerName: "iTerm2",
                                      bounds: Rect(x: 0, y: 0, width: 400, height: 600))
    private let right = WindowSnapshot(id: 2, ownerPID: 11, ownerName: "iTerm2",
                                       bounds: Rect(x: 400, y: 0, width: 400, height: 600))

    func testResolvesInteriorPoint() {
        let m = ZoneMapper()
        XCTAssertEqual(m.resolve(point: Point2D(x: 200, y: 300), windows: [left, right]), .window(1))
        XCTAssertEqual(m.resolve(point: Point2D(x: 600, y: 300), windows: [left, right]), .window(2))
    }

    func testBorderDeadbandHolds() {
        let m = ZoneMapper(config: .init(borderDeadband: 12, maxWindows: 4, minWindowSize: 150))
        // x=398 is within 12pt of the shared 400 border on the left window's edge.
        XCTAssertEqual(m.resolve(point: Point2D(x: 398, y: 300), windows: [left, right]), Target.none)
    }

    func testTooManyWindowsHolds() {
        let m = ZoneMapper(config: .init(borderDeadband: 12, maxWindows: 4, minWindowSize: 50))
        let five = (0..<5).map { i in
            WindowSnapshot(id: i, ownerPID: 1, ownerName: "t",
                           bounds: Rect(x: Double(i) * 100, y: 0, width: 90, height: 600))
        }
        XCTAssertEqual(m.resolve(point: Point2D(x: 45, y: 300), windows: five), Target.none)
    }

    func testTooSmallWindowNotSelectable() {
        let m = ZoneMapper(config: .init(borderDeadband: 4, maxWindows: 4, minWindowSize: 150))
        let tiny = WindowSnapshot(id: 9, ownerPID: 1, ownerName: "t",
                                  bounds: Rect(x: 0, y: 0, width: 80, height: 80))
        XCTAssertEqual(m.resolve(point: Point2D(x: 40, y: 40), windows: [tiny]), Target.none)
    }

    func testCalibrationShiftsTarget() {
        let m = ZoneMapper()
        let raw = Point2D(x: 200, y: 300)   // raw lands in left
        XCTAssertEqual(m.resolve(point: raw, windows: [left, right]), .window(1))
        let cal = CalibrationOffset(translation: Point2D(x: 400, y: 0))  // shift into right
        XCTAssertEqual(m.resolve(point: raw, windows: [left, right], calibration: cal), .window(2))
    }
}
