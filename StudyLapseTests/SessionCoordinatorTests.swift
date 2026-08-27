import AVFoundation
import SwiftData
import XCTest
@testable import StudyLapse

/// BUILD.md Phase 2: multi-clip sessions with a correct study-time axis.
/// Criteria 5 & 6 are `[eyes-on]`; the study-time math and cross-relaunch
/// persistence underneath them are exercised here in the simulator job.
@MainActor
final class SessionCoordinatorTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() {
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 5,
                           _ message: String = "condition not met",
                           file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func newSource() -> SyntheticFrameSource {
        SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
    }

    private func cleanupClipFiles() {
        let clips = (try? context.fetch(FetchDescriptor<Clip>())) ?? []
        for clip in clips {
            try? FileManager.default.removeItem(at: StorageLocator.url(forRelativePath: clip.relativePath))
        }
    }

    /// Criterion 5's math: record 2 min, pause, "10 minutes" pass, resume,
    /// record 2 min — study time is 4 min, not the ~14 min of wall clock.
    func testMultiClipSessionAccumulatesOnlyStudyTime() async throws {
        let source = newSource()
        let coordinator = SessionCoordinator(context: context, makeFrameSource: { source })

        try coordinator.startNewSession()
        source.emit(seconds: 120)                 // 2 minutes studied → 40 frames
        await coordinator.pause()
        await waitUntil({ coordinator.clipCount == 1 }, "first chunk not persisted")

        // 10 minutes backgrounded — nothing emitted.
        try coordinator.resume()
        source.emit(seconds: 120)                 // 2 more minutes → 40 frames
        await coordinator.end()
        await waitUntil({ coordinator.status == .ended }, "session did not end")

        let clips = try context.fetch(FetchDescriptor<Clip>()).sorted { $0.index < $1.index }
        XCTAssertEqual(clips.count, 2)
        XCTAssertTrue(clips.allSatisfy(\.isFinalized))
        XCTAssertEqual(clips.reduce(0) { $0 + $1.frameCount }, 80)
        XCTAssertEqual(clips.map(\.index), [0, 1])
        XCTAssertEqual(clips.map(\.studyOffsetStart), [0, 120])
        XCTAssertEqual(coordinator.studySeconds, 240, accuracy: 3,
                       "study time is the 4 min recorded, not ~14 min of wall clock")

        cleanupClipFiles()
    }

    /// Criterion 6: the session survives a full app kill and relaunch, and
    /// resumes cleanly with correct clip indexing and study time.
    func testSessionSurvivesRelaunchAndResumes() async throws {
        let source1 = newSource()
        let first = SessionCoordinator(context: context, makeFrameSource: { source1 })
        try first.startNewSession()
        source1.emit(seconds: 90)                 // 30 frames → 90s
        await first.pause()
        await waitUntil({ first.clipCount == 1 })
        let sessionID = try XCTUnwrap(first.session?.id)

        // App killed — a brand-new coordinator over the same store.
        let source2 = newSource()
        let relaunched = SessionCoordinator(context: context, makeFrameSource: { source2 })
        await relaunched.recoverOnLaunch()

        XCTAssertEqual(relaunched.session?.id, sessionID)
        XCTAssertEqual(relaunched.status, .paused)
        XCTAssertEqual(relaunched.clipCount, 1)
        XCTAssertEqual(relaunched.studySeconds, 90, accuracy: 1)

        try relaunched.resume()
        source2.emit(seconds: 60)                 // 20 frames → 60s
        await relaunched.end()
        await waitUntil({ relaunched.status == .ended })

        let clips = try context.fetch(FetchDescriptor<Clip>()).sorted { $0.index < $1.index }
        XCTAssertEqual(clips.map(\.index), [0, 1])
        XCTAssertEqual(clips.reduce(0) { $0 + $1.frameCount }, 50)
        XCTAssertEqual(clips.map(\.studyOffsetStart), [0, 90])
        XCTAssertEqual(relaunched.studySeconds, 150, accuracy: 3)

        cleanupClipFiles()
    }

    /// D-016: leaving the app finalizes the current chunk and pauses — it does
    /// not end the session or drop the recorded time.
    func testBackgroundingAutoPausesRecording() async throws {
        let source = newSource()
        let coordinator = SessionCoordinator(context: context, makeFrameSource: { source })

        try coordinator.startNewSession()
        source.emit(seconds: 30)                  // 10 frames → 30s
        await coordinator.handleScenePhase(.background)

        XCTAssertEqual(coordinator.status, .paused)
        XCTAssertNotNil(coordinator.session)
        await waitUntil({ coordinator.clipCount == 1 })

        let clips = try context.fetch(FetchDescriptor<Clip>())
        XCTAssertEqual(clips.count, 1)
        XCTAssertEqual(clips.first?.frameCount, 10)
        XCTAssertTrue(clips.first?.isFinalized == true)

        await coordinator.end()
        cleanupClipFiles()
    }

    func testStartingASecondSessionWhileActiveThrows() async throws {
        let source = newSource()
        let coordinator = SessionCoordinator(context: context, makeFrameSource: { source })
        try coordinator.startNewSession()
        XCTAssertThrowsError(try coordinator.startNewSession())
        await coordinator.end()
        cleanupClipFiles()
    }
}
