import XCTest
@testable import GazeFocusCore

// U5: dwell-threshold learning + graduation.
final class DwellModelTests: XCTestCase {

    private func model(_ values: [Instant]) -> DwellModel {
        var m = DwellModel()
        for v in values { m.record(validDwell: v) }
        return m
    }

    func testPercentileThresholdWithinBounds() {
        let m = model(Array(repeating: 0.5, count: 50))
        XCTAssertEqual(m.threshold(), 0.5, accuracy: 1e-9)
    }

    func testThresholdClampsToCeilingAndFloor() {
        XCTAssertEqual(model(Array(repeating: 1.5, count: 10)).threshold(), 1.0, accuracy: 1e-9)
        XCTAssertEqual(model(Array(repeating: 0.1, count: 10)).threshold(), 0.3, accuracy: 1e-9)
    }

    func testUsesPercentileNotMeanOnSkew() {
        // 45 × 0.45 + 5 × 0.95 → p80 = 0.45, mean = 0.50.
        let m = model(Array(repeating: 0.45, count: 45) + Array(repeating: 0.95, count: 5))
        XCTAssertEqual(m.threshold(), 0.45, accuracy: 1e-6)   // percentile, not the 0.50 mean
    }

    func testGraduationCountGate() {
        XCTAssertEqual(model(Array(repeating: 0.5, count: 39)).graduationStatus(capReached: false), .collecting)
        XCTAssertEqual(model(Array(repeating: 0.5, count: 40)).graduationStatus(capReached: false),
                       .graduateLearned(0.5))
    }

    func testWideDistributionDoesNotGraduateLearned() {
        // Bimodal 25 × 0.35 + 25 × 0.95 → spread exceeds the usable bound.
        let m = model(Array(repeating: 0.35, count: 25) + Array(repeating: 0.95, count: 25))
        XCTAssertFalse(m.distributionUsable())
        XCTAssertEqual(m.graduationStatus(capReached: false), .collecting)
        XCTAssertEqual(m.threshold(), 0.6, accuracy: 1e-9)    // pinned to default
    }

    func testCollectionCapGraduatesWithDefault() {
        let m = model(Array(repeating: 0.5, count: 10))
        XCTAssertEqual(m.graduationStatus(capReached: true), .graduateDefault(0.6))
    }

    func testRevertNudgeLengthensThreshold() {
        var m = model(Array(repeating: 0.5, count: 50))
        XCTAssertEqual(m.threshold(), 0.5, accuracy: 1e-9)
        m.recordOutcome(reverted: true)
        XCTAssertEqual(m.threshold(), 0.6, accuracy: 1e-9)    // +revertStep
        XCTAssertEqual(m.sampleCount, 50)                     // outcomes don't touch the dwell buffer
    }

    func testSustainedRevertsTripNetNegative() {
        var m = model(Array(repeating: 0.5, count: 50))
        for _ in 0..<4 { m.recordOutcome(reverted: true) }
        XCTAssertTrue(m.isNetNegative())
    }
}
