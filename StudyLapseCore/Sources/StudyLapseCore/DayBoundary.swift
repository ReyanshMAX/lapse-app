import Foundation

/// Maps wall-clock instants to the study day they belong to, using a
/// configurable cutoff hour rather than midnight. See docs/DATA_MODEL.md.
public struct DayBoundary {
    public let cutoffHour: Int

    public init(cutoffHour: Int) {
        self.cutoffHour = cutoffHour
    }

    /// The study day a wall-clock instant belongs to. An instant before the
    /// cutoff hour belongs to the previous calendar day.
    public func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        Self.formatter(for: calendar).string(from: shiftedDate(for: date, calendar: calendar))
    }

    /// The instant at which a session started on `dayKey` must auto-close:
    /// the cutoff hour on the day following `dayKey`.
    public func closeDeadline(forDayKey key: String, calendar: Calendar = .current) -> Date {
        guard let dayStart = Self.formatter(for: calendar).date(from: key) else {
            fatalError("closeDeadline given a malformed dayKey: \(key)")
        }
        let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
        return calendar.date(bySettingHour: cutoffHour, minute: 0, second: 0, of: nextDay) ?? nextDay
    }

    private func shiftedDate(for date: Date, calendar: Calendar) -> Date {
        let hour = calendar.component(.hour, from: date)
        guard hour < cutoffHour else { return date }
        return calendar.date(byAdding: .day, value: -1, to: date) ?? date
    }

    private static func formatter(for calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}
