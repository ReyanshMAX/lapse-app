import SwiftData
import XCTest
@testable import StudyLapse
@testable import StudyLapseCore

/// The tagging screens mutate ranges through `TagEditor`, which round-trips
/// `TagRangeMath` results back onto `@Model` rows. Phase 0 already proves the
/// value-type math; this proves the `@Model` round trip keeps the tiling
/// invariant (BUILD.md Phase 4 criterion 1, at the persistence layer).
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

@MainActor
final class TagEditorTests: XCTestCase {
    private var container: ModelContainer!
    override func setUpWithError() throws { container = try ModelContainerFactory.makeInMemory() }
    override func tearDown() { container = nil }
    private var context: ModelContext { container.mainContext }

    private func makeSession(frameCounts: [Int], interval: Double = 2) -> Session {
        let session = Session(startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                              dayKey: "2026-08-24", captureIntervalSeconds: interval, outputFrameRate: 30)
        session.status = .ended
        context.insert(session)
        for (i, frames) in frameCounts.enumerated() {
            context.insert(Clip(session: session, index: i,
                                relativePath: "sessions/\(session.id.uuidString)/clips/\(i).mov",
                                startedAt: Date(), endedAt: Date(),
                                frameCount: frames, studyOffsetStart: 0, isFinalized: true))
        }
        StudyOffsets.recompute(for: session)
        try? context.save()
        return session
    }

    private func rowsTile(_ session: Session, total: Double) -> Bool {
        let rows = session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }
        return TagRangeMath.validate(rows.map {
            .init(start: $0.startStudySeconds, end: $0.endStudySeconds, tags: $0.tagNames)
        }, total: total)
    }

    func testInitSeedsAndMirrorsRows() {
        let session = makeSession(frameCounts: [40, 30, 20]) // 80/60/40 → 180
        let editor = TagEditor(session: session, context: context)
        XCTAssertEqual(editor.ranges.count, 3)
        XCTAssertEqual(editor.totalStudySeconds, 180)
        XCTAssertEqual(session.tagRanges.count, 3)
    }

    func testSplitMergeResizePersistAndKeepRowsTiling() {
        let session = makeSession(frameCounts: [60, 60]) // 120/120 → 240
        let editor = TagEditor(session: session, context: context)

        editor.split(at: 30)
        XCTAssertEqual(session.tagRanges.count, 3)
        XCTAssertTrue(rowsTile(session, total: 240))

        editor.previewResize(boundaryIndex: 0, to: 15)
        editor.commitResize()
        XCTAssertTrue(rowsTile(session, total: 240))

        editor.merge(at: 0)
        XCTAssertEqual(session.tagRanges.count, 2)
        XCTAssertTrue(rowsTile(session, total: 240))
    }

    func testResizeMarksRowManualButLeavesUntouchedRowsSegment() {
        let session = makeSession(frameCounts: [60, 60])
        let editor = TagEditor(session: session, context: context)
        editor.previewResize(boundaryIndex: 0, to: 90)
        editor.commitResize()
        let rows = session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }
        XCTAssertEqual(rows[0].origin, TagRangeOrigin.manual.rawValue)
        XCTAssertEqual(rows[1].origin, TagRangeOrigin.manual.rawValue, "the shared boundary moved both rows")
    }

    func testSetTagsNormalizesDedupesAndPersists() {
        let session = makeSession(frameCounts: [60])
        let editor = TagEditor(session: session, context: context)
        editor.setTags(["Calculus", "calculus ", "  ", "Physics"], at: 0)
        XCTAssertEqual(editor.ranges[0].tags, ["calculus", "physics"])
        XCTAssertEqual(session.tagRanges.first?.tagNames, ["calculus", "physics"])
        XCTAssertEqual(TagCatalog.existingTag(named: "calculus", in: context)?.useCount, 1)
    }

    func testRandomOperationSequenceKeepsPersistedRowsTiling() {
        var gen = SeededGenerator(seed: 0x7A6_5EED)
        let session = makeSession(frameCounts: Array(repeating: 90, count: 6)) // 180 each → 1080
        let total = 1080.0
        let editor = TagEditor(session: session, context: context)

        for _ in 0..<300 {
            switch Int.random(in: 0..<3, using: &gen) {
            case 0:
                editor.split(at: Double.random(in: 0...total, using: &gen))
            case 1:
                editor.merge(at: Int.random(in: -1...(editor.ranges.count + 1), using: &gen))
            default:
                let b = Int.random(in: -1...(editor.ranges.count), using: &gen)
                editor.previewResize(boundaryIndex: b, to: Double.random(in: -total...(2 * total), using: &gen))
                editor.commitResize()
            }
            XCTAssertTrue(rowsTile(session, total: total), "persisted rows stopped tiling")
            XCTAssertEqual(session.tagRanges.count, editor.ranges.count, "row count tracks the working set")
        }
    }
}
