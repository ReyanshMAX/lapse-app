import SwiftData
import XCTest
@testable import StudyLapse
@testable import StudyLapseCore

/// Phase 6. The record itself is device-only (`AVAudioRecorder`), so a stub
/// recorder drives the coordinator — take placement, overlap gating, staleness,
/// and delete are all pure model work and run in the `simulator` job.
@MainActor
final class VoiceoverCoordinatorTests: XCTestCase {
    private var container: ModelContainer!
    private var cleanupIDs: [UUID] = []

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        cleanupIDs = []
    }

    override func tearDown() {
        for id in cleanupIDs {
            try? FileManager.default.removeItem(at: SessionStorage.directory(for: id))
        }
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    private final class StubRecorder: VoiceoverRecording {
        var isRecording = false
        let fixedDuration: Double
        init(duration: Double) { fixedDuration = duration }
        func start(to url: URL) throws {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try Data([0, 1, 2, 3]).write(to: url)
            isRecording = true
        }
        func stop() -> Double { isRecording = false; return fixedDuration }
    }

    private func makeSession() -> Session {
        let session = Session(startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                              dayKey: "2026-08-24", captureIntervalSeconds: 2, outputFrameRate: 30)
        session.status = .ended
        context.insert(session)
        cleanupIDs.append(session.id)
        return session
    }

    private func coordinator(_ session: Session, revision: Int = 0,
                             takeDuration: Double = 2) -> VoiceoverCoordinator {
        VoiceoverCoordinator(context: context, session: session,
                             recordedAgainstRevision: revision,
                             makeRecorder: { StubRecorder(duration: takeDuration) })
    }

    @discardableResult
    private func seedTake(_ session: Session, start: Double, duration: Double,
                          revision: Int = 0, muted: Bool = false,
                          createdAt: Date = .now) -> VoiceoverTake {
        let rel = "sessions/\(session.id.uuidString)/voiceovers/\(UUID().uuidString).m4a"
        let url = StorageLocator.url(forRelativePath: rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data([0]))
        let take = VoiceoverTake(session: session, relativePath: rel,
                                 outputStartSeconds: start, durationSeconds: duration,
                                 recordedAgainstProfileRevision: revision, isMuted: muted,
                                 createdAt: createdAt)
        context.insert(take)
        try? context.save()
        return take
    }

    // MARK: Take placement + revision stamp (criterion 1 logic)

    func testStartThenStopPersistsTakeAtPlayheadWithRevision() async throws {
        let session = makeSession()
        let coordinator = coordinator(session, revision: 3, takeDuration: 2.5)

        try coordinator.startTake(at: 12.0)
        XCTAssertTrue(coordinator.isRecording)
        let take = await coordinator.stopTake()

        let take2 = try XCTUnwrap(take)
        XCTAssertEqual(take2.outputStartSeconds, 12.0, accuracy: 1e-9)
        XCTAssertEqual(take2.durationSeconds, 2.5, accuracy: 1e-9)
        XCTAssertEqual(take2.recordedAgainstProfileRevision, 3)
        XCTAssertFalse(coordinator.isRecording)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: StorageLocator.url(forRelativePath: take2.relativePath).path))
    }

    func testStopWithNothingRecordingReturnsNil() async {
        let session = makeSession()
        let take = await coordinator(session).stopTake()
        XCTAssertNil(take)
    }

    // MARK: Overlap gating (criterion 3 logic)

    func testRecordButtonGatingInsideAnExistingTake() throws {
        let session = makeSession()
        seedTake(session, start: 10, duration: 5)   // occupies [10, 15)
        let coordinator = coordinator(session)

        XCTAssertTrue(coordinator.playheadIsInsideTake(12))
        XCTAssertFalse(coordinator.playheadIsInsideTake(15))
        XCTAssertFalse(coordinator.playheadIsInsideTake(3))

        XCTAssertThrowsError(try coordinator.startTake(at: 12)) {
            XCTAssertEqual($0 as? VoiceoverError, .playheadInsideExistingTake)
        }
        XCTAssertNoThrow(try coordinator.startTake(at: 15))
    }

    // MARK: Delete removes row + file

    func testDeleteRemovesRowAndFile() throws {
        let session = makeSession()
        let take = seedTake(session, start: 0, duration: 2)
        let url = StorageLocator.url(forRelativePath: take.relativePath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        coordinator(session).delete(take)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<VoiceoverTake>()), 0)
    }

    // MARK: Staleness (criterion 2 logic)

    func testStaleTakesTrackTheProfileRevision() throws {
        let session = makeSession()
        seedTake(session, start: 0, duration: 2, revision: 0)
        seedTake(session, start: 5, duration: 2, revision: 1)
        let coordinator = coordinator(session)

        let profile = ExportProfile(session: session)
        profile.reconcileRevision()                 // stamps, revision stays 0
        XCTAssertEqual(coordinator.staleTakes(for: profile).map(\.outputStartSeconds), [5])

        profile.includeIntroCard.toggle()
        profile.reconcileRevision()                 // revision → 1
        XCTAssertEqual(profile.revision, 1)
        XCTAssertEqual(coordinator.staleTakes(for: profile).map(\.outputStartSeconds), [0])
    }

    // MARK: Export snapshots — muted / stale excluded, overlaps resolved

    func testExportSnapshotsFilterAndResolve() throws {
        let session = makeSession()
        let profile = ExportProfile(session: session)
        profile.reconcileRevision()                 // revision 0

        seedTake(session, start: 0, duration: 3, revision: 0)                     // kept
        seedTake(session, start: 20, duration: 3, revision: 0, muted: true)       // muted → out
        seedTake(session, start: 40, duration: 3, revision: 9)                    // stale → out
        let old = seedTake(session, start: 10, duration: 6, revision: 0,
                           createdAt: Date(timeIntervalSince1970: 100))           // [10,16)
        _ = old
        seedTake(session, start: 14, duration: 4, revision: 0,
                 createdAt: Date(timeIntervalSince1970: 200))                     // [14,18) newer → wins

        let snapshots = VoiceoverCoordinator.exportSnapshots(session: session, profile: profile)
        XCTAssertEqual(snapshots.map(\.outputStartSeconds), [0, 14],
                       "muted + stale dropped, and the newer of the overlapping pair kept")
    }
}
