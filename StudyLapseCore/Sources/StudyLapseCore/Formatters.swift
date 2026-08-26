import Foundation

/// Text formatting for durations shown in the UI and burned into exports.
/// See docs/EXPORT.md: `H:MM` once total study time reaches an hour, `MM:SS`
/// below that.
public enum Formatters {
    public static func hoursMinutes(_ seconds: Double) -> String {
        let totalMinutes = Int(seconds) / 60
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        return "\(hours):\(String(format: "%02d", minutes))"
    }

    public static func minutesSeconds(_ seconds: Double) -> String {
        let totalSeconds = Int(seconds)
        let minutes = totalSeconds / 60
        let secs = totalSeconds % 60
        return "\(minutes):\(String(format: "%02d", secs))"
    }

    /// Picks `hoursMinutes` at or above one hour, `minutesSeconds` below it.
    public static func studyTime(_ seconds: Double) -> String {
        seconds >= 3600 ? hoursMinutes(seconds) : minutesSeconds(seconds)
    }
}
