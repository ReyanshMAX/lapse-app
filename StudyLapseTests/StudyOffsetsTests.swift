import SwiftData
import XCTest
@testable import StudyLapse

/// BUILD.md Phase 2 criterion 2 (tagged `[device]`, but per docs/TESTING.md
/// the `studyOffsetStart` tiling invariant is fully CI-verifiable — see
/// STATUS.md Deviations). Inserts, finalizes, and deletes clips in arbitrary
/// order and asserts the invariant holds after each `StudyOffsets.recompute`.
@MainActor
final class StudyOffsetsTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() {
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    private func makeSession(interval: Double = 3) -> Session {
        let session = Session(startedAt: .now, dayKey: "2026-08-26",
                              captureIntervalSeconds: interval, outputFrameRate: 30)
        context.insert(session)
        return session
    }

    private func addClip(to session: Session, index: Int, frameCount: Int,
                         finalized: Bool) {
        let clip = Clip(session: session, index: index,
                        relativePath: "sessions/x/clips/\(index).mov",
                        startedAt: .now, frameCount: frameCount,
                        isFinalized: finalized)
        context.insert(clip)
    }

    /// Asserts the DATA_MODEL.md invariant over the finalized clips of `session`.
    private func assertInvariant(_ session: Session,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let finalized = session.clips.filter(\.isFinalized).sorted { $0.index < $1.index }
        var expected = 0.0
        for clip in finalized {
            XCTAssertEqual(clip.studyOffsetStart, expected, accuracy: 1e-9,
                           "offset mismatch at index \(clip.index)", file: file, line: line)
            expected += clip.studyDuration
        }
    }

    func testOffsetsAfterSequentialFinalize() throws {
        let session = makeSession()
        addClip(to: session, index: 0, frameCount: 40, finalized: true)   // 120s
        addClip(to: session, index: 1, frameCount: 100, finalized: true)  // 300s
        addClip(to: session, index: 2, frameCount: 20, finalized: true)   // 60s
        StudyOffsets.recompute(for: session)
        assertInvariant(session)

        let offsets = session.clips.sorted { $0.index < $1.index }.map(\.studyOffsetStart)
        XCTAssertEqual(offsets, [0, 120, 420])
    }

    func testUnfinalizedClipIsExcludedThenIncludedOnFinalize() throws {
        let session = makeSession()
        addClip(to: session, index: 0, frameCount: 40, finalized: true)
        addClip(to: session, index: 1, frameCount: 10, finalized: false)  // recording
        StudyOffsets.recompute(for: session)
        assertInvariant(session)
        XCTAssertEqual(StudyOffsets.runningTotal(for: session), 120)

        // Clip 1 finishes with more frames than it had mid-recording.
        let clip1 = session.clips.first { $0.index == 1 }!
        clip1.frameCount = 100
        clip1.isFinalized = true
        StudyOffsets.recompute(for: session)
        assertInvariant(session)
        XCTAssertEqual(clip1.studyOffsetStart, 120)
    }

    func testOffsetsAfterOutOfOrderInsertAndDelete() throws {
        let session = makeSession()
        // Insert out of index order.
        addClip(to: session, index: 2, frameCount: 20, finalized: true)
        addClip(to: session, index: 0, frameCount: 40, finalized: true)
        addClip(to: session, index: 1, frameCount: 100, finalized: true)
        addClip(to: session, index: 3, frameCount: 33, finalized: true)
        StudyOffsets.recompute(for: session)
        assertInvariant(session)

        // Delete the middle clip (index 1) — leaves a gap in indices, which is
        // allowed; sorted order still defines the tiling.
        let middle = session.clips.first { $0.index == 1 }!
        context.delete(middle)
        session.clips.removeAll { $0.index == 1 }
        StudyOffsets.recompute(for: session)
        assertInvariant(session)

        let remaining = session.clips.sorted { $0.index < $1.index }
        XCTAssertEqual(remaining.map(\.index), [0, 2, 3])
        XCTAssertEqual(remaining.map(\.studyOffsetStart), [0, 120, 180])
    }

    func testRandomOperationSequencePreservesInvariant() throws {
        var rng = SeededRNG(seed: 0xC0FFEE)
        for _ in 0..<200 {
            let session = makeSession(interval: [1.0, 3.0, 5.0].randomElement(using: &rng)!)
            var nextIndex = 0
            let operations = Int.random(in: 1...12, using: &rng)
            for _ in 0..<operations {
                switch Int.random(in: 0...2, using: &rng) {
                case 0: // append a finalized clip
                    addClip(to: session, index: nextIndex,
                            frameCount: Int.random(in: 1...1000, using: &rng), finalized: true)
                    nextIndex += 1
                case 1: // append an unfinalized clip
                    addClip(to: session, index: nextIndex,
                            frameCount: Int.random(in: 0...50, using: &rng), finalized: false)
                    nextIndex += 1
                default: // delete a random existing clip
                    if let victim = session.clips.randomElement(using: &rng) {
                        let victimIndex = victim.index
                        context.delete(victim)
                        session.clips.removeAll { $0.index == victimIndex }
                    }
                }
                StudyOffsets.recompute(for: session)
                assertInvariant(session)
            }
            context.delete(session)
        }
    }
}

/// Deterministic RNG so the random-sequence test is reproducible in CI.
private struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
