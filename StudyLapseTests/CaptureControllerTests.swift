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

        var sampleCount = 0
        while output.copyNextSampleBuffer() != nil {
            sampleCount += 1
        }

        XCTAssertEqual(reader.status, .completed)
        XCTAssertEqual(sampleCount, 20)
    }
}
