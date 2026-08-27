import SwiftData
import XCTest
@testable import StudyLapse
@testable import StudyLapseCore

/// BUILD.md Phase 4 criterion 3: ending a session seeds exactly one `TagRange`
/// per finalized clip. Tagged `[device]`, but the seeding is pure model math
/// with no device-specific behaviour (same situation as Phase 2's criteria
/// 2/3/4) — exercised here in the `simulator` job.
@MainActor
final class TagRangeSeedingTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() { container = nil }

    private var context: ModelContext { container.mainContext }

    /// A finalized session with `frameCounts.count` clips and no tag ranges.
    private func makeSession(interval: Double = 2, fps: Int32 = 30,
                             frameCounts: [Int]) -> Session {
        let session = Session(startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                              dayKey: "2026-08-24",
                              captureIntervalSeconds: interval, outputFrameRate: fps)
        session.status = .ended
        context.insert(session)
        for (i, frames) in frameCounts.enumerated() {
            let clip = Clip(session: session, index: i,
                            relativePath: "sessions/\(session.id.uuidString)/clips/\(i).mov",
                            startedAt: Date(), endedAt: Date(),
                            frameCount: frames, studyOffsetStart: 0, isFinalized: true)
            context.insert(clip)
        }
        StudyOffsets.recompute(for: session)
        try? context.save()
        return session
    }

    private func sortedRanges(_ session: Session) -> [TagRange] {
        session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }
    }

    private func tiles(_ session: Session, total: Double) -> Bool {
        TagRangeMath.validate(sortedRanges(session).map {
            .init(start: $0.startStudySeconds, end: $0.endStudySeconds, tags: $0.tagNames)
        }, total: total)
    }

    // MARK: Criterion 3 — one range per finalized clip

    func testSeedsExactlyOneRangePerFinalizedClip() {
        let session = makeSession(frameCounts: [40, 30, 20]) // 80s, 60s, 40s @2s
        TagRangeSeeding.ensureSeeded(for: session, in: context)

        XCTAssertEqual(session.tagRanges.count, 3)
        XCTAssertTrue(tiles(session, total: 180))
        XCTAssertEqual(sortedRanges(session).map(\.startStudySeconds), [0, 80, 140])
        XCTAssertTrue(session.tagRanges.allSatisfy { $0.origin == TagRangeOrigin.segment.rawValue })
        XCTAssertTrue(session.tagRanges.allSatisfy { $0.tagNames.isEmpty })
    }

    func testCoordinatorEndSeedsRangesAndExposesEndedSession() async throws {
        UserDefaults.standard.set(3.0, forKey: "captureIntervalSeconds")
        defer { UserDefaults.standard.removeObject(forKey: "captureIntervalSeconds") }

        let source = SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
        let coordinator = SessionCoordinator(context: context, makeFrameSource: { source })
        try coordinator.startNewSession()
        source.emit(seconds: 90)                      // 30 frames → clip 0
        await coordinator.pause()
        let deadline = Date().addingTimeInterval(5)
        while coordinator.clipCount < 1 && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        try coordinator.resume()
        source.emit(seconds: 60)                      // 20 frames → clip 1
        await coordinator.end()

        let ended = try XCTUnwrap(coordinator.lastEndedSession)
        let finalized = ended.orderedFinalizedClips.count
        XCTAssertEqual(finalized, 2)
        XCTAssertEqual(ended.tagRanges.count, finalized)
        XCTAssertTrue(tiles(ended, total: 150))

        for clip in ended.clips {
            try? FileManager.default.removeItem(at: StorageLocator.url(forRelativePath: clip.relativePath))
        }
    }

    // MARK: Repair semantics

    func testIdempotentAcrossRepeatedCalls() {
        let session = makeSession(frameCounts: [40, 30])
        TagRangeSeeding.ensureSeeded(for: session, in: context)
        TagRangeSeeding.ensureSeeded(for: session, in: context)
        TagRangeSeeding.ensureSeeded(for: session, in: context)
        XCTAssertEqual(session.tagRanges.count, 2)
        XCTAssertTrue(tiles(session, total: 140))
    }

    func testReseedsWhenAnUntouchedClipLandsLate() {
        let session = makeSession(frameCounts: [40, 30])
        TagRangeSeeding.ensureSeeded(for: session, in: context)
        XCTAssertEqual(session.tagRanges.count, 2)

        // A rollover clip whose persist Task landed after end().
        let late = Clip(session: session, index: 2,
                        relativePath: "sessions/\(session.id.uuidString)/clips/2.mov",
                        startedAt: Date(), endedAt: Date(),
                        frameCount: 20, studyOffsetStart: 0, isFinalized: true)
        context.insert(late)
        StudyOffsets.recompute(for: session)

        TagRangeSeeding.ensureSeeded(for: session, in: context)
        XCTAssertEqual(session.tagRanges.count, 3)
        XCTAssertTrue(tiles(session, total: 180))
    }

    func testPreservesUserTagsAndCoversTailGapWhenAClipLandsLate() {
        let session = makeSession(frameCounts: [40, 30])
        TagRangeSeeding.ensureSeeded(for: session, in: context)
        let first = sortedRanges(session)[0]
        first.tagNames = ["calculus"]
        try? context.save()

        let late = Clip(session: session, index: 2,
                        relativePath: "sessions/\(session.id.uuidString)/clips/2.mov",
                        startedAt: Date(), endedAt: Date(),
                        frameCount: 20, studyOffsetStart: 0, isFinalized: true)
        context.insert(late)
        StudyOffsets.recompute(for: session)

        TagRangeSeeding.ensureSeeded(for: session, in: context)
        XCTAssertEqual(session.tagRanges.count, 3, "keeps the 2 user-touched ranges, appends 1 for the gap")
        XCTAssertTrue(tiles(session, total: 180))
        XCTAssertEqual(sortedRanges(session)[0].tagNames, ["calculus"])
        XCTAssertTrue(sortedRanges(session).last!.tagNames.isEmpty)
    }

    func testNoOpWhenSessionHasNoFinalizedClips() {
        let session = Session(startedAt: Date(), dayKey: "2026-08-24",
                              captureIntervalSeconds: 2, outputFrameRate: 30)
        session.status = .ended
        context.insert(session)
        TagRangeSeeding.ensureSeeded(for: session, in: context)
        XCTAssertTrue(session.tagRanges.isEmpty)
    }
}
