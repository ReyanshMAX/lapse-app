import XCTest
@testable import StudyLapseCore

/// BUILD.md Phase 5: streak computation uses `dayKey` (criterion 4) and the
/// per-tag split / untagged band (criterion 5). Pure math — proven in the
/// `core` job; the `[device]`/`[eyes-on]` tags are about the on-screen result.
final class StatsTests: XCTestCase {

    // MARK: currentStreak

    func testStreakCountsConsecutiveDaysEndingToday() {
        let days: Set<String> = ["2026-08-25", "2026-08-26", "2026-08-27"]
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: days, today: "2026-08-27"), 3)
    }

    func testStreakStillCurrentWhenLastStudyDayIsYesterday() {
        let days: Set<String> = ["2026-08-24", "2026-08-25", "2026-08-26"]
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: days, today: "2026-08-27"), 3)
    }

    func testStreakBrokenWhenLastStudyDayIsTwoDaysAgo() {
        let days: Set<String> = ["2026-08-24", "2026-08-25"]
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: days, today: "2026-08-27"), 0)
    }

    func testStreakStopsAtTheFirstGap() {
        let days: Set<String> = ["2026-08-20", "2026-08-25", "2026-08-26", "2026-08-27"]
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: days, today: "2026-08-27"), 3)
    }

    func testStreakCrossesMonthBoundary() {
        let days: Set<String> = ["2026-07-30", "2026-07-31", "2026-08-01"]
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: days, today: "2026-08-01"), 3)
    }

    func testStreakIsZeroWithNoHistory() {
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: [], today: "2026-08-27"), 0)
    }

    /// A session ending at 02:00 has a `dayKey` of the previous day (cutoff 4).
    /// The streak reads that `dayKey`, so it counts toward the previous day —
    /// BUILD.md Phase 5 criterion 4.
    func testStreakUsesDayKeyNotWallClock() {
        let boundary = DayBoundary(cutoffHour: 4)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!

        func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int) -> Date {
            calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
        }
        // Studied late on the 25th and the 26th, each session ending at 02:00
        // the following calendar day.
        let key1 = boundary.dayKey(for: date(2026, 8, 26, 2), calendar: calendar) // -> 25th
        let key2 = boundary.dayKey(for: date(2026, 8, 27, 2), calendar: calendar) // -> 26th
        XCTAssertEqual(key1, "2026-08-25")
        XCTAssertEqual(key2, "2026-08-26")

        let today = boundary.dayKey(for: date(2026, 8, 27, 10), calendar: calendar) // -> 27th
        XCTAssertEqual(Stats.currentStreak(studiedDayKeys: [key1, key2], today: today), 2)
    }

    func testLongestStreak() {
        let days: Set<String> = ["2026-08-01", "2026-08-02", "2026-08-03",
                                 "2026-08-10",
                                 "2026-08-20", "2026-08-21"]
        XCTAssertEqual(Stats.longestStreak(studiedDayKeys: days), 3)
    }

    // MARK: recentDayKeys

    func testRecentDayKeysAreOldestFirstAndInclusive() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let end = calendar.date(from: DateComponents(year: 2026, month: 8, day: 3))!
        XCTAssertEqual(Stats.recentDayKeys(count: 3, endingOn: end),
                       ["2026-08-01", "2026-08-02", "2026-08-03"])
    }

    // MARK: perTagSplit

    func testSingleTagRangesSumToTheirDurations() {
        let ranges = [
            TagRangeMath.Range(start: 0, end: 100, tags: ["math"]),
            TagRangeMath.Range(start: 100, end: 160, tags: ["physics"]),
            TagRangeMath.Range(start: 160, end: 200, tags: ["math"]),
        ]
        let split = Stats.perTagSplit(ranges: ranges)
        XCTAssertEqual(split.shares, [
            .init(tag: "math", seconds: 140),
            .init(tag: "physics", seconds: 60),
        ])
        XCTAssertEqual(split.untagged, 0)
        XCTAssertEqual(split.total, 200)
    }

    func testUntaggedRangesFormTheirOwnBand() {
        let ranges = [
            TagRangeMath.Range(start: 0, end: 100, tags: ["math"]),
            TagRangeMath.Range(start: 100, end: 250, tags: []),
        ]
        let split = Stats.perTagSplit(ranges: ranges)
        XCTAssertEqual(split.untagged, 150)
        XCTAssertEqual(split.taggedTotal, 100)
        XCTAssertEqual(split.total, 250)
    }

    func testMultiTagRangeSplitsEvenlyAndPartitionsTheTotal() {
        let ranges = [
            TagRangeMath.Range(start: 0, end: 120, tags: ["math", "physics"]),
            TagRangeMath.Range(start: 120, end: 180, tags: ["math"]),
        ]
        let split = Stats.perTagSplit(ranges: ranges)
        XCTAssertEqual(split.shares, [
            .init(tag: "math", seconds: 120),
            .init(tag: "physics", seconds: 60),
        ])
        // Bands still sum to the studied total — the property §8's bar needs.
        XCTAssertEqual(split.total, 180, accuracy: 1e-9)
    }

    func testSharesAreSortedBySecondsThenName() {
        let ranges = [
            TagRangeMath.Range(start: 0, end: 60, tags: ["zeta"]),
            TagRangeMath.Range(start: 60, end: 120, tags: ["alpha"]),
            TagRangeMath.Range(start: 120, end: 300, tags: ["beta"]),
        ]
        let split = Stats.perTagSplit(ranges: ranges)
        XCTAssertEqual(split.shares.map(\.tag), ["beta", "alpha", "zeta"])
    }
}
