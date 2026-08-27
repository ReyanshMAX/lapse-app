import Foundation

/// Display granularity for the burned-in study timer. `minutes` is the default
/// for anything longer than a few minutes; `seconds` is only sensible for very
/// short sessions. See docs/EXPORT.md.
public enum TimerGranularity {
    case seconds
    case minutes
}

/// Pure keyframe generation for the burned-in study-time overlay. The overlay
/// displays **study time**, not output time — because the composition is
/// uniformly scaled, output time `t` maps linearly to study time
/// `t / outputDuration * totalStudySeconds`. `CATextLayer` cannot animate its
/// string, so the render layer is a stack of pre-rendered text layers whose
/// opacity is switched on and off in sequence at the times computed here.
///
/// Format is fixed by the session's *total* study time, not the running value,
/// so the digits never change shape mid-video: `H:MM` at or above one hour,
/// `MM:SS` below it (docs/EXPORT.md).
public enum TimerOverlay {
    /// Hard cap on emitted keyframes. A 9-hour session at minute granularity is
    /// 540 keyframes — cheap. Anything that would exceed this is coarsened.
    public static let maxKeyframes = 2000

    public static func timerKeyframes(totalStudySeconds: Double,
                                      outputDuration: Double,
                                      granularity: TimerGranularity)
        -> [(time: Double, text: String)] {

        let useHoursMinutes = totalStudySeconds >= 3600
        func text(_ seconds: Double) -> String {
            useHoursMinutes ? Formatters.hoursMinutes(seconds)
                            : Formatters.minutesSeconds(seconds)
        }

        guard totalStudySeconds > 0, outputDuration > 0 else {
            return [(0, text(0))]
        }

        var step = granularity == .seconds ? 1.0 : 60.0
        if totalStudySeconds / step > Double(maxKeyframes) {
            step = (totalStudySeconds / Double(maxKeyframes)).rounded(.up)
        }

        var keyframes: [(time: Double, text: String)] = []
        var value = 0.0
        while value < totalStudySeconds {
            let time = outputDuration * value / totalStudySeconds
            keyframes.append((time, text(value)))
            value += step
        }
        // Always close on the exact total at the end of the video.
        keyframes.append((outputDuration, text(totalStudySeconds)))
        return keyframes
    }
}
