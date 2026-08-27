import SwiftData
import XCTest
@testable import StudyLapse

@MainActor
final class TagCatalogTests: XCTestCase {
    private var container: ModelContainer!
    override func setUpWithError() throws { container = try ModelContainerFactory.makeInMemory() }
    override func tearDown() { container = nil }
    private var context: ModelContext { container.mainContext }

    func testNormalizeTrimsAndLowercases() {
        XCTAssertEqual(TagCatalog.normalize("  Organic Chemistry \n"), "organic chemistry")
        XCTAssertEqual(TagCatalog.normalize("CALC"), "calc")
    }

    func testEnsureCreatesOnceAndReusesByNormalizedName() {
        let a = TagCatalog.ensure("Calculus", in: context)
        let b = TagCatalog.ensure("  calculus", in: context)
        XCTAssertNotNil(a)
        XCTAssertIdentical(a, b)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Tag>())), 1)
        XCTAssertEqual(a?.displayName, "Calculus", "display casing is the first spelling seen")
    }

    func testEnsureRejectsBlank() {
        XCTAssertNil(TagCatalog.ensure("   ", in: context))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Tag>())), 0)
    }

    func testEnsureAssignsDistinctPaletteColours() {
        let first = TagCatalog.ensure("a", in: context)
        let second = TagCatalog.ensure("b", in: context)
        XCTAssertEqual(first?.colorHex, TagCatalog.palette[0])
        XCTAssertEqual(second?.colorHex, TagCatalog.palette[1])
    }

    func testRefreshUseCountsDerivesFromRanges() {
        let session = Session(startedAt: Date(), dayKey: "2026-08-24",
                              captureIntervalSeconds: 2, outputFrameRate: 30)
        context.insert(session)
        TagCatalog.ensure("calc", in: context)
        TagCatalog.ensure("physics", in: context)
        context.insert(TagRange(session: session, startStudySeconds: 0, endStudySeconds: 10, tagNames: ["calc"]))
        context.insert(TagRange(session: session, startStudySeconds: 10, endStudySeconds: 20, tagNames: ["calc", "physics"]))
        try? context.save()

        TagCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(TagCatalog.existingTag(named: "calc", in: context)?.useCount, 2)
        XCTAssertEqual(TagCatalog.existingTag(named: "physics", in: context)?.useCount, 1)
    }

    func testRefreshUseCountsDoesNotDriftOnRemoveThenReAdd() {
        let session = Session(startedAt: Date(), dayKey: "2026-08-24",
                              captureIntervalSeconds: 2, outputFrameRate: 30)
        context.insert(session)
        TagCatalog.ensure("calc", in: context)
        let range = TagRange(session: session, startStudySeconds: 0, endStudySeconds: 10, tagNames: ["calc"])
        context.insert(range)
        try? context.save()

        TagCatalog.refreshUseCounts(in: context)
        range.tagNames = []
        TagCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(TagCatalog.existingTag(named: "calc", in: context)?.useCount, 0)
        range.tagNames = ["calc"]
        TagCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(TagCatalog.existingTag(named: "calc", in: context)?.useCount, 1)
    }

    func testSuggestionsRankByUseCountThenSubstringMatch() {
        let session = Session(startedAt: Date(), dayKey: "2026-08-24",
                              captureIntervalSeconds: 2, outputFrameRate: 30)
        context.insert(session)
        for name in ["calculus", "calligraphy", "physics"] { TagCatalog.ensure(name, in: context) }
        // calculus used twice, calligraphy once
        context.insert(TagRange(session: session, startStudySeconds: 0, endStudySeconds: 1, tagNames: ["calculus"]))
        context.insert(TagRange(session: session, startStudySeconds: 1, endStudySeconds: 2, tagNames: ["calculus"]))
        context.insert(TagRange(session: session, startStudySeconds: 2, endStudySeconds: 3, tagNames: ["calligraphy"]))
        try? context.save()
        TagCatalog.refreshUseCounts(in: context)

        let all = TagCatalog.suggestions(matching: "", in: context)
        XCTAssertEqual(all.first?.name, "calculus")

        let cal = TagCatalog.suggestions(matching: "cal", in: context).map(\.name)
        XCTAssertEqual(cal, ["calculus", "calligraphy"])
        XCTAssertFalse(cal.contains("physics"))
    }
}
