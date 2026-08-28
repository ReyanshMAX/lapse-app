import Foundation
import StudyLapseCore
#if canImport(UIKit)
import UIKit
#endif

/// Everything `GuardMonitor` needs from the system. A seam (D-026's pattern
/// applied to guards): `DeviceGuardSignalSource` is the only thing that
/// touches `UIDevice`/`ProcessInfo` directly, so tests can inject synthetic
/// battery/thermal/disk values (BUILD.md Phase 7 criterion 1) the same way
/// `SyntheticFrameSource` stands in for the camera.
protocol GuardSignalSource: AnyObject {
    /// Fired whenever a relevant system value changes, so the monitor doesn't
    /// have to poll for everything.
    var onChange: (() -> Void)? { get set }
    func currentReading() -> GuardReading
    func startObserving()
    func stopObserving()
}

/// Evaluates live guard signals through `CaptureGuards` and reports the
/// resulting actions. Polls on a slow interval as a backstop for disk space,
/// which has no change notification, in addition to reacting immediately to
/// battery/thermal notifications.
///
/// `@unchecked Sendable`: every call in from `SessionCoordinator` (`start`,
/// `stop`, `evaluateSessionStart`) runs on the main actor, and the only thing
/// the background poll loop touches is a call-through to `onActions`, which
/// itself immediately hops back to the main actor before touching any shared
/// state — the same resolution `CaptureController` uses for its capture
/// queue (see STATUS.md Deviations).
final class GuardMonitor: @unchecked Sendable {
    private let source: GuardSignalSource
    private let pollInterval: TimeInterval
    private var pollTask: Task<Void, Never>?
    private var onActions: (([GuardAction]) -> Void)?

    init(source: GuardSignalSource, pollInterval: TimeInterval = 30) {
        self.source = source
        self.pollInterval = pollInterval
    }

    /// A one-off check with no ongoing observation — used before a session
    /// starts (docs/CAPTURE.md: "Warn, offer to continue").
    func evaluateSessionStart() -> [GuardAction] {
        CaptureGuards.evaluate(source.currentReading(), phase: .sessionStart)
    }

    /// Begins continuous monitoring for the duration of a recording. Calls
    /// `onActions` once immediately and again on every subsequent change or
    /// poll tick.
    func start(onActions: @escaping ([GuardAction]) -> Void) {
        self.onActions = onActions
        source.onChange = { [weak self] in self?.evaluate() }
        source.startObserving()
        evaluate()

        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self.evaluate()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        source.onChange = nil
        source.stopObserving()
        onActions = nil
    }

    private func evaluate() {
        let actions = CaptureGuards.evaluate(source.currentReading(), phase: .duringRecording)
        onActions?(actions)
    }
}

#if canImport(UIKit)
/// Device implementation of `GuardSignalSource` — the only type in the guard
/// system that touches `UIDevice`/`ProcessInfo` directly.
final class DeviceGuardSignalSource: GuardSignalSource {
    var onChange: (() -> Void)?
    private var observers: [NSObjectProtocol] = []

    func currentReading() -> GuardReading {
        let device = UIDevice.current
        let rawLevel = device.batteryLevel
        // `batteryLevel` is -1 when monitoring is off or unavailable
        // (simulator, some devices) — treat that as "unknown", not "empty".
        let battery: Float? = rawLevel < 0 ? nil : rawLevel
        let charging = device.batteryState == .charging || device.batteryState == .full

        let thermal: CaptureThermalState
        switch ProcessInfo.processInfo.thermalState {
        case .nominal:  thermal = .nominal
        case .fair:     thermal = .fair
        case .serious:  thermal = .serious
        case .critical: thermal = .critical
        @unknown default: thermal = .nominal
        }

        return GuardReading(batteryLevel: battery, isCharging: charging,
                            thermalState: thermal, freeDiskBytes: Self.freeDiskBytes())
    }

    func startObserving() {
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIDevice.batteryLevelDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.onChange?() },
            center.addObserver(forName: UIDevice.batteryStateDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.onChange?() },
            center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                               object: nil, queue: .main) { [weak self] _ in self?.onChange?() }
        ]
    }

    func stopObserving() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        observers = []
    }

    private static func freeDiskBytes() -> Int64 {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64.max
    }
}
#endif
