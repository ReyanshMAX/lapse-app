import SwiftData
import XCTest
@testable import StudyLapse

@MainActor
final class ProjectCatalogTests: XCTestCase {
    private var container: ModelContainer!
    override func setUpWithError() throws { container = try ModelContainerFactory.makeInMemory() }
    override func tearDown() { container = nil }
    private var context: ModelContext { container.mainContext }

    func testNormalizeTrimsAndLowercases() {
        XCTAssertEqual(ProjectCatalog.normalize("  MCAT Prep \n"), "mcat prep")
        XCTAssertEqual(ProjectCatalog.normalize("THESIS"), "thesis")
    }

    func testEnsureCreatesOnceAndReusesByNormalizedName() {
        let a = ProjectCatalog.ensure("Thesis", in: context)
        let b = ProjectCatalog.ensure("  thesis", in: context)
        XCTAssertNotNil(a)
        XCTAssertIdentical(a, b)
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Project>())), 1)
        XCTAssertEqual(a?.displayName, "Thesis", "display casing is the first spelling seen")
    }

    func testEnsureRejectsBlank() {
        XCTAssertNil(ProjectCatalog.ensure("   ", in: context))
        XCTAssertEqual((try? context.fetchCount(FetchDescriptor<Project>())), 0)
    }

    func testEnsureAssignsDistinctPaletteColours() {
        let first = ProjectCatalog.ensure("a", in: context)
        let second = ProjectCatalog.ensure("b", in: context)
        XCTAssertEqual(first?.colorHex, ProjectCatalog.palette[0])
        XCTAssertEqual(second?.colorHex, ProjectCatalog.palette[1])
    }

    func testRefreshUseCountsDerivesFromSessions() {
        ProjectCatalog.ensure("thesis", in: context)
        ProjectCatalog.ensure("mcat", in: context)
        let s1 = Session(startedAt: Date(), dayKey: "2026-08-24", captureIntervalSeconds: 2, outputFrameRate: 30)
        s1.projectName = "thesis"
        let s2 = Session(startedAt: Date(), dayKey: "2026-08-25", captureIntervalSeconds: 2, outputFrameRate: 30)
        s2.projectName = "thesis"
        let s3 = Session(startedAt: Date(), dayKey: "2026-08-26", captureIntervalSeconds: 2, outputFrameRate: 30)
        s3.projectName = "mcat"
        context.insert(s1); context.insert(s2); context.insert(s3)
        try? context.save()

        ProjectCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(ProjectCatalog.existingProject(named: "thesis", in: context)?.useCount, 2)
        XCTAssertEqual(ProjectCatalog.existingProject(named: "mcat", in: context)?.useCount, 1)
    }

    func testRefreshUseCountsDoesNotDriftOnRemoveThenReAdd() {
        ProjectCatalog.ensure("thesis", in: context)
        let session = Session(startedAt: Date(), dayKey: "2026-08-24", captureIntervalSeconds: 2, outputFrameRate: 30)
        session.projectName = "thesis"
        context.insert(session)
        try? context.save()

        ProjectCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(ProjectCatalog.existingProject(named: "thesis", in: context)?.useCount, 1)

        session.projectName = nil
        ProjectCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(ProjectCatalog.existingProject(named: "thesis", in: context)?.useCount, 0)

        session.projectName = "thesis"
        ProjectCatalog.refreshUseCounts(in: context)
        XCTAssertEqual(ProjectCatalog.existingProject(named: "thesis", in: context)?.useCount, 1)
    }

    func testSuggestionsRankByUseCount() {
        ProjectCatalog.ensure("thesis", in: context)
        ProjectCatalog.ensure("mcat", in: context)
        let s1 = Session(startedAt: Date(), dayKey: "2026-08-24", captureIntervalSeconds: 2, outputFrameRate: 30)
        s1.projectName = "mcat"
        let s2 = Session(startedAt: Date(), dayKey: "2026-08-25", captureIntervalSeconds: 2, outputFrameRate: 30)
        s2.projectName = "mcat"
        context.insert(s1); context.insert(s2)
        try? context.save()
        ProjectCatalog.refreshUseCounts(in: context)

        let ranked = ProjectCatalog.suggestions(in: context).map(\.name)
        XCTAssertEqual(ranked.first, "mcat")
    }
}
