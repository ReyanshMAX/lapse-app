import XCTest
@testable import StudyLapseCore

final class CaptureGuardsTests: XCTestCase {
    private func reading(battery: Float? = 1.0, charging: Bool = false,
                         thermal: CaptureThermalState = .nominal,
                         diskBytes: Int64 = 10_000_000_000) -> GuardReading {
        GuardReading(batteryLevel: battery, isCharging: charging,
                     thermalState: thermal, freeDiskBytes: diskBytes)
    }

    // MARK: Session start

    func testSessionStartWarnsOnLowUnpluggedBattery() {
        let actions = CaptureGuards.evaluate(reading(battery: 0.29, charging: false),
                                             phase: .sessionStart)
        XCTAssertEqual(actions, [.warn(.batteryLowAtStart)])
    }

    func testSessionStartDoesNotWarnWhenCharging() {
        let actions = CaptureGuards.evaluate(reading(battery: 0.1, charging: true),
                                             phase: .sessionStart)
        XCTAssertTrue(actions.isEmpty)
    }

    func testSessionStartThresholdIsExclusive() {
        // Exactly 30% is not "< 30%" (docs/CAPTURE.md).
        let actions = CaptureGuards.evaluate(reading(battery: 0.30, charging: false),
                                             phase: .sessionStart)
        XCTAssertTrue(actions.isEmpty)
    }

    func testSessionStartWarnsOnLowDisk() {
        let actions = CaptureGuards.evaluate(reading(diskBytes: 999_999_999),
                                             phase: .sessionStart)
        XCTAssertEqual(actions, [.warn(.diskLowAtStart)])
    }

    func testSessionStartCanWarnOnBothAtOnce() {
        let actions = CaptureGuards.evaluate(
            reading(battery: 0.1, charging: false, diskBytes: 500_000_000),
            phase: .sessionStart)
        XCTAssertEqual(Set(actions), Set([.warn(.batteryLowAtStart), .warn(.diskLowAtStart)]))
    }

    func testSessionStartIgnoresBatteryWhenLevelUnknown() {
        let actions = CaptureGuards.evaluate(reading(battery: nil, charging: false),
                                             phase: .sessionStart)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: During recording — battery

    func testDuringRecordingBannersAtTenPercent() {
        let actions = CaptureGuards.evaluate(reading(battery: 0.10), phase: .duringRecording)
        XCTAssertEqual(actions, [.warn(.batteryLowDuringRecording)])
    }

    func testDuringRecordingAboveTenPercentIsQuiet() {
        let actions = CaptureGuards.evaluate(reading(battery: 0.11), phase: .duringRecording)
        XCTAssertTrue(actions.isEmpty)
    }

    func testDuringRecordingAutoPauseAndEndsAtFivePercent() {
        let actions = CaptureGuards.evaluate(reading(battery: 0.05), phase: .duringRecording)
        XCTAssertEqual(actions, [.autoPauseAndEnd])
    }

    func testDuringRecordingAutoPauseAndEndBelowFivePercent() {
        let actions = CaptureGuards.evaluate(reading(battery: 0.01), phase: .duringRecording)
        XCTAssertEqual(actions, [.autoPauseAndEnd])
    }

    func testDuringRecordingBatteryUnknownNeverGates() {
        let actions = CaptureGuards.evaluate(reading(battery: nil), phase: .duringRecording)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: During recording — thermal

    func testDuringRecordingBannersOnSeriousThermal() {
        let actions = CaptureGuards.evaluate(reading(thermal: .serious), phase: .duringRecording)
        XCTAssertEqual(actions, [.warn(.thermalSerious)])
    }

    func testDuringRecordingAutoPausesOnCriticalThermal() {
        let actions = CaptureGuards.evaluate(reading(thermal: .critical), phase: .duringRecording)
        XCTAssertEqual(actions, [.autoPause])
    }

    func testDuringRecordingFairThermalIsQuiet() {
        let actions = CaptureGuards.evaluate(reading(thermal: .fair), phase: .duringRecording)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: During recording — disk

    func testDuringRecordingAutoPauseAndEndsBelowThreeHundredMB() {
        let actions = CaptureGuards.evaluate(reading(diskBytes: 299_999_999), phase: .duringRecording)
        XCTAssertEqual(actions, [.autoPauseAndEnd])
    }

    func testDuringRecordingThresholdIsExclusive() {
        let actions = CaptureGuards.evaluate(reading(diskBytes: 300_000_000), phase: .duringRecording)
        XCTAssertTrue(actions.isEmpty)
    }

    // MARK: Multiple simultaneous conditions

    func testDuringRecordingCanFireMultipleActionsAtOnce() {
        let actions = CaptureGuards.evaluate(
            reading(battery: 0.03, thermal: .critical, diskBytes: 100_000_000),
            phase: .duringRecording)
        XCTAssertEqual(Set(actions), Set([.autoPauseAndEnd, .autoPause]))
    }
}
