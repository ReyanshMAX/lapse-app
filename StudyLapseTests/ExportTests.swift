import AVFoundation
import QuartzCore
import SwiftData
import XCTest
@testable import StudyLapse
@testable import StudyLapseCore

/// BUILD.md Phase 3. `AVAssetExportSession` + `AVVideoCompositionCoreAnimationTool`
/// crash the iOS Simulator ("Lost connection to IOSurface Remote Server"), so CI
/// verifies the assembled composition graph and the overlay layer tree — the
/// `[device]`/`[eyes-on]` criteria (the rendered file itself, legibility, Photos
/// playback) are confirmed by the developer sideloading the build.
///
/// Fixtures use `interval 0.1 / fps 30` → a 3x minimum-speed floor, so a 3x
/// export is exact.
@MainActor
final class ExportTests: XCTestCase {
    private var container: ModelContainer!
    private var sessionDirs: [URL] = []
    private var scratchURLs: [URL] = []

    override func setUpWithError() throws {
        container = try ModelContainerFactory.makeInMemory()
        sessionDirs = []
        scratchURLs = []
    }

    override func tearDown() {
        for dir in sessionDirs { try? FileManager.default.removeItem(at: dir) }
        for url in scratchURLs { try? FileManager.default.removeItem(at: url) }
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

    /// A detached `ExportProfile` — `ExportCoordinator.buildPlan` takes the
    /// profile explicitly and only reads it, so it needn't be inserted.
    /// Default multiplier 6 is above the fixtures' 3× floor (interval 0.1 / fps
    /// 30), so the composition is actually speed-scaled.
    private func profile(_ session: Session,
                         speedModeRaw: String = "multiplier",
                         speedMultiplier: Double = 6,
                         targetDurationSeconds: Double = 30,
                         aspectRaw: String = "portrait9x16",
                         overlayCornerRaw: String = "topRight") -> ExportProfile {
        ExportProfile(session: nil,
                      speedModeRaw: speedModeRaw,
                      speedMultiplier: speedMultiplier,
                      targetDurationSeconds: targetDurationSeconds,
                      aspectRaw: aspectRaw,
                      overlayCornerRaw: overlayCornerRaw)
    }

    private func prepare(_ session: Session, _ profile: ExportProfile)
        async throws -> AVFoundationSessionExporter.Prepared {
        let plan = try ExportCoordinator.buildPlan(session: session, profile: profile)
        let prepared = try await AVFoundationSessionExporter().prepare(plan)
        if let url = prepared.silentAudioURL { scratchURLs.append(url) }
        return prepared
    }

    /// A real short audio file on disk plus its snapshot, for voiceover-mix
    /// tests. LPCM `.caf` (via `SilentAudio`) is readable by `AVURLAsset`.
    private func takeSnapshot(start: Double, duration: Double,
                              createdAt: Date = .now) throws -> VoiceoverTakeSnapshot {
        let url = try SilentAudio.makeFile(duration: duration)
        scratchURLs.append(url)
        return VoiceoverTakeSnapshot(id: UUID(), url: url, outputStartSeconds: start,
                                     durationSeconds: duration, createdAt: createdAt)
    }

    /// Where each audio track's real content begins on the composition
    /// timeline. `track.timeRange.start` is always 0 once an insert `at:` a
    /// non-zero time prepends an empty segment — the placement lives in the
    /// non-empty `AVCompositionTrackSegment`'s target mapping.
    private func audioContentStarts(_ prepared: AVFoundationSessionExporter.Prepared) -> [Double] {
        prepared.composition.tracks
            .filter { $0.mediaType == .audio }
            .compactMap { track in
                track.segments.first { !$0.isEmpty }?.timeMapping.target.start.seconds
            }
            .sorted()
    }

    private func textStrings(in layer: CALayer) -> [String] {
        var out: [String] = []
        if let t = layer as? CATextLayer, let s = t.string as? String { out.append(s) }
        for sub in layer.sublayers ?? [] { out += textStrings(in: sub) }
        return out
    }

    // MARK: Criteria 1 / 2 / 3 / 6 — the composition graph

    func testCompositionMatchesComputedDurationWithOneFullLengthAudioTrack() async throws {
        // 3 clips × ~60 frames → study ~18s; native ~6s; net 6× → ~3s output.
        let session = try await makeSession(clipCount: 3, framesPerClip: 60)
        let exportProfile = profile(session)
        let prepared = try await prepare(session, exportProfile)

        let expected = ExportCoordinator.estimatedOutputDuration(session: session, profile: exportProfile)
        XCTAssertEqual(prepared.outputDuration, expected, accuracy: 1e-6)
        XCTAssertEqual(prepared.composition.duration.seconds, expected, accuracy: 0.05,
                       "the composition is scaled to exactly the duration the UI reports")

        let videoTracks = prepared.composition.tracks.filter { $0.mediaType == .video }
        XCTAssertEqual(videoTracks.count, 1)

        let audioTracks = prepared.composition.tracks.filter { $0.mediaType == .audio }
        XCTAssertEqual(audioTracks.count, 1, "export always carries one silent audio track (D-014)")
        XCTAssertEqual(audioTracks.first?.timeRange.duration.seconds ?? 0,
                       prepared.composition.duration.seconds, accuracy: 0.1,
                       "the audio track spans the whole output")
    }

    func testFitToDurationClampsAndTheReportedDurationIsTheComposedDuration() async throws {
        // ~225 frames → study ~22.5s. fit-to-15s → net speed 22.5/15 = 1.5×,
        // below the 3× floor → clamps to 3×; real output ≈ 22.5 / 3 = 7.5s.
        let session = try await makeSession(clipCount: 3, framesPerClip: 75)
        let exportProfile = profile(session, speedModeRaw: "fitToDuration", targetDurationSeconds: 15)

        XCTAssertTrue(ExportCoordinator.isClampedToFloor(session: session, profile: exportProfile))
        let reported = ExportCoordinator.estimatedOutputDuration(session: session, profile: exportProfile)
        XCTAssertGreaterThan(abs(reported - 15), 1, "clamped output must not be near the 15s request")

        let prepared = try await prepare(session, exportProfile)
        XCTAssertEqual(prepared.composition.duration.seconds, reported, accuracy: 0.05)
    }

    func testAspectPresetsSetTheirDeclaredRenderSize() async throws {
        let cases: [(String, CGSize)] = [
            ("portrait9x16", CGSize(width: 1080, height: 1920)),
            ("square1x1", CGSize(width: 1080, height: 1080)),
            ("original", CGSize(width: 1920, height: 1080)),
        ]
        let session = try await makeSession(clipCount: 1, framesPerClip: 60)
        for (raw, size) in cases {
            let exportProfile = profile(session, aspectRaw: raw)
            let prepared = try await prepare(session, exportProfile)
            XCTAssertEqual(prepared.videoComposition.renderSize, size, "preset \(raw)")
        }
    }

    func testCentreCropTransformFillsWithoutStretching() {
        let source = CGSize(width: 1920, height: 1080)

        let portrait = AVFoundationSessionExporter.cropTransform(
            naturalSize: source, preferredTransform: .identity,
            renderSize: CGSize(width: 1080, height: 1920))
        // Uniform scale (a == d) → no stretch; fills height; centred horizontally.
        XCTAssertEqual(portrait.a, portrait.d, accuracy: 1e-6)
        XCTAssertEqual(portrait.a, 1920.0 / 1080.0, accuracy: 1e-6)
        XCTAssertLessThan(portrait.tx, 0)               // cropped in from the sides
        XCTAssertEqual(portrait.ty, 0, accuracy: 1e-6)

        let original = AVFoundationSessionExporter.cropTransform(
            naturalSize: source, preferredTransform: .identity,
            renderSize: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(original.a, 1, accuracy: 1e-6)
        XCTAssertEqual(original.tx, 0, accuracy: 1e-6)
        XCTAssertEqual(original.ty, 0, accuracy: 1e-6)
    }

    // MARK: Criterion 5 — the overlay layer tree

    func testOverlayTreeHasAKeyframeStackThatChangesOverTime() async throws {
        let session = try await makeSession(clipCount: 2, framesPerClip: 60)
        let exportProfile = profile(session)
        let prepared = try await prepare(session, exportProfile)

        // videoLayer is a sublayer of parent, sized to the render bounds.
        XCTAssertTrue(prepared.overlay.parent.sublayers?.contains { $0 === prepared.overlay.video } ?? false)
        XCTAssertEqual(prepared.overlay.video.frame.size, prepared.videoComposition.renderSize)
        XCTAssertTrue(prepared.overlay.parent.isGeometryFlipped)

        let strings = textStrings(in: prepared.overlay.parent)
        XCTAssertTrue(strings.contains("0:00"), "timer starts at zero")
        XCTAssertGreaterThan(Set(strings).count, 1, "the timer shows more than one value over the video")
        let totalStudy = session.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration }
        let totalText = Formatters.studyTime(totalStudy)
        XCTAssertTrue(strings.contains(totalText), "the timer ends on the session total \(totalText)")
    }

    func testOverlayCornerPlacesTheTimerBox() async throws {
        let session = try await makeSession(clipCount: 1, framesPerClip: 60)

        let topRight = try await prepare(session, profile(session, overlayCornerRaw: "topRight"))
        let bottomLeft = try await prepare(session, profile(session, overlayCornerRaw: "bottomLeft"))

        // The timer container is the parent sublayer that isn't the video layer
        // and carries text sublayers.
        func timerBox(_ p: AVFoundationSessionExporter.Prepared) -> CALayer? {
            p.overlay.parent.sublayers?.first {
                $0 !== p.overlay.video && !textStrings(in: $0).isEmpty
            }
        }
        let tr = try XCTUnwrap(timerBox(topRight))
        let bl = try XCTUnwrap(timerBox(bottomLeft))

        XCTAssertLessThan(tr.frame.minY, 200, "top-right box sits near the top")
        XCTAssertGreaterThan(bl.frame.minY, 1920 - 400, "bottom-left box sits near the bottom")
        XCTAssertLessThan(bl.frame.minX, 200, "bottom-left box sits near the left")
    }

    // MARK: Criterion 4 — zero finalized clips fails with a typed error

    func testExportOfSessionWithNoFinalizedClipsThrowsTypedError() async throws {
        let session = Session(startedAt: Date(), dayKey: "2026-08-24",
                              captureIntervalSeconds: 3, outputFrameRate: 30)
        session.status = .ended
        context.insert(session)
        let exportProfile = profile(session)
        try context.save()

        XCTAssertThrowsError(try ExportCoordinator.buildPlan(session: session, profile: exportProfile)) {
            XCTAssertEqual($0 as? ExportError, .noFinalizedClips)
        }

        let emptyPlan = ExportPlan(
            sessionID: session.id, sessionStartedAt: session.startedAt, dayKey: session.dayKey,
            clips: [], captureIntervalSeconds: 3, outputFrameRate: 30, totalStudySeconds: 0,
            speedMode: .multiplier(100), aspect: .portrait9x16, overlayStyle: .minimal,
            overlayCorner: .topRight, includeIntroCard: false, includeOutroCard: false,
            profileRevision: 0, tagNames: [])
        do {
            _ = try await AVFoundationSessionExporter().export(ExportRequest(plan: emptyPlan),
                                                              progress: { _ in })
            XCTFail("expected ExportError.noFinalizedClips")
        } catch let error as ExportError {
            XCTAssertEqual(error, .noFinalizedClips)
        }
    }

    // MARK: EXPORT.md — unfinalized clips are skipped, not fatal

    func testUnfinalizedClipsAreSkipped() async throws {
        let session = try await makeSession(clipCount: 3, framesPerClip: 60, finalizeLast: false)
        XCTAssertEqual(session.orderedFinalizedClips.count, 2)

        let plan = try ExportCoordinator.buildPlan(session: session, profile: profile(session))
        XCTAssertEqual(plan.clips.count, 2)

        let prepared = try await AVFoundationSessionExporter().prepare(plan)
        if let url = prepared.silentAudioURL { scratchURLs.append(url) }
        XCTAssertEqual(prepared.composition.tracks.filter { $0.mediaType == .video }.count, 1)
    }

    // MARK: Coordinator builds a plan and reports errors without crashing

    func testCoordinatorSurfacesRenderOutcome() async throws {
        // The render itself can't run on the simulator; this checks the
        // coordinator wiring — a plan is built and no exception escapes.
        let session = try await makeSession(clipCount: 2, framesPerClip: 60)
        let plan = try ExportCoordinator.buildPlan(session: session, profile: profile(session))
        XCTAssertEqual(plan.clips.count, 2)
        XCTAssertGreaterThan(plan.totalStudySeconds, 0)
        XCTAssertEqual(plan.aspect, .portrait9x16)
    }

    // MARK: Phase 6 — voiceover mix (criteria 1 / 2 logic)

    func testVoiceoverTakesBecomeCompositionTracksAtTheirOutputPositions() async throws {
        let session = try await makeSession(clipCount: 3, framesPerClip: 60)
        let plan = try ExportCoordinator.buildPlan(session: session, profile: profile(session))
        let takes = [try takeSnapshot(start: 0.5, duration: 1.0),
                     try takeSnapshot(start: 2.0, duration: 0.8)]

        let prepared = try await AVFoundationSessionExporter().prepare(plan, voiceoverTakes: takes)
        if let url = prepared.silentAudioURL { scratchURLs.append(url) }

        let audioTracks = prepared.composition.tracks.filter { $0.mediaType == .audio }
        XCTAssertEqual(audioTracks.count, 3, "one silent track (D-014) + one per take")

        // The take tracks' content starts at exactly their output position
        // (±1 frame); the silent track's content starts at 0.
        let starts = audioContentStarts(prepared)
        XCTAssertEqual(starts.count, 3)
        XCTAssertEqual(starts[0], 0.0, accuracy: 1.0 / 30)
        XCTAssertEqual(starts[1], 0.5, accuracy: 1.0 / 30)
        XCTAssertEqual(starts[2], 2.0, accuracy: 1.0 / 30)

        // The mix parameters are keyed to the COMPOSITION take tracks, never the
        // source asset tracks — otherwise the fades are a silent no-op.
        let mix = try XCTUnwrap(prepared.audioMix)
        XCTAssertEqual(mix.inputParameters.count, 2)
        let silent = try XCTUnwrap(audioTracks.first {
            $0.timeRange.duration.seconds >= prepared.composition.duration.seconds - 0.1
        })
        let takeTrackIDs = Set(audioTracks.map(\.trackID)).subtracting([silent.trackID])
        XCTAssertEqual(Set(mix.inputParameters.map(\.trackID)), takeTrackIDs)
    }

    func testOverlappingVoiceoverTakesAreResolvedKeepingTheNewer() async throws {
        let session = try await makeSession(clipCount: 3, framesPerClip: 60)
        let plan = try ExportCoordinator.buildPlan(session: session, profile: profile(session))
        let older = try takeSnapshot(start: 0.5, duration: 1.5,
                                     createdAt: Date(timeIntervalSince1970: 100))   // [0.5, 2.0)
        let newer = try takeSnapshot(start: 1.5, duration: 1.0,
                                     createdAt: Date(timeIntervalSince1970: 200))   // [1.5, 2.5)

        let prepared = try await AVFoundationSessionExporter().prepare(plan, voiceoverTakes: [older, newer])
        if let url = prepared.silentAudioURL { scratchURLs.append(url) }

        let audioTracks = prepared.composition.tracks.filter { $0.mediaType == .audio }
        XCTAssertEqual(audioTracks.count, 2, "silent + one surviving take")
        XCTAssertEqual(prepared.audioMix?.inputParameters.count, 1)
        let starts = audioContentStarts(prepared)
        XCTAssertEqual(starts.last!, 1.5, accuracy: 1.0 / 30, "the newer take survived")
    }

    func testNoVoiceoverTakesLeavesTheSingleSilentTrackAndNoMix() async throws {
        let session = try await makeSession(clipCount: 2, framesPerClip: 60)
        let plan = try ExportCoordinator.buildPlan(session: session, profile: profile(session))
        let prepared = try await AVFoundationSessionExporter().prepare(plan)
        if let url = prepared.silentAudioURL { scratchURLs.append(url) }

        XCTAssertEqual(prepared.composition.tracks.filter { $0.mediaType == .audio }.count, 1)
        XCTAssertNil(prepared.audioMix)
    }

    #if !targetEnvironment(simulator)
    /// Full render — only runs on a physical device (the simulator's
    /// CoreAnimationTool path crashes the process). Checks the rendered file
    /// itself: duration, audio track, and that the timer overlay actually
    /// burned in (the timer corner changes between the first and last frame,
    /// while an empty corner stays static).
    func testFullRenderOnDevice() async throws {
        let session = try await makeSession(clipCount: 2, framesPerClip: 60)
        let exportProfile = profile(session)   // topRight corner, 9:16
        let plan = try ExportCoordinator.buildPlan(session: session, profile: exportProfile)
        let url = try await AVFoundationSessionExporter().export(ExportRequest(plan: plan),
                                                                progress: { _ in })
        defer { try? FileManager.default.removeItem(at: url) }

        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds,
                       ExportCoordinator.estimatedOutputDuration(session: session, profile: exportProfile),
                       accuracy: 0.1)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audio.count, 1)
        let videoSize = try await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        XCTAssertEqual(videoSize, CGSize(width: 1080, height: 1920))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let first = try await generator.image(at: .zero).image
        let last = try await generator.image(
            at: CMTimeSubtract(duration, CMTime(value: 1, timescale: 30))).image

        let timerCorner = CGRect(x: 1080 - 460, y: 0, width: 460, height: 280)
        XCTAssertGreaterThan(PixelAssertions.fractionDiffering(first, last, in: timerCorner), 0.005,
                             "the burned-in timer did not change between t=0 and t=end")
        let emptyCorner = CGRect(x: 0, y: 1920 - 280, width: 460, height: 280)
        XCTAssertLessThan(PixelAssertions.fractionDiffering(first, last, in: emptyCorner), 0.02,
                          "a corner with no overlay changed unexpectedly")
    }
    #endif
}
