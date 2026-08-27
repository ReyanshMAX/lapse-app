import AVFoundation
import SwiftData
import XCTest
@testable import StudyLapse
@testable import StudyLapseCore

/// BUILD.md Phase 3. The composition path is CI-testable per docs/TESTING.md
/// ("Export verification without eyes"); the `[device]`/`[eyes-on]` criteria
/// themselves are confirmed by the developer sideloading the build.
///
/// All fixtures use `interval 0.1 / fps 30` → a 3x minimum-speed floor, so a
/// 3x export is exact and a modest number of synthetic frames still yields a
/// 1–3s render (the 90x default floor would collapse it to sub-frame length).
@MainActor
final class ExportTests: XCTestCase {
    private var container: ModelContainer!
    private var sessionDirs: [URL] = []

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        sessionDirs = []
    }

    override func tearDown() {
        for dir in sessionDirs { try? FileManager.default.removeItem(at: dir) }
        container = nil
    }

    private var context: ModelContext { container.mainContext }

    // MARK: Fixture

    private func makeSession(clipCount: Int,
                             framesPerClip: Int,
                             interval: Double = 0.1,
                             fps: Int32 = 30,
                             finalizeLast: Bool = true) async throws -> Session {
        let session = Session(startedAt: Date(timeIntervalSince1970: 1_756_000_000),
                              dayKey: "2026-08-24",
                              captureIntervalSeconds: interval,
                              outputFrameRate: fps)
        session.status = .ended
        session.endedAt = Date()
        context.insert(session)
        sessionDirs.append(StorageLocator.url(forRelativePath: "sessions/\(session.id.uuidString)"))

        for i in 0..<clipCount {
            let rel = "sessions/\(session.id.uuidString)/clips/\(String(format: "%03d", i)).mov"
            let url = StorageLocator.url(forRelativePath: rel)
            let actualFrames = try await writeClip(frameCount: framesPerClip,
                                                   interval: interval, fps: fps, to: url)
            let isFinal = finalizeLast || i < clipCount - 1
            let clip = Clip(session: session, index: i, relativePath: rel,
                            startedAt: Date(), endedAt: Date(),
                            frameCount: actualFrames, studyOffsetStart: 0,
                            isFinalized: isFinal)
            context.insert(clip)
        }
        StudyOffsets.recompute(for: session)
        try context.save()
        return session
    }

    @discardableResult
    private func writeClip(frameCount: Int, interval: Double, fps: Int32, to url: URL) async throws -> Int {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let source = SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
        let controller = CaptureController(source: source, clock: SystemClock())
        try controller.startClip(to: url, intervalSeconds: interval, outputFrameRate: fps)
        source.emit(seconds: Double(frameCount) * interval + interval)
        let result = try await controller.finishClip()
        return result.frameCount
    }

    private func profile(_ session: Session,
                         speedModeRaw: String = "multiplier",
                         speedMultiplier: Double = 3,
                         targetDurationSeconds: Double = 30,
                         aspectRaw: String = "portrait9x16",
                         overlayCornerRaw: String = "topRight") -> ExportProfile {
        let profile = ExportProfile(session: session,
                                    speedModeRaw: speedModeRaw,
                                    speedMultiplier: speedMultiplier,
                                    targetDurationSeconds: targetDurationSeconds,
                                    aspectRaw: aspectRaw,
                                    overlayCornerRaw: overlayCornerRaw)
        session.exportProfile = profile
        context.insert(profile)
        return profile
    }

    // MARK: Criteria 1 / 3 / 5 / 6 — a real render, inspected

    func testExportProducesFileMatchingComputedDurationWithAudioAndOverlay() async throws {
        // 3 clips × ~60 frames → ~180 frames, study ~18s, base ~6s, 3x → ~2s.
        let session = try await makeSession(clipCount: 3, framesPerClip: 60)
        let exportProfile = profile(session)

        let plan = try ExportCoordinator.buildPlan(session: session, profile: exportProfile)
        XCTAssertGreaterThan(plan.totalStudySeconds, 0)

        let exporter = AVFoundationSessionExporter()
        var progressValues: [Double] = []
        let url = try await exporter.export(ExportRequest(plan: plan),
                                            progress: { progressValues.append($0) })
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(progressValues.last, 1)

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)

        // Criterion 1 / 2b: file duration matches the computed output duration.
        let expected = ExportCoordinator.estimatedOutputDuration(session: session, profile: exportProfile)
        XCTAssertEqual(duration.seconds, expected, accuracy: 0.1)
        XCTAssertEqual(duration.seconds, plan.outputDuration, accuracy: 0.1)

        // Criterion 3: exactly one audio track, spanning the whole duration.
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        if let audio = audioTracks.first {
            let range = try await audio.load(.timeRange)
            XCTAssertEqual(range.duration.seconds, duration.seconds, accuracy: 0.2)
        }

        // Criterion 6 (partial): rendered at the 9:16 preset's size, not stretched.
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let naturalSize = try await videoTracks.first?.load(.naturalSize)
        XCTAssertEqual(naturalSize, CGSize(width: 1080, height: 1920))

        // Criterion 5: the timer overlay actually rendered — pixels in the
        // top-right corner differ between the first and last frame ("0:00" vs
        // the final total), while a corner with no overlay stays static.
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.appliesPreferredTrackTransform = true
        let first = try await generator.image(at: .zero).image
        let lastTime = CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))
        let last = try await generator.image(at: lastTime).image

        let timerCorner = CGRect(x: 1080 - 460, y: 0, width: 460, height: 280)
        let timerDiff = PixelAssertions.fractionDiffering(first, last, in: timerCorner)
        XCTAssertGreaterThan(timerDiff, 0.005, "timer overlay did not change between t=0 and t=end")

        let emptyCorner = CGRect(x: 0, y: 1920 - 280, width: 460, height: 280)
        let emptyDiff = PixelAssertions.fractionDiffering(first, last, in: emptyCorner)
        XCTAssertLessThan(emptyDiff, 0.02, "a corner with no overlay changed unexpectedly")
    }

    // MARK: Criterion 2 — fit-to-duration clamps, and the UI number is the truth

    func testFitToDurationClampsAndReportedDurationEqualsActual() async throws {
        // ~225 frames, study ~22.5s, base ~7.5s. fit-to-15s → raw speed 0.5,
        // well below the 3x floor → clamps; real output ≈ 7.5 / 3 = 2.5s.
        let session = try await makeSession(clipCount: 3, framesPerClip: 75)
        let exportProfile = profile(session, speedModeRaw: "fitToDuration", targetDurationSeconds: 15)

        XCTAssertTrue(ExportCoordinator.isClampedToFloor(session: session, profile: exportProfile),
                      "fit-to-15s on this session must clamp to the 3x floor")

        let reported = ExportCoordinator.estimatedOutputDuration(session: session, profile: exportProfile)
        XCTAssertGreaterThan(abs(reported - 15), 1, "clamped output must not be near the 15s request")

        let plan = try ExportCoordinator.buildPlan(session: session, profile: exportProfile)
        let exporter = AVFoundationSessionExporter()
        let url = try await exporter.export(ExportRequest(plan: plan), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        let duration = try await AVURLAsset(url: url).load(.duration)
        XCTAssertEqual(duration.seconds, reported, accuracy: 0.1,
                       "the UI-reported duration must equal the actual output duration")
    }

    // MARK: Criterion 4 — zero finalized clips fails with a typed error

    func testExportOfSessionWithNoFinalizedClipsThrowsTypedError() async throws {
        let session = Session(startedAt: Date(), dayKey: "2026-08-24",
                              captureIntervalSeconds: 3, outputFrameRate: 30)
        session.status = .ended
        context.insert(session)
        let exportProfile = profile(session)
        try context.save()

        XCTAssertThrowsError(try ExportCoordinator.buildPlan(session: session, profile: exportProfile)) { error in
            XCTAssertEqual(error as? ExportError, .noFinalizedClips)
        }

        let emptyPlan = ExportPlan(
            sessionID: session.id, sessionStartedAt: session.startedAt, dayKey: session.dayKey,
            clips: [], captureIntervalSeconds: 3, outputFrameRate: 30, totalStudySeconds: 0,
            speedMode: .multiplier(100), aspect: .portrait9x16, overlayStyle: .minimal,
            overlayCorner: .topRight, includeIntroCard: false, includeOutroCard: false,
            profileRevision: 0, tagNames: [])
        let exporter = AVFoundationSessionExporter()
        do {
            _ = try await exporter.export(ExportRequest(plan: emptyPlan), progress: { _ in })
            XCTFail("expected ExportError.noFinalizedClips")
        } catch let error as ExportError {
            XCTAssertEqual(error, .noFinalizedClips)
        }
    }

    // MARK: EXPORT.md — unfinalized clips are skipped, not fatal

    func testUnfinalizedClipsAreSkipped() async throws {
        let session = try await makeSession(clipCount: 3, framesPerClip: 60, finalizeLast: false)
        let exportProfile = profile(session)

        XCTAssertEqual(session.orderedFinalizedClips.count, 2)
        let plan = try ExportCoordinator.buildPlan(session: session, profile: exportProfile)
        XCTAssertEqual(plan.clips.count, 2)

        let exporter = AVFoundationSessionExporter()
        let url = try await exporter.export(ExportRequest(plan: plan), progress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: Aspect presets → render size (Criterion 6 support)

    func testAspectPresetsRenderAtTheirDeclaredSize() async throws {
        let cases: [(String, CGSize)] = [
            ("portrait9x16", CGSize(width: 1080, height: 1920)),
            ("square1x1", CGSize(width: 1080, height: 1080)),
            ("original", CGSize(width: 1920, height: 1080)),
        ]
        for (raw, size) in cases {
            let session = try await makeSession(clipCount: 1, framesPerClip: 90)
            let exportProfile = profile(session, aspectRaw: raw)
            let plan = try ExportCoordinator.buildPlan(session: session, profile: exportProfile)
            let exporter = AVFoundationSessionExporter()
            let url = try await exporter.export(ExportRequest(plan: plan), progress: { _ in })
            defer { try? FileManager.default.removeItem(at: url) }
            let track = try await AVURLAsset(url: url).loadTracks(withMediaType: .video).first
            let natural = try await track?.load(.naturalSize)
            XCTAssertEqual(natural, size, "preset \(raw) rendered at the wrong size")
        }
    }

    // MARK: Coordinator writes an ExportRecord

    func testCoordinatorWritesExportRecord() async throws {
        let session = try await makeSession(clipCount: 2, framesPerClip: 60)
        let exportProfile = profile(session)

        let coordinator = ExportCoordinator(context: context)
        await coordinator.export(session: session, profile: exportProfile)

        XCTAssertNil(coordinator.lastError)
        let url = try XCTUnwrap(coordinator.lastExportURL)
        defer { try? FileManager.default.removeItem(at: url) }

        let records = try context.fetch(FetchDescriptor<ExportRecord>())
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.profileRevision, exportProfile.revision)
        XCTAssertGreaterThan(records.first?.durationSeconds ?? 0, 0)
    }
}
