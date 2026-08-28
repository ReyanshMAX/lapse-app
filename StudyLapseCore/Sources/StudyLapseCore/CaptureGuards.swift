import Foundation

/// Mirrors `ProcessInfo.ThermalState` without importing Foundation's Apple-only
/// bits — this package only ever depends on portable Foundation (see
/// docs/ARCHITECTURE.md). The device-side guard monitor maps the real
/// `ProcessInfo.ThermalState` onto this.
public enum CaptureThermalState: Sendable, Equatable {
    case nominal
    case fair
    case serious
    case critical
}

/// A snapshot of the signals the guards in docs/CAPTURE.md react to.
/// `batteryLevel` is `nil` when the device can't report one (e.g. no battery
/// monitoring, or the simulator) — `evaluate` treats that as "don't gate on
/// battery" rather than treating it as empty/zero.
public struct GuardReading: Sendable, Equatable {
    public let batteryLevel: Float?       // 0...1
    public let isCharging: Bool
    public let thermalState: CaptureThermalState
    public let freeDiskBytes: Int64

    public init(batteryLevel: Float?, isCharging: Bool,
                thermalState: CaptureThermalState, freeDiskBytes: Int64) {
        self.batteryLevel = batteryLevel
        self.isCharging = isCharging
        self.thermalState = thermalState
        self.freeDiskBytes = freeDiskBytes
    }
}

/// When a reading is taken — thresholds differ at session start vs. mid-recording
/// (docs/CAPTURE.md's guard table).
public enum GuardEvaluationPhase: Sendable {
    case sessionStart
    case duringRecording
}

/// A non-blocking condition to surface in the UI. Never gates recording by
/// itself — only `GuardAction.autoPause`/`.autoPauseAndEnd` do that.
public enum GuardWarningKind: Sendable, Hashable {
    case batteryLowAtStart
    case diskLowAtStart
    case batteryLowDuringRecording
    case thermalSerious
}

/// What `CaptureGuards.evaluate` says should happen. A single reading can
/// produce more than one action (e.g. thermal critical *and* disk exhausted at
/// once) — `evaluate` returns them all, in no particular priority order, and
/// the caller applies every one.
public enum GuardAction: Sendable, Hashable {
    case warn(GuardWarningKind)
    /// Thermal `.critical` (docs/CAPTURE.md: "Auto-pause", not "and end" — the
    /// user can resume once the device cools).
    case autoPause
    /// Battery ≤5% or free disk <300MB during recording: pause *and* end the
    /// session cleanly, since neither condition is expected to resolve itself
    /// mid-session.
    case autoPauseAndEnd
}

/// Pure threshold logic for the guards in docs/CAPTURE.md's guard table. No
/// Apple-framework dependency — the device-side `GuardMonitor` (in the app
/// target) is the only thing that touches `UIDevice`/`ProcessInfo` directly and
/// hands readings in here.
public enum CaptureGuards {
    /// Battery at session start: warn (and offer to continue, D-018) below this
    /// while unplugged.
    public static let batteryStartThreshold: Float = 0.30
    /// Battery during recording: non-blocking banner at or below this.
    public static let batteryBannerThreshold: Float = 0.10
    /// Battery during recording: auto-pause-and-end at or below this.
    public static let batteryAutoEndThreshold: Float = 0.05
    /// Free disk at session start: warn below this.
    public static let diskStartThresholdBytes: Int64 = 1_000_000_000
    /// Free disk during recording: auto-pause-and-end below this.
    public static let diskAutoEndThresholdBytes: Int64 = 300_000_000

    public static func evaluate(_ reading: GuardReading,
                                phase: GuardEvaluationPhase) -> [GuardAction] {
        switch phase {
        case .sessionStart:
            var actions: [GuardAction] = []
            if let level = reading.batteryLevel,
               level < batteryStartThreshold, !reading.isCharging {
                actions.append(.warn(.batteryLowAtStart))
            }
            if reading.freeDiskBytes < diskStartThresholdBytes {
                actions.append(.warn(.diskLowAtStart))
            }
            return actions

        case .duringRecording:
            var actions: [GuardAction] = []

            if let level = reading.batteryLevel {
                if level <= batteryAutoEndThreshold {
                    actions.append(.autoPauseAndEnd)
                } else if level <= batteryBannerThreshold {
                    actions.append(.warn(.batteryLowDuringRecording))
                }
            }

            if reading.freeDiskBytes < diskAutoEndThresholdBytes {
                actions.append(.autoPauseAndEnd)
            }

            switch reading.thermalState {
            case .critical:
                actions.append(.autoPause)
            case .serious:
                actions.append(.warn(.thermalSerious))
            case .fair, .nominal:
                break
            }

            return actions
        }
    }
}
