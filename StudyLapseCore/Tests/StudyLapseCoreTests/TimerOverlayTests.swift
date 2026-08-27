import XCTest
@testable import StudyLapseCore

final class TimerOverlayTests: XCTestCase {
    func testFirstKeyframeIsZeroAndLastIsTheTotal() {
        let frames = TimerOverlay.timerKeyframes(totalStudySeconds: 600,
                                                 outputDuration: 6,
                                                 granularity: .minutes)
        XCTAssertEqual(frames.first?.time, 0.0)
        XCTAssertEqual(frames.first?.text, "0:00")
        XCTAssertEqual(frames.last?.time, 6.0)
        XCTAssertEqual(frames.last?.text, "10:00")   // MM:SS, below one hour
    }

    func testFormatIsFixedByTotalNotRunningValue() {
        // Total 2 hours → every label is H:MM, including the ones under an hour.
        let frames = TimerOverlay.timerKeyframes(totalStudySeconds: 7200,
                                                 outputDuration: 10,
                                                 granularity: .minutes)
        XCTAssertEqual(frames.first?.text, "0:00")
        XCTAssertTrue(frames.allSatisfy { $0.text.contains(":") })
        XCTAssertEqual(frames.last?.text, "2:00")
        // A label 30 minutes in must read "0:30", not "30:00".
        let halfHour = frames.first { abs($0.time - 10.0 * 1800.0 / 7200.0) < 0.01 }
        XCTAssertEqual(halfHour?.text, "0:30")
    }

    func testKeyframeTimesAreMonotonicAndWithinOutputDuration() {
        let frames = TimerOverlay.timerKeyframes(totalStudySeconds: 5000,
                                                 outputDuration: 12.5,
                                                 granularity: .minutes)
        let times = frames.map(\.time)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(times.allSatisfy { $0 >= 0 && $0 <= 12.5 + 1e-9 })
    }

    func testLongSessionIsCoarsenedUnderTheKeyframeCap() {
        // 9 hours at second granularity would be 32400 keyframes — must coarsen.
        let frames = TimerOverlay.timerKeyframes(totalStudySeconds: 9 * 3600.0,
                                                 outputDuration: 20,
                                                 granularity: .seconds)
        XCTAssertLessThanOrEqual(frames.count, TimerOverlay.maxKeyframes + 1)
        XCTAssertGreaterThan(frames.count, 100)
    }

    func testMinuteGranularityNineHourSessionIsAround540Keyframes() {
        let frames = TimerOverlay.timerKeyframes(totalStudySeconds: 9 * 3600.0,
                                                 outputDuration: 20,
                                                 granularity: .minutes)
        XCTAssertEqual(Double(frames.count), 541, accuracy: 2)
    }

    func testEmptySessionYieldsASingleZeroKeyframe() {
        let frames = TimerOverlay.timerKeyframes(totalStudySeconds: 0,
                                                 outputDuration: 0,
                                                 granularity: .minutes)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.time, 0.0)
        XCTAssertEqual(frames.first?.text, "0:00")
    }
}
