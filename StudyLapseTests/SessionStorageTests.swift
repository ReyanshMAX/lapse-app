import SwiftData
import XCTest
@testable import StudyLapse

/// BUILD.md Phase 5 criteria 1–3 (tagged `[device]`, exercised here in the
/// `simulator` job — pure storage + model math, no device-specific behaviour,
/// same situation as Phase 2/4). Directories are created and deleted for real.
@MainActor
final class SessionStorageTests: XCTestCase {
    private var container: ModelContainer!

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
    }

    override func tearDown() { container = nil }

    private var context: ModelContext { container.mainContext }

    /// A finalized session with `frameCounts.count` clips, and real (empty)
    /// files on disk under `sessions/<id>/clips/` plus an exports file.
    @discardableResult
    private func makeSessionOnDisk(frameCounts: [Int] = [20, 20]) throws -> Session {
        let session = Session(startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                              dayKey: "2026-08-24",
                              captureIntervalSeconds: 2, outputFrameRate: 30)
        session.status = .ended
        context.insert(session)

        let dir = SessionStorage.directory(for: session.id)
        let clipsDir = dir.appendingPathComponent("clips", isDirectory: true)
        let exportsDir = dir.appendingPathComponent("exports", isDirectory: true)
        try FileManager.default.createDirectory(at: clipsDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: exportsDir, withIntermediateDirectories: true)

        for (i, frames) in frameCounts.enumerated() {
            let relative = "sessions/\(session.id.uuidString)/clips/\(String(format: "%03d", i))_\(UUID().uuidString).mov"
            let url = StorageLocator.url(forRelativePath: relative)
            FileManager.default.createFile(atPath: url.path, contents: Data([0x00, 0x01]))
            let clip = Clip(session: session, index: i, relativePath: relative,
                            startedAt: Date(), endedAt: Date(),
                            frameCount: frames, studyOffsetStart: 0, isFinalized: true)
            context.insert(clip)
        }
        let exportRelative = "sessions/\(session.id.uuidString)/exports/\(UUID().uuidString).mov"
        FileManager.default.createFile(atPath: StorageLocator.url(forRelativePath: exportRelative).path,
                                       contents: Data([0x00]))
        let export = ExportRecord(session: session, relativePath: exportRelative,
                                  profileRevision: 0, durationSeconds: 3, fileSizeBytes: 1)
        context.insert(export)

        StudyOffsets.recompute(for: session)
        try context.save()
        return session
    }

    private func addCleanup(_ id: UUID) {
        addTeardownBlock {
            try? FileManager.default.removeItem(at: SessionStorage.directory(for: id))
        }
    }

    // MARK: Criterion 1 — delete removes rows AND directory

    func testDeleteSessionRemovesRowsAndDirectory() throws {
        let session = try makeSessionOnDisk()
        let id = session.id
        addCleanup(id)
        let dir = SessionStorage.directory(for: id)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))

        SessionStorage.deleteSession(session, in: context)

        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path), "directory gone")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Session>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Clip>()), 0, "clip rows cascade")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<ExportRecord>()), 0, "export rows cascade")
    }

    // MARK: Criterion 2 — launch sweep removes orphan directories only

    func testSweepRemovesOrphanDirectoryButKeepsKnownAndUnparseable() throws {
        let known = try makeSessionOnDisk()
        addCleanup(known.id)
        let knownDir = SessionStorage.directory(for: known.id)

        // An orphan: a UUID-named dir with no Session row.
        let orphanID = UUID()
        let orphanDir = SessionStorage.directory(for: orphanID)
        try FileManager.default.createDirectory(at: orphanDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: orphanDir) }

        // A non-UUID directory the sweep must never touch.
        let strayDir = StorageLocator.url(forRelativePath: "sessions/not-a-uuid-\(Int.random(in: 0...9999))")
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: strayDir) }

        let removed = SessionStorage.sweepOrphanedDirectories(in: context)

        XCTAssertTrue(removed.contains(orphanID.uuidString))
        XCTAssertFalse(removed.contains(known.id.uuidString))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanDir.path), "orphan removed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: knownDir.path), "known session kept")
        XCTAssertTrue(FileManager.default.fileExists(atPath: strayDir.path), "unparseable name kept")
    }

    // MARK: Criterion 3 — purge keeps rows/exports, blocks re-export

    func testPurgeSourcesKeepsRowsAndExportsAndBlocksReExport() throws {
        let session = try makeSessionOnDisk(frameCounts: [30, 20]) // 100s @2s
        addCleanup(session.id)
        let dir = SessionStorage.directory(for: session.id)
        let clipsDir = dir.appendingPathComponent("clips", isDirectory: true)
        let exportsDir = dir.appendingPathComponent("exports", isDirectory: true)

        let studyBefore = session.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration }
        XCTAssertEqual(studyBefore, 100)
        XCTAssertTrue(session.canReExport)

        SessionStorage.purgeSources(session, in: context)

        XCTAssertFalse(FileManager.default.fileExists(atPath: clipsDir.path), "clip files gone")
        XCTAssertTrue(FileManager.default.fileExists(atPath: exportsDir.path), "exports untouched")
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Clip>()), 2, "clip rows kept")

        let studyAfter = session.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration }
        XCTAssertEqual(studyAfter, 100, "study-time total survives the purge")

        XCTAssertNotNil(session.sourcesPurgedAt)
        XCTAssertFalse(session.canReExport)

        let profile = ExportProfile(session: session)
        session.exportProfile = profile
        context.insert(profile)
        try context.save()
        XCTAssertThrowsError(try ExportCoordinator.buildPlan(session: session, profile: profile)) { error in
            XCTAssertEqual(error as? ExportError, .sourcesPurged)
        }
    }
}
