import AVFoundation
import SwiftData
import XCTest
@testable import StudyLapse

/// BUILD.md Phase 2 criteria 3 & 4 (tagged `[device]`, run here in the
/// simulator job per docs/TESTING.md — see STATUS.md Deviations).
/// docs/TESTING.md: recovery tests must *actually* truncate a written file.
@MainActor
final class ClipRecoveryTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() {
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    /// Writes a real HEVC clip of `virtualSeconds` at a 3s interval and returns
    /// its relative path under the storage root.
    private func writeClip(virtualSeconds: Double) async throws -> String {
        let relativePath = "clip-recovery-tests/\(UUID().uuidString).mov"
        let url = StorageLocator.url(forRelativePath: relativePath)
        let source = SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
        let controller = CaptureController(source: source, clock: SystemClock())
        try controller.startClip(to: url, intervalSeconds: 3, outputFrameRate: 30)
        source.emit(seconds: virtualSeconds)
        _ = try await controller.finishClip()
        return relativePath
    }

    private func makeSession() -> Session {
        let session = Session(startedAt: .now, dayKey: "2026-08-26",
                              captureIntervalSeconds: 3, outputFrameRate: 30)
        context.insert(session)
        return session
    }

    private func addClip(to session: Session, index: Int, relativePath: String,
                         frameCount: Int, studyOffsetStart: Double, finalized: Bool) -> Clip {
        let clip = Clip(session: session, index: index, relativePath: relativePath,
                        startedAt: .now, frameCount: frameCount,
                        studyOffsetStart: studyOffsetStart, isFinalized: finalized)
        context.insert(clip)
        return clip
    }

    private func assertTiling(_ session: Session,
                              file: StaticString = #filePath, line: UInt = #line) {
        let finalized = session.clips.filter(\.isFinalized).sorted { $0.index < $1.index }
        var expected = 0.0
        for clip in finalized {
            XCTAssertEqual(clip.studyOffsetStart, expected, accuracy: 1e-9, file: file, line: line)
            expected += clip.studyDuration
        }
    }

    // MARK: Criterion 3 — force-quit mid-clip

    func testTruncatedMidClipFileLeavesNoUnfinalizedRows() async throws {
        let session = makeSession()

        // Chunk 0 finished cleanly: 20 frames = 60s of study.
        let goodPath = try await writeClip(virtualSeconds: 60)
        _ = addClip(to: session, index: 0, relativePath: goodPath,
                    frameCount: 20, studyOffsetStart: 0, finalized: true)

        // Chunk 1: writer never finished. Write a full file, then chop the tail
        // (which carries the moov atom for a non-fragmented .mov) to simulate a
        // force-quit mid-write.
        let brokenPath = try await writeClip(virtualSeconds: 60)
        let brokenURL = StorageLocator.url(forRelativePath: brokenPath)
        let fullSize = try FileManager.default.attributesOfItem(atPath: brokenURL.path)[.size] as! Int
        let handle = try FileHandle(forWritingTo: brokenURL)
        try handle.truncate(atOffset: UInt64(Double(fullSize) * 0.45))
        try handle.close()
        _ = addClip(to: session, index: 1, relativePath: brokenPath,
                    frameCount: 0, studyOffsetStart: 60, finalized: false)

        try context.save()

        await ClipRecovery.recoverUnfinalized(in: context)

        let clips = (try context.fetch(FetchDescriptor<Clip>()))
        XCTAssertFalse(clips.contains { !$0.isFinalized },
                       "no isFinalized == false row may survive recovery")
        XCTAssertTrue(clips.contains { $0.index == 0 && $0.frameCount == 20 },
                      "the cleanly finished chunk must be untouched")

        let studySeconds = clips.filter(\.isFinalized).reduce(0) { $0 + $1.studyDuration }
        XCTAssertGreaterThanOrEqual(studySeconds, 60, "the intact chunk's study time is kept")
        XCTAssertLessThanOrEqual(studySeconds, 60 + CaptureController.maxSegmentSeconds,
                                 "at most one chunk (120s) of study time can be lost")
        assertTiling(session)

        try? FileManager.default.removeItem(at: StorageLocator.url(forRelativePath: goodPath))
        try? FileManager.default.removeItem(at: brokenURL)
    }

    func testMissingAndZeroLengthFilesAreDeleted() async throws {
        let session = makeSession()
        _ = addClip(to: session, index: 0, relativePath: "clip-recovery-tests/gone-\(UUID().uuidString).mov",
                    frameCount: 0, studyOffsetStart: 0, finalized: false)

        let emptyPath = "clip-recovery-tests/empty-\(UUID().uuidString).mov"
        let emptyURL = StorageLocator.url(forRelativePath: emptyPath)
        try FileManager.default.createDirectory(at: emptyURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: emptyURL.path, contents: Data())
        _ = addClip(to: session, index: 1, relativePath: emptyPath,
                    frameCount: 0, studyOffsetStart: 0, finalized: false)
        try context.save()

        await ClipRecovery.recoverUnfinalized(in: context)

        let clips = try context.fetch(FetchDescriptor<Clip>())
        XCTAssertTrue(clips.isEmpty, "both unusable clip rows should be deleted")
        XCTAssertFalse(FileManager.default.fileExists(atPath: emptyURL.path))
    }

    func testCleanlyRecoverableFileKeepsItsFrames() async throws {
        let session = makeSession()
        // A file the writer *did* finish, but whose row somehow never flipped
        // isFinalized (crash between finishWriting and context.save). It is
        // fully readable, so recovery should keep it.
        let path = try await writeClip(virtualSeconds: 60)   // 20 frames, 0.667s of video
        let clip = addClip(to: session, index: 0, relativePath: path,
                           frameCount: 0, studyOffsetStart: 0, finalized: false)
        try context.save()

        let repaired = await ClipRecovery.recoverUnfinalized(in: context)

        XCTAssertEqual(repaired.count, 1)
        XCTAssertTrue(clip.isFinalized)
        XCTAssertTrue(clip.wasRecovered)
        XCTAssertGreaterThan(clip.frameCount, 0)
        // ~0.667s of video * 30fps ≈ 20 frames, allow encoder slack.
        XCTAssertEqual(Double(clip.frameCount), 20, accuracy: 4)
        assertTiling(session)

        try? FileManager.default.removeItem(at: StorageLocator.url(forRelativePath: path))
    }

    // MARK: Criterion 4 — session left .recording at launch

    func testRecordingSessionsAreDemotedToPaused() throws {
        let recording = makeSession(); recording.status = .recording
        let paused = makeSession(); paused.status = .paused
        let ended = makeSession(); ended.status = .ended
        try context.save()

        let demoted = ClipRecovery.demoteRecordingSessions(in: context)

        XCTAssertEqual(demoted.count, 1)
        XCTAssertEqual(recording.status, .paused)
        XCTAssertEqual(paused.status, .paused)
        XCTAssertEqual(ended.status, .ended)
    }
}
