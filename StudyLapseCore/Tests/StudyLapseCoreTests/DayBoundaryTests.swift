import XCTest
@testable import StudyLapseCore

final class DayBoundaryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    func testDayKeyBeforeCutoffBelongsToPreviousDay() {
        let boundary = DayBoundary(cutoffHour: 4)
        let key = boundary.dayKey(for: date(2026, 8, 24, 2, 30), calendar: calendar)
        XCTAssertEqual(key, "2026-08-23")
    }

    func testDayKeyAfterCutoffBelongsToSameDay() {
        let boundary = DayBoundary(cutoffHour: 4)
        let key = boundary.dayKey(for: date(2026, 8, 24, 4, 0), calendar: calendar)
        XCTAssertEqual(key, "2026-08-24")
    }

    func testCloseDeadlineLandsAtCutoffTheFollowingDay() {
        let boundary = DayBoundary(cutoffHour: 4)
        let deadline = boundary.closeDeadline(forDayKey: "2026-08-23", calendar: calendar)
        XCTAssertEqual(deadline, date(2026, 8, 24, 4, 0))
    }
}
