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

    // MARK: speed is net, real-time — a `multiplier` of N means "N× faster than
    // you actually studied", NOT N× on top of the capture-interval compression.

    func testMultiplierIsTheNetSpeedNotStackedOnTheInterval() {
        // 1 h studied, 2 s interval (→ 60× floor), multiplier 100.
        // Net speed must be 100×, so a 3600 s session → 36 s of video.
        // (The bug this guards against gave 60 × 100 = 6000× → 0.6 s.)
        let d = TimeAxis.outputDuration(mode: .multiplier(100),
                                        totalStudySeconds: 3600,
                                        interval: 2, fps: 30)
        XCTAssertEqual(d, 36, accuracy: 1e-6)
        XCTAssertEqual(TimeAxis.speed(mode: .multiplier(100), totalStudySeconds: 3600,
                                      interval: 2, fps: 30), 100)
    }

    func testMultiplierAboveFloorIsUnchanged() {
        XCTAssertEqual(TimeAxis.speed(mode: .multiplier(150), totalStudySeconds: 1000,
                                      interval: 3, fps: 30), 150)
    }

    func testMultiplierBelowFloorClampsUp() {
        XCTAssertEqual(TimeAxis.speed(mode: .multiplier(10), totalStudySeconds: 1000,
                                      interval: 3, fps: 30), 90)
    }

    func testFitToDurationIsTheNetSpeedThatLandsTheTarget() {
        // 9 h studied, fit to 30 s → net speed 32400 / 30 = 1080×, far above the
        // 90× floor, so the output is exactly 30 s.
        let d = TimeAxis.outputDuration(mode: .fitToDuration(targetSeconds: 30),
                                        totalStudySeconds: 9 * 3600.0,
                                        interval: 3, fps: 30)
        XCTAssertEqual(d, 30, accuracy: 1e-6)
    }

    func testFitToDurationClampsWhenTheTargetIsLongerThanPhysicallyPossible() {
        // 20 min studied, 3 s interval (90× floor). Fit to 60 s implies a net
        // speed of 1200 / 60 = 20×, below the floor → clamp to 90×, and the real
        // output is 1200 / 90 ≈ 13.33 s, not 60.
        let speed = TimeAxis.speed(mode: .fitToDuration(targetSeconds: 60),
                                   totalStudySeconds: 1200,
                                   interval: 3, fps: 30)
        XCTAssertEqual(speed, 90)
        let d = TimeAxis.outputDuration(mode: .fitToDuration(targetSeconds: 60),
                                        totalStudySeconds: 1200,
                                        interval: 3, fps: 30)
        XCTAssertEqual(d, 1200.0 / 90.0, accuracy: 1e-6)
    }

    func testOutputDurationForAMultiplier() {
        // 480 s studied, multiplier 100 (above the 90× floor) → 480 / 100 = 4.8 s.
        let d = TimeAxis.outputDuration(mode: .multiplier(100),
                                        totalStudySeconds: 480,
                                        interval: 3, fps: 30)
        XCTAssertEqual(d, 4.8, accuracy: 1e-9)
    }

    func testOutputDurationIsAlwaysTotalOverSpeed() {
        let total = 1234.0
        for mode in [SpeedMode.multiplier(120), .multiplier(5),
                     .fitToDuration(targetSeconds: 8), .fitToDuration(targetSeconds: 400)] {
            let speed = TimeAxis.speed(mode: mode, totalStudySeconds: total, interval: 3, fps: 30)
            let d = TimeAxis.outputDuration(mode: mode, totalStudySeconds: total, interval: 3, fps: 30)
            XCTAssertEqual(d, total / speed, accuracy: 1e-9)
        }
    }

    func testNativeOutputSecondsIsTotalOverFloor() {
        XCTAssertEqual(TimeAxis.nativeOutputSeconds(totalStudySeconds: 1800, interval: 3, fps: 30),
                       1800.0 / 90.0, accuracy: 1e-9)
    }

    func testOutputDurationZeroForEmptySession() {
        XCTAssertEqual(TimeAxis.outputDuration(mode: .multiplier(90),
                                               totalStudySeconds: 0,
                                               interval: 3, fps: 30), 0)
    }
}
