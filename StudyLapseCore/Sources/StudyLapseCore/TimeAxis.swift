import Foundation

/// How an export's playback speed is chosen. See docs/EXPORT.md.
public enum SpeedMode {
    case multiplier(Double)
    case fitToDuration(targetSeconds: Double)
}

/// Conversions between the study-time axis (seconds of actual study, pauses
/// excluded) and the output-video axis. See docs/DATA_MODEL.md.
public enum TimeAxis {
    /// Study seconds at a given frame within a clip.
    public static func studySeconds(clipOffset: Double, frameIndex: Int, interval: Double) -> Double {
        clipOffset + Double(frameIndex) * interval
    }

    /// Total study seconds for a session, given each finalized clip's duration.
    public static func totalStudySeconds(clipDurations: [Double]) -> Double {
        clipDurations.reduce(0, +)
    }

    /// The slowest speed the composition can play back at without duplicating
    /// frames: one captured frame per output frame. See docs/DATA_MODEL.md.
    public static func minimumSpeed(interval: Double, fps: Int32) -> Double {
        interval * Double(fps)
    }

    /// Effective speed multiplier for an export, clamped to the minimum-speed
    /// floor — export can drop frames but never create them.
    public static func speed(mode: SpeedMode, totalStudySeconds: Double,
                              interval: Double, fps: Int32) -> Double {
        let floor = minimumSpeed(interval: interval, fps: fps)
        switch mode {
        case .multiplier(let value):
            return max(value, floor)
        case .fitToDuration(let targetSeconds):
            let baseOutputSeconds = totalStudySeconds / interval / Double(fps)
            let requestedSpeed = baseOutputSeconds / targetSeconds
            return max(requestedSpeed, floor)
        }
    }
}
