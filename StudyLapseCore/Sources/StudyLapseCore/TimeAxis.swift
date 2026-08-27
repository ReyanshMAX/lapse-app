import Foundation

/// How an export's playback speed is chosen. See docs/EXPORT.md.
public enum SpeedMode: Sendable, Equatable {
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

    /// The fastest a **net, real-time** speed can't drop below: showing every
    /// captured frame exactly once at `fps` already compresses `interval * fps`
    /// seconds of real study into one output second (3s/30fps → 90x). Export can
    /// drop frames but never invent them, so it can't go slower. All `speed`
    /// values below are on this same net-real-time axis. See docs/DATA_MODEL.md.
    public static func minimumSpeed(interval: Double, fps: Int32) -> Double {
        interval * Double(fps)
    }

    /// The exported video's **net speed relative to real study time** — a
    /// `speed` of 100 means the video plays 100× faster than the user actually
    /// studied. Clamped to `minimumSpeed`.
    ///
    /// `.multiplier(n)` is that net speed directly. `.fitToDuration(t)` asks for
    /// whatever net speed lands `totalStudySeconds` of study in `t` seconds of
    /// video (`totalStudySeconds / t`); if that is slower than the floor it
    /// clamps and the real output ends up longer than `t` (surfaced in the UI).
    public static func speed(mode: SpeedMode, totalStudySeconds: Double,
                              interval: Double, fps: Int32) -> Double {
        let floor = minimumSpeed(interval: interval, fps: fps)
        switch mode {
        case .multiplier(let value):
            return max(value, floor)
        case .fitToDuration(let targetSeconds):
            guard targetSeconds > 0, totalStudySeconds > 0 else { return floor }
            return max(totalStudySeconds / targetSeconds, floor)
        }
    }

    /// Output-video seconds if every captured frame is shown exactly once at
    /// `fps` — i.e. the composition's native length, before any speed scaling.
    /// Equals `totalStudySeconds / minimumSpeed`.
    public static func nativeOutputSeconds(totalStudySeconds: Double,
                                           interval: Double, fps: Int32) -> Double {
        guard totalStudySeconds > 0, interval > 0, fps > 0 else { return 0 }
        return totalStudySeconds / minimumSpeed(interval: interval, fps: fps)
    }

    /// The actual duration of the exported file: `totalStudySeconds / speed`,
    /// with `speed` already clamped to the floor. Single source of truth for
    /// both the number the export UI shows and the duration the composition is
    /// scaled to — never compute them independently (BUILD.md Phase 3
    /// criterion 2: "the UI-reported duration equals the actual output
    /// duration").
    public static func outputDuration(mode: SpeedMode, totalStudySeconds: Double,
                                      interval: Double, fps: Int32) -> Double {
        guard totalStudySeconds > 0 else { return 0 }
        let effectiveSpeed = speed(mode: mode, totalStudySeconds: totalStudySeconds,
                                   interval: interval, fps: fps)
        guard effectiveSpeed > 0 else { return 0 }
        return totalStudySeconds / effectiveSpeed
    }
}
