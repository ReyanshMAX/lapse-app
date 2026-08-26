import XCTest
@testable import StudyLapseCore

final class TimeAxisTests: XCTestCase {
    func testStudySeconds() {
        XCTAssertEqual(TimeAxis.studySeconds(clipOffset: 120, frameIndex: 4, interval: 3), 132)
    }

    func testTotalStudySecondsSumsClipDurations() {
        XCTAssertEqual(TimeAxis.totalStudySeconds(clipDurations: [120, 300, 60]), 480)
    }

    func testMinimumSpeed() {
        XCTAssertEqual(TimeAxis.minimumSpeed(interval: 3, fps: 30), 90)
    }

    func testFitToDurationClampsToMinimumSpeedFloor() {
        // 9-hour session, 3s interval, 30fps: base output = 32400/3/30 = 360s.
        // Requested 15s implies speed 24, below the 90x floor, so it clamps to 90.
        let totalStudySeconds = 9 * 60 * 60.0
        let speed = TimeAxis.speed(mode: .fitToDuration(targetSeconds: 15),
                                    totalStudySeconds: totalStudySeconds,
                                    interval: 3, fps: 30)
        XCTAssertEqual(speed, 90)
    }

    func testMultiplierAboveFloorIsUnchanged() {
        let speed = TimeAxis.speed(mode: .multiplier(150),
                                    totalStudySeconds: 1000,
                                    interval: 3, fps: 30)
        XCTAssertEqual(speed, 150)
    }

    func testMultiplierBelowFloorClampsUp() {
        let speed = TimeAxis.speed(mode: .multiplier(10),
                                    totalStudySeconds: 1000,
                                    interval: 3, fps: 30)
        XCTAssertEqual(speed, 90)
    }
}
