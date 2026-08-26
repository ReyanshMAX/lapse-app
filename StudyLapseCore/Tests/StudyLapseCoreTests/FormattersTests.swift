import XCTest
@testable import StudyLapseCore

final class FormattersTests: XCTestCase {
    func testHoursMinutes() {
        XCTAssertEqual(Formatters.hoursMinutes(3725), "1:02") // 1h 02m 05s
    }

    func testMinutesSeconds() {
        XCTAssertEqual(Formatters.minutesSeconds(125), "2:05")
    }

    func testStudyTimePicksMinutesSecondsBelowOneHour() {
        XCTAssertEqual(Formatters.studyTime(599), "9:59")
    }

    func testStudyTimePicksHoursMinutesAtOneHourAndAbove() {
        XCTAssertEqual(Formatters.studyTime(3600), "1:00")
    }
}
