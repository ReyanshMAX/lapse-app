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
            let requestedSpeed = baseOutputSeconds(totalStudySeconds: totalStudySeconds,
                                                   interval: interval, fps: fps) / targetSeconds
            return max(requestedSpeed, floor)
        }
    }

    /// Output-video seconds at 1x composition speed — the length of the
    /// concatenated source clips before any speed scaling is applied.
    public static func baseOutputSeconds(totalStudySeconds: Double,
                                         interval: Double, fps: Int32) -> Double {
        guard totalStudySeconds > 0, interval > 0, fps > 0 else { return 0 }
        return totalStudySeconds / interval / Double(fps)
    }

    /// The actual duration of the exported file for a given speed mode, after
    /// the minimum-speed floor is applied. Single source of truth for both the
    /// number the export UI shows and the duration the composition is scaled to
    /// — they must never be computed independently (BUILD.md Phase 3
    /// criterion 2: "the UI-reported duration equals the actual output
    /// duration").
    public static func outputDuration(mode: SpeedMode, totalStudySeconds: Double,
                                      interval: Double, fps: Int32) -> Double {
        let base = baseOutputSeconds(totalStudySeconds: totalStudySeconds,
                                     interval: interval, fps: fps)
        guard base > 0 else { return 0 }
        let effectiveSpeed = speed(mode: mode, totalStudySeconds: totalStudySeconds,
                                   interval: interval, fps: fps)
        guard effectiveSpeed > 0 else { return 0 }
        return base / effectiveSpeed
    }
}
