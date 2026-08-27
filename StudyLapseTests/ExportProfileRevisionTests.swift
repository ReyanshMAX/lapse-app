import SwiftData
import XCTest
@testable import StudyLapse

/// Phase 6: `ExportProfile.reconcileRevision()` write semantics — the mechanism
/// behind BUILD.md Phase 6 criterion 2 ("changing the export profile bumps
/// `revision` and marks existing takes stale").
@MainActor
final class ExportProfileRevisionTests: XCTestCase {
    func testFirstReconcileStampsFingerprintWithoutBumping() {
        let profile = ExportProfile()
        XCTAssertEqual(profile.revision, 0)
        XCTAssertFalse(profile.reconcileRevision(), "a fresh profile's first reconcile does not bump")
        XCTAssertEqual(profile.revision, 0)
        XCTAssertFalse(profile.reconcileRevision(), "and is idempotent")
        XCTAssertEqual(profile.revision, 0)
    }

    func testAnySettingChangeBumpsRevisionExactlyOnce() {
        let profile = ExportProfile()
        profile.reconcileRevision()

        profile.includeIntroCard.toggle()
        XCTAssertTrue(profile.reconcileRevision())
        XCTAssertEqual(profile.revision, 1)
        XCTAssertFalse(profile.reconcileRevision(), "no second bump for the same change")
        XCTAssertEqual(profile.revision, 1)

        profile.speedMultiplier = 240
        profile.reconcileRevision()
        XCTAssertEqual(profile.revision, 2)

        profile.overlayCornerRaw = "bottomLeft"
        profile.reconcileRevision()
        XCTAssertEqual(profile.revision, 3)
    }

    func testTogglingASettingBackIsANoOp() {
        let profile = ExportProfile()
        profile.reconcileRevision()

        profile.includeOutroCard.toggle()
        profile.includeOutroCard.toggle()
        XCTAssertFalse(profile.reconcileRevision())
        XCTAssertEqual(profile.revision, 0)
    }
}
