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

    // MARK: outputDuration — the number the export UI shows and the value the
    // composition is scaled to (BUILD.md Phase 3 criterion 2).

    func testOutputDurationForAMultiplier() {
        // 480s study, 3s interval, 30fps: base output = 480/3/30 = 5.333s.
        // Speed 100x is above the 90x floor, so output = 5.333 / 100.
        let d = TimeAxis.outputDuration(mode: .multiplier(100),
                                        totalStudySeconds: 480,
                                        interval: 3, fps: 30)
        XCTAssertEqual(d, (480.0 / 3 / 30) / 100, accuracy: 1e-9)
    }

    func testFitToDurationHitsTheRequestedDurationWhenAboveFloor() {
        // Short interval so the min-speed floor doesn't bind and the request is
        // honoured exactly. total = 32400s, interval 0.1, fps 30 →
        // base = 32400 / 0.1 / 30 = 10800s. floor = 0.1 * 30 = 3x. requested
        // speed for a 30s target = 10800 / 30 = 360x, well above the floor, so
        // the output is exactly 30s.
        let total = 9 * 3600.0
        let d = TimeAxis.outputDuration(mode: .fitToDuration(targetSeconds: 30),
                                        totalStudySeconds: total,
                                        interval: 0.1, fps: 30)
        XCTAssertEqual(d, 30, accuracy: 1e-6)
    }

    func testFitToDurationReportsTheClampedDurationNotTheRequest() {
        // 9-hour, 3s interval, 30fps. Request fit-to-15s. Floor 90x binds, so
        // the real output is base/90 = 360/90 = 4.0s, and the UI must show 4.0,
        // never 15.
        let total = 9 * 3600.0
        let d = TimeAxis.outputDuration(mode: .fitToDuration(targetSeconds: 15),
                                        totalStudySeconds: total,
                                        interval: 3, fps: 30)
        XCTAssertEqual(d, 4.0, accuracy: 1e-6)
    }

    func testOutputDurationIsConsistentWithSpeed() {
        // base / speed == outputDuration, for any mode.
        let total = 1234.0
        for mode in [SpeedMode.multiplier(120), .multiplier(5),
                     .fitToDuration(targetSeconds: 8), .fitToDuration(targetSeconds: 1)] {
            let base = TimeAxis.baseOutputSeconds(totalStudySeconds: total, interval: 3, fps: 30)
            let speed = TimeAxis.speed(mode: mode, totalStudySeconds: total, interval: 3, fps: 30)
            let d = TimeAxis.outputDuration(mode: mode, totalStudySeconds: total, interval: 3, fps: 30)
            XCTAssertEqual(d, base / speed, accuracy: 1e-9)
        }
    }

    func testOutputDurationZeroForEmptySession() {
        XCTAssertEqual(TimeAxis.outputDuration(mode: .multiplier(90),
                                               totalStudySeconds: 0,
                                               interval: 3, fps: 30), 0)
    }
}
