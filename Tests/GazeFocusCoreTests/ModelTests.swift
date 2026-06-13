import XCTest
@testable import GazeFocusCore

// U1/U2: scaffold smoke + domain model.
final class ModelTests: XCTestCase {
    func testPackageImports() {
        XCTAssertEqual(LifecycleState.allCases.count, 7)
    }

    func testRectContainsAndInset() {
        let r = Rect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertTrue(r.contains(Point2D(x: 50, y: 50)))
        XCTAssertFalse(r.contains(Point2D(x: 150, y: 50)))
        let inset = r.insetBy(10)
        XCTAssertFalse(inset.contains(Point2D(x: 5, y: 50)))   // inside band
        XCTAssertTrue(inset.contains(Point2D(x: 50, y: 50)))
        XCTAssertEqual(r.center, Point2D(x: 50, y: 50))
    }

    func testCalibrationApply() {
        let c = CalibrationOffset(scale: Point2D(x: 1, y: 1), translation: Point2D(x: 200, y: 0))
        XCTAssertEqual(c.apply(to: Point2D(x: 50, y: 10)), Point2D(x: 250, y: 10))
        XCTAssertEqual(CalibrationOffset.identity.apply(to: Point2D(x: 7, y: 9)), Point2D(x: 7, y: 9))
    }

    func testFocusDecisionEquatable() {
        XCTAssertEqual(FocusDecision.switchTo(3), .switchTo(3))
        XCTAssertNotEqual(FocusDecision.switchTo(3), .hold)
    }
}
