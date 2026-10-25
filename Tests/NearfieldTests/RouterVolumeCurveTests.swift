import XCTest
@testable import Nearfield

final class RouterVolumeCurveTests: XCTestCase {
    private let minimum: Float32 = -63.5
    private let span: Float32 = 63.5

    func testDisplayCurveMatchesTheStudioDisplays() {
        // Measured on two Studio Displays, which round to 0.5 dB.
        let measured: [(scalar: Float32, decibels: Float32)] = [
            (0.0625, -47.5), (0.125, -41), (0.25, -31.5), (0.375, -24.5),
            (0.5, -18.5), (0.625, -13.5), (0.75, -8.5), (0.875, -4), (1, 0)
        ]
        for point in measured {
            let decibels = RouterVolumeCurve.display.decibels(forScalar: point.scalar, minimum: minimum, span: span)
            XCTAssertEqual(decibels, point.decibels, accuracy: 0.5)
            XCTAssertEqual(
                RouterVolumeCurve.display.scalar(forDecibels: decibels, minimum: minimum, span: span),
                point.scalar,
                accuracy: 0.0001
            )
        }
    }

    func testTheReportedLevelIdentifiesTheCurve() {
        XCTAssertEqual(
            RouterVolumeCurve.matching(scalar: 0.5, reportedDecibels: -31.75, minimum: minimum, span: span),
            .linearDecibels
        )
        XCTAssertEqual(
            RouterVolumeCurve.matching(scalar: 0.5, reportedDecibels: -18.6, minimum: minimum, span: span),
            .display
        )
        XCTAssertNil(RouterVolumeCurve.matching(scalar: 0.5, reportedDecibels: -25, minimum: minimum, span: span))
    }

    func testUpgradeKeepsTheLevel() {
        for scalar: Float32 in [0, 0.1, 0.5, 0.8, 1] {
            let before = RouterVolumeCurve.linearDecibels.decibels(forScalar: scalar, minimum: minimum, span: span)
            let converted = RouterVolumeCurve.displayScalarKeepingLevel(ofLinearScalar: scalar)
            let after = RouterVolumeCurve.display.decibels(forScalar: converted, minimum: minimum, span: span)
            XCTAssertEqual(after, before, accuracy: 0.001)
        }
    }

    func testOnlyUpgradesFromBeforeDriver120ChangeTheCurve() {
        XCTAssertTrue(RouterVolumeCurve.upgradeChangesCurve(from: "1.1.0", to: "1.2.0"))
        XCTAssertTrue(RouterVolumeCurve.upgradeChangesCurve(from: "1.0", to: "1.3.0"))
        XCTAssertFalse(RouterVolumeCurve.upgradeChangesCurve(from: "1.2.0", to: "1.3.0"))
        XCTAssertFalse(RouterVolumeCurve.upgradeChangesCurve(from: nil, to: "1.2.0"))
        XCTAssertFalse(RouterVolumeCurve.upgradeChangesCurve(from: "1.0.0", to: "1.1.0"))
    }

    func testRememberedVolumeKeepsItsLevel() {
        var continuity = RouterVolumeContinuity()
        continuity.keepLevelAfterCurveChange()
        XCTAssertNil(continuity.lastKnownVolume)
        continuity.observe(0.5)
        continuity.keepLevelAfterCurveChange()
        XCTAssertEqual(continuity.lastKnownVolume, 0.25)
    }
}
