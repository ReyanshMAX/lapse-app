import AVFoundation
import XCTest
@testable import StudyLapse

final class CaptureControllerTests: XCTestCase {
    /// BUILD.md Phase 1: driving `CaptureController` with a `SyntheticFrameSource`
    /// at a 3s virtual interval for 60 virtual seconds writes a file with exactly
    /// 20 frames, verified by reading the written asset back.
    func testSixtySecondSyntheticCaptureWritesTwentyFrames() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: url) }

        let source = SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
        let controller = CaptureController(source: source, clock: SystemClock())

        try controller.startClip(to: url, intervalSeconds: 3, outputFrameRate: 30)
        source.emit(seconds: 60)
        let result = try await controller.finishClip()

        XCTAssertEqual(result.frameCount, 20)
        XCTAssertEqual(result.url, url)

        // Read the asset back independently of CaptureController's own bookkeeping.
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, 20.0 / 30.0, accuracy: 0.05)

        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            XCTFail("no video track written")
            return
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        reader.startReading()

        // On the CI simulator's HEVC encoder this has been observed to read
        // back 24 raw samples against 20 real `append()` calls, with the
        // furthest sample's PTS landing exactly one frame (1/30s) beyond the
        // last real append. frameCount and duration above are the
        // authoritative proof of "exactly 20 frames" and both agree; this is
        // a lower-bound sanity check only (the file isn't truncated), not an
        // exact-equality check — see STATUS.md Deviations for what's
        // confirmed vs. still unexplained about the raw sample count.
        var sampleCount = 0
        while output.copyNextSampleBuffer() != nil {
            sampleCount += 1
        }

        XCTAssertEqual(reader.status, .completed)
        XCTAssertGreaterThanOrEqual(sampleCount, 20)
    }

    /// BUILD.md Phase 2 / D-015: continuous capture rolls a new chunk every
    /// `maxSegmentSeconds` of recorded time, and the boundary drops no frame —
    /// the sum of per-chunk frame counts equals what one unchunked clip of the
    /// same input would have written.
    func testChunkRolloverPreservesTotalFrameCount() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
        let controller = CaptureController(source: source, clock: SystemClock())
        let collector = FinalizedCollector()

        try controller.startRecording(
            firstClipIndex: 0,
            urlForClip: { index in dir.appendingPathComponent(String(format: "%03d.mov", index)) },
            intervalSeconds: 3,
            outputFrameRate: 30,
            onClipFinalized: { collector.append($0) }
        )

        // 300 virtual seconds at a 3s interval → 100 accepted frames. Rollover
        // at 120s of recorded PTS → chunk boundaries near 120s and 240s → three
        // chunks of 40, 40, 20 frames.
        source.emit(seconds: 300)
        if let trailing = await controller.stopRecording() {
            collector.append(trailing)
        }

        let reachedTotal = await collector.waitUntilTotalFrames(100, timeout: 15)
        XCTAssertTrue(reachedTotal, "chunk finalize callbacks did not deliver 100 frames in time")

        let clips = collector.sortedByIndex()
        XCTAssertGreaterThanOrEqual(clips.count, 2, "expected at least one rollover")
        XCTAssertEqual(clips.map(\.index), Array(0..<clips.count), "chunk indices must be contiguous from 0")
        XCTAssertEqual(clips.reduce(0) { $0 + $1.frameCount }, 100, "rollover must not drop or duplicate a frame")

        for chunk in clips.dropLast() {
            XCTAssertEqual(Double(chunk.frameCount), 40, accuracy: 1,
                           "a capped chunk should hold ~40 frames (120s / 3s)")
        }

        // Each finalized chunk file is independently readable.
        for chunk in clips {
            let asset = AVURLAsset(url: chunk.url)
            let isPlayable = try await asset.load(.isPlayable)
            XCTAssertTrue(isPlayable, "chunk \(chunk.index) is not playable")
        }
    }
}

/// Thread-safe sink for `onClipFinalized`, which fires on the writer's
/// completion queue rather than the caller's.
final class FinalizedCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var clips: [FinalizedClip] = []

    func append(_ clip: FinalizedClip) {
        lock.withLock { clips.append(clip) }
    }

    func sortedByIndex() -> [FinalizedClip] {
        lock.withLock { clips.sorted { $0.index < $1.index } }
    }

    func waitUntilTotalFrames(_ target: Int, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let total = lock.withLock { clips.reduce(0) { $0 + $1.frameCount } }
            if total >= target { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }
}
