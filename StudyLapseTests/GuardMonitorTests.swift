import StudyLapseCore
import SwiftData
import XCTest
@testable import StudyLapse

/// BUILD.md Phase 7 criterion 1: "each guard fires at its documented
/// threshold in a test that injects synthetic battery/thermal/disk values."
/// `FakeGuardSignalSource` stands in for `UIDevice`/`ProcessInfo` the same way
/// `SyntheticFrameSource` stands in for the camera (D-026's pattern applied to
/// guards).
private final class FakeGuardSignalSource: GuardSignalSource {
    var onChange: (() -> Void)?
    private var reading: GuardReading

    init(reading: GuardReading) {
        self.reading = reading
    }

    func currentReading() -> GuardReading { reading }
    func startObserving() {}
    func stopObserving() {}

    /// Simulates a system notification firing with a new reading.
    func push(_ reading: GuardReading) {
        self.reading = reading
        onChange?()
    }
}

private func fullReading(battery: Float? = 1.0, charging: Bool = false,
                         thermal: CaptureThermalState = .nominal,
                         diskBytes: Int64 = 10_000_000_000) -> GuardReading {
    GuardReading(batteryLevel: battery, isCharging: charging,
                thermalState: thermal, freeDiskBytes: diskBytes)
}

@MainActor
final class GuardMonitorTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        UserDefaults.standard.set(3.0, forKey: "captureIntervalSeconds")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "captureIntervalSeconds")
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 15,
                           _ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func cleanupClipFiles() {
        let clips = (try? context.fetch(FetchDescriptor<Clip>())) ?? []
        for clip in clips {
            try? FileManager.default.removeItem(at: StorageLocator.url(forRelativePath: clip.relativePath))
        }
    }

    func testEvaluateStartWarningsSurfacesLowBatteryAndDisk() {
        let signalSource = FakeGuardSignalSource(
            reading: fullReading(battery: 0.2, charging: false, diskBytes: 500_000_000))
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { SyntheticFrameSource() },
            makeGuardSignalSource: { signalSource })

        let warnings = coordinator.evaluateStartWarnings()
        XCTAssertEqual(Set(warnings), Set([.batteryLowAtStart, .diskLowAtStart]))
    }

    func testEvaluateStartWarningsIsEmptyWhenHealthy() {
        let signalSource = FakeGuardSignalSource(reading: fullReading())
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { SyntheticFrameSource() },
            makeGuardSignalSource: { signalSource })

        XCTAssertTrue(coordinator.evaluateStartWarnings().isEmpty)
    }

    func testBatteryAtFivePercentDuringRecordingAutoPausesAndEnds() async throws {
        let source = SyntheticFrameSource()
        let signalSource = FakeGuardSignalSource(reading: fullReading())
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { source },
            makeGuardSignalSource: { signalSource })

        try coordinator.startNewSession()
        source.emit(seconds: 30)
        XCTAssertEqual(coordinator.status, .recording)

        signalSource.push(fullReading(battery: 0.05))

        await waitUntil({ coordinator.status == .ended },
                        "battery <= 5% must auto-pause and end the session")
        cleanupClipFiles()
    }

    func testCriticalThermalDuringRecordingAutoPausesWithoutEnding() async throws {
        let source = SyntheticFrameSource()
        let signalSource = FakeGuardSignalSource(reading: fullReading())
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { source },
            makeGuardSignalSource: { signalSource })

        try coordinator.startNewSession()
        source.emit(seconds: 30)

        signalSource.push(fullReading(thermal: .critical))

        await waitUntil({ coordinator.status == .paused },
                        "thermal .critical must auto-pause the session")
        XCTAssertNotNil(coordinator.session, "auto-pause must not end the session")
        await coordinator.end()
        cleanupClipFiles()
    }

    func testDiskBelowThresholdDuringRecordingAutoPausesAndEnds() async throws {
        let source = SyntheticFrameSource()
        let signalSource = FakeGuardSignalSource(reading: fullReading())
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { source },
            makeGuardSignalSource: { signalSource })

        try coordinator.startNewSession()
        source.emit(seconds: 30)

        signalSource.push(fullReading(diskBytes: 100_000_000))

        await waitUntil({ coordinator.status == .ended },
                        "free disk < 300MB must auto-pause and end the session")
        cleanupClipFiles()
    }

    func testBatteryBannerAppearsAndClearsAsTheReadingChanges() async throws {
        let source = SyntheticFrameSource()
        let signalSource = FakeGuardSignalSource(reading: fullReading())
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { source },
            makeGuardSignalSource: { signalSource })

        try coordinator.startNewSession()
        source.emit(seconds: 30)

        signalSource.push(fullReading(battery: 0.08))
        await waitUntil({ coordinator.warnings.contains(.batteryLow) },
                        "10% or below must raise a non-blocking battery banner")

        signalSource.push(fullReading(battery: 0.5))
        await waitUntil({ !coordinator.warnings.contains(.batteryLow) },
                        "the banner must clear once battery recovers")

        await coordinator.end()
        cleanupClipFiles()
    }

    func testWarningsClearOnPause() async throws {
        let source = SyntheticFrameSource()
        let signalSource = FakeGuardSignalSource(reading: fullReading())
        let coordinator = SessionCoordinator(
            context: context,
            makeFrameSource: { source },
            makeGuardSignalSource: { signalSource })

        try coordinator.startNewSession()
        source.emit(seconds: 30)
        signalSource.push(fullReading(thermal: .serious))
        await waitUntil({ coordinator.warnings.contains(.thermalSerious) })

        await coordinator.pause()
        XCTAssertTrue(coordinator.warnings.isEmpty)
        cleanupClipFiles()
    }
}
