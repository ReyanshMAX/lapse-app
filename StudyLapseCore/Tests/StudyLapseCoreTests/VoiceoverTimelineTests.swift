import XCTest
@testable import StudyLapseCore

final class VoiceoverTimelineTests: XCTestCase {
    private func take(_ start: Double, _ duration: Double,
                      at seconds: TimeInterval = 0) -> VoiceoverTimeline.Take {
        VoiceoverTimeline.Take(id: UUID(), start: start, duration: duration,
                               createdAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: Playhead / record-button gating (criterion 3)

    func testPlayheadInsideTakeIsDetected() {
        let takes = [take(12, 3)]   // occupies [12, 15)
        XCTAssertTrue(VoiceoverTimeline.isPlayheadInsideAnyTake(12, takes: takes))
        XCTAssertTrue(VoiceoverTimeline.isPlayheadInsideAnyTake(13.5, takes: takes))
        XCTAssertFalse(VoiceoverTimeline.isPlayheadInsideAnyTake(15, takes: takes),
                       "the end edge is exclusive — a new take can start there")
        XCTAssertFalse(VoiceoverTimeline.isPlayheadInsideAnyTake(11.9, takes: takes))
        XCTAssertFalse(VoiceoverTimeline.isPlayheadInsideAnyTake(0, takes: []))
    }

    // MARK: Overlap prevention at creation

    func testWouldOverlapCatchesIntersectionButAllowsTouching() {
        let existing = [take(0, 5), take(10, 5)]   // [0,5) and [10,15)
        XCTAssertTrue(VoiceoverTimeline.wouldOverlap(start: 4, duration: 2, existing: existing))
        XCTAssertTrue(VoiceoverTimeline.wouldOverlap(start: 12, duration: 1, existing: existing))
        XCTAssertFalse(VoiceoverTimeline.wouldOverlap(start: 5, duration: 5, existing: existing),
                       "abutting the previous take's end is fine")
        XCTAssertFalse(VoiceoverTimeline.wouldOverlap(start: 15, duration: 3, existing: existing))
    }

    // MARK: Export-time overlap resolution — keep the newer take

    func testResolveOverlapsKeepsNewerAndSortsByStart() {
        let old = take(10, 6, at: 100)    // [10, 16)
        let new = take(14, 4, at: 200)    // [14, 18) — overlaps `old`
        let far = take(0, 3, at: 50)      // [0, 3) — no overlap

        let resolved = VoiceoverTimeline.resolveOverlaps([old, new, far])
        XCTAssertEqual(resolved.map(\.id), [far.id, new.id])
        XCTAssertTrue(VoiceoverTimeline.hasOverlaps([old, new, far]))
        XCTAssertFalse(VoiceoverTimeline.hasOverlaps(resolved))
    }

    func testResolveOverlapsIsANoOpWhenNothingIntersects() {
        let takes = [take(0, 3, at: 1), take(3, 3, at: 2), take(9, 3, at: 3)]
        XCTAssertEqual(VoiceoverTimeline.resolveOverlaps(takes).map(\.id), takes.map(\.id))
        XCTAssertFalse(VoiceoverTimeline.hasOverlaps(takes))
    }

    // MARK: 50 ms edge fades

    func testFadeRampsSitAtTheTakeEdges() {
        let fade = VoiceoverTimeline.fade(start: 12, duration: 4)
        XCTAssertEqual(fade.inStart, 12, accuracy: 1e-9)
        XCTAssertEqual(fade.inEnd, 12.05, accuracy: 1e-9)
        XCTAssertEqual(fade.outStart, 15.95, accuracy: 1e-9)
        XCTAssertEqual(fade.outEnd, 16, accuracy: 1e-9)
    }

    func testFadeOnAVeryShortTakeMeetsAtTheMidpointInsteadOfInverting() {
        let fade = VoiceoverTimeline.fade(start: 0, duration: 0.06)   // < 100 ms
        XCTAssertEqual(fade.inEnd, 0.03, accuracy: 1e-9)
        XCTAssertEqual(fade.outStart, 0.03, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(fade.inEnd, fade.outStart)
    }
}
