import Foundation

/// Pure aggregation for the stats screen (docs/UI.md §8): totals, current
/// streak by `dayKey`, and the per-tag time split with an explicit untagged
/// band. Foundation-only — the app layer maps `@Model` rows to the plain
/// value inputs here (same seam as `TagRangeMath`).
///
/// **Multi-tag attribution (Q-007).** docs/UI.md §8 specifies the split as
/// bands of a single horizontal bar with untagged as its own band; that only
/// reads correctly if the bands partition the total. So a range carrying N
/// tags contributes `duration / N` to each of its tags rather than the full
/// duration to every tag. Ranges with no tags feed the untagged band.
///
/// **Streak currency (Q-007).** A streak counts as "current" only if its most
/// recent studied day is today's or yesterday's `dayKey`; a gap of a full day
/// or more resets it to zero.
public enum Stats {
    /// A gregorian/UTC calendar so `dayKey` string arithmetic is deterministic
    /// and DST-free. `dayKey`s are wall-clock-day labels already resolved by
    /// `DayBoundary`; stepping between them is plain calendar-day subtraction.
    public static var dayKeyCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private static func dayKeyFormatter(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    /// The plain calendar-day `dayKey` for a date (no cutoff-hour shift — that
    /// is `DayBoundary`'s job; this is for laying out the heatmap grid).
    public static func dayKeyString(for date: Date,
                                    calendar: Calendar = Stats.dayKeyCalendar) -> String {
        dayKeyFormatter(calendar).string(from: date)
    }

    /// The `count` most recent calendar-day `dayKey`s ending on `endingOn`
    /// (inclusive), oldest first — the columns/rows of the calendar heatmap.
    public static func recentDayKeys(count: Int, endingOn: Date,
                                     calendar: Calendar = Stats.dayKeyCalendar) -> [String] {
        guard count > 0 else { return [] }
        let formatter = dayKeyFormatter(calendar)
        var keys: [String] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            if let date = calendar.date(byAdding: .day, value: -offset, to: endingOn) {
                keys.append(formatter.string(from: date))
            }
        }
        return keys
    }

    // MARK: Streak

    /// Consecutive study days ending at the most recent studied day, provided
    /// that day is `today` or the day before it. Returns 0 if the streak is
    /// broken (the last study day is two or more days before `today`) or if
    /// nothing was studied.
    ///
    /// - Parameters:
    ///   - studiedDayKeys: every `dayKey` on which at least one session exists.
    ///   - today: the current `dayKey` (caller resolves it via `DayBoundary`).
    public static func currentStreak(studiedDayKeys: Set<String>, today: String,
                                     calendar: Calendar = Stats.dayKeyCalendar) -> Int {
        let formatter = dayKeyFormatter(calendar)
        guard let todayDate = formatter.date(from: today) else { return 0 }

        var cursor = todayDate
        if !studiedDayKeys.contains(formatter.string(from: cursor)) {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: cursor) else { return 0 }
            cursor = yesterday
            if !studiedDayKeys.contains(formatter.string(from: cursor)) { return 0 }
        }

        var count = 0
        while studiedDayKeys.contains(formatter.string(from: cursor)) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = previous
        }
        return count
    }

    /// The longest run of consecutive study days anywhere in the history.
    public static func longestStreak(studiedDayKeys: Set<String>,
                                     calendar: Calendar = Stats.dayKeyCalendar) -> Int {
        let formatter = dayKeyFormatter(calendar)
        let dates = studiedDayKeys.compactMap { formatter.date(from: $0) }.sorted()
        guard !dates.isEmpty else { return 0 }

        var best = 1
        var run = 1
        for i in 1..<dates.count {
            let expectedPrevious = calendar.date(byAdding: .day, value: -1, to: dates[i])
            if let expectedPrevious, calendar.isDate(expectedPrevious, inSameDayAs: dates[i - 1]) {
                run += 1
            } else {
                run = 1
            }
            best = max(best, run)
        }
        return best
    }

    // MARK: Per-tag split

    public struct TagShare: Equatable {
        public let tag: String
        public let seconds: Double
        public init(tag: String, seconds: Double) {
            self.tag = tag
            self.seconds = seconds
        }
    }

    public struct Split: Equatable {
        /// Per-tag totals, largest first (ties broken alphabetically).
        public let shares: [TagShare]
        /// Study seconds sitting in ranges that carry no tag.
        public let untagged: Double

        public var taggedTotal: Double { shares.reduce(0) { $0 + $1.seconds } }
        public var total: Double { taggedTotal + untagged }
    }

    /// Split a flat list of tag ranges (from any number of sessions) into
    /// per-tag totals plus an untagged band. A range with several tags divides
    /// its duration evenly among them (see the type doc comment).
    public static func perTagSplit(ranges: [TagRangeMath.Range]) -> Split {
        var totals: [String: Double] = [:]
        var untagged = 0.0

        for range in ranges {
            let duration = max(0, range.end - range.start)
            guard duration > 0 else { continue }
            if range.tags.isEmpty {
                untagged += duration
                continue
            }
            let share = duration / Double(range.tags.count)
            for tag in range.tags { totals[tag, default: 0] += share }
        }

        let shares = totals
            .map { TagShare(tag: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.tag < $1.tag }
        return Split(shares: shares, untagged: untagged)
    }
}
