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

    /// The bounding box of an already-upright `contentSize` rect, after
    /// `orientationAdjustment`, must stay anchored at the origin (min corner
    /// exactly (0,0)) — `cropTransform`'s crop/scale math assumes a plain
    /// 0…w, 0…h rect, so a rotation that left it in the wrong quadrant would
    /// silently corrupt the centre-crop for every rotated export.
    private func boundingBox(of transform: CGAffineTransform, size: CGSize) -> CGRect {
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: size.width, y: 0),
                       CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)]
            .map { $0.applying(transform) }
        let xs = corners.map(\.x), ys = corners.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!,
                     width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    func testOrientationAdjustmentStaysOriginAnchoredForEveryRotation() {
        let size = CGSize(width: 1080, height: 1920)
        for rotation in VideoRotation.allCases {
            for mirrored in [false, true] {
                let transform = AVFoundationSessionExporter.orientationAdjustment(
                    contentSize: size, rotation: rotation, isMirrored: mirrored)
                let box = boundingBox(of: transform, size: size)
                XCTAssertEqual(box.origin.x, 0, accuracy: 1e-6, "rotation \(rotation), mirrored \(mirrored)")
                XCTAssertEqual(box.origin.y, 0, accuracy: 1e-6, "rotation \(rotation), mirrored \(mirrored)")

                let quarterTurned = rotation == .quarter || rotation == .threeQuarter
                let expected = quarterTurned
                    ? CGSize(width: size.height, height: size.width) : size
                XCTAssertEqual(box.width, expected.width, accuracy: 1e-6, "rotation \(rotation)")
                XCTAssertEqual(box.height, expected.height, accuracy: 1e-6, "rotation \(rotation)")
            }
        }
    }

    func testQuarterTurnRotationSwapsRenderDimensionsInTheCropScale() {
        // A 1920x1080 source rotated 90° is already 1080x1920 before the
        // crop — exactly the render size below — so fitting it needs a
        // uniform scale of 1, unlike the un-rotated case, which needs the
        // same 1920/1080 portrait-crop scale `testCentreCropTransformFillsWithoutStretching`
        // asserts. A 90° turn's matrix has a == d == 0 (cos 90° == 0), so the
        // scale shows up as the row length (a, b) rather than as `a` alone.
        let source = CGSize(width: 1920, height: 1080)
        let renderSize = CGSize(width: 1080, height: 1920)

        let rotated = AVFoundationSessionExporter.cropTransform(
            naturalSize: source, preferredTransform: .identity, renderSize: renderSize,
            rotation: .quarter)
        let rotatedScale = (rotated.a * rotated.a + rotated.b * rotated.b).squareRoot()
        XCTAssertEqual(rotatedScale, 1.0, accuracy: 1e-6)

        let unrotated = AVFoundationSessionExporter.cropTransform(
            naturalSize: source, preferredTransform: .identity, renderSize: renderSize)
        let unrotatedScale = (unrotated.a * unrotated.a + unrotated.b * unrotated.b).squareRoot()
        XCTAssertEqual(unrotatedScale, 1920.0 / 1080.0, accuracy: 1e-6)
    }

    func testMirrorFlipsHorizontally() {
        let source = CGSize(width: 1920, height: 1080)
        let renderSize = CGSize(width: 1920, height: 1080)

        let plain = AVFoundationSessionExporter.cropTransform(
            naturalSize: source, preferredTransform: .identity, renderSize: renderSize)
        let mirrored = AVFoundationSessionExporter.cropTransform(
            naturalSize: source, preferredTransform: .identity, renderSize: renderSize,
            isMirrored: true)

        // A pure horizontal mirror negates the x-scale term (a) and leaves
        // the frame the same size and position otherwise.
        XCTAssertEqual(mirrored.a, -plain.a, accuracy: 1e-6)
        XCTAssertEqual(mirrored.d, plain.d, accuracy: 1e-6)
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

    /// Q-009 / STATUS.md Deviations: `TimerOverlay.timerKeyframes` always
    /// closes with `(outputDuration, finalTotal)`, so the final keyframe's
    /// own normalized start is exactly 1.0 — before the fix this collapsed
    /// its visible window to a fixed sliver under one video frame regardless
    /// of length, and let it briefly overlap the penultimate label (whose own
    /// window ran uncapped to 1.0 too).
    func testFinalTimerValueGetsAFairShareOfTheTailNotASliver() async throws {
        let session = try await makeSession(clipCount: 2, framesPerClip: 60)
        let prepared = try await prepare(session, profile(session))

        func timerBox(_ p: AVFoundationSessionExporter.Prepared) -> CALayer? {
            p.overlay.parent.sublayers?.first {
                $0 !== p.overlay.video && !textStrings(in: $0).isEmpty
            }
        }
        let box = try XCTUnwrap(timerBox(prepared))
        let textLayers = (box.sublayers ?? []).compactMap { $0 as? CATextLayer }
        XCTAssertGreaterThanOrEqual(textLayers.count, 3, "fixture should produce several keyframes")

        func visibleWindow(_ layer: CATextLayer) throws -> (start: Double, end: Double) {
            let anim = try XCTUnwrap(layer.animation(forKey: "opacity") as? CAKeyframeAnimation)
            let keyTimes = try XCTUnwrap(anim.keyTimes?.map(\.doubleValue))
            let values = try XCTUnwrap(anim.values as? [NSNumber]).map(\.doubleValue)
            let visibleIndex = try XCTUnwrap(values.firstIndex(of: 1))
            return (keyTimes[visibleIndex], keyTimes[visibleIndex + 1])
        }

        let penultimateWindow = try visibleWindow(textLayers[textLayers.count - 2])
        let lastWindow = try visibleWindow(textLayers[textLayers.count - 1])

        XCTAssertEqual(lastWindow.end, 1.0, accuracy: 1e-9,
                       "the final value must stay visible through the video's end")
        // Assert the algorithm's actual contract — the last keyframe gets
        // exactly half of whatever tail remains after the penultimate one's
        // own (unchanged) start — rather than a hand-picked absolute width,
        // which depends on this fixture's exact step/duration math.
        let remainingTail = 1.0 - penultimateWindow.start
        XCTAssertEqual(lastWindow.end - lastWindow.start, remainingTail / 2, accuracy: 1e-9,
                       "the final value's window should be exactly half of the remaining tail")
        XCTAssertGreaterThan(lastWindow.end - lastWindow.start, 1e-6,
                             "the final timer value must be visible for some real duration, not a sliver")
        XCTAssertEqual(penultimateWindow.end, lastWindow.start, accuracy: 1e-9,
                       "the last two labels must split the tail exactly, with no gap or overlap")
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
            speedMode: .multiplier(100), aspect: .portrait9x16, rotation: .none, isMirrored: false,
            overlayStyle: .minimal,
            overlayCorner: .topRight, includeIntroCard: false, includeOutroCard: false,
            tagNames: [])
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
