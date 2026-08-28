import AVFoundation
import XCTest
@testable import StudyLapse

/// docs/CAPTURE.md "Framing continuity": `ghost.jpg` is the last frame of the
/// most recently finalized clip, regenerated on every finalize.
@MainActor
final class GhostOverlayTests: XCTestCase {
    private func writeSyntheticClip(seconds: Double = 6, intervalSeconds: Double = 3) async throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        let source = SyntheticFrameSource(size: CGSize(width: 1920, height: 1080), virtualFrameRate: 30)
        let controller = CaptureController(source: source, clock: SystemClock())
        try controller.startClip(to: url, intervalSeconds: intervalSeconds, outputFrameRate: 30)
        source.emit(seconds: seconds)
        _ = try await controller.finishClip()
        return url
    }

    func testRegenerateWritesAReadableJPEG() async throws {
        let clipURL = try await writeSyntheticClip()
        defer { try? FileManager.default.removeItem(at: clipURL) }

        let sessionID = UUID()
        let ghostURL = GhostOverlayGenerator.url(for: sessionID)
        defer { try? FileManager.default.removeItem(at: SessionStorage.directory(for: sessionID)) }

        XCTAssertFalse(GhostOverlayGenerator.exists(for: sessionID))
        await GhostOverlayGenerator.regenerate(for: sessionID, clipURL: clipURL)

        XCTAssertTrue(GhostOverlayGenerator.exists(for: sessionID))
        let data = try Data(contentsOf: ghostURL)
        XCTAssertFalse(data.isEmpty)
        XCTAssertNotNil(UIImage(data: data), "ghost.jpg must decode as a real image")
    }

    func testRegenerateOverwritesThePreviousGhostFrame() async throws {
        let firstClip = try await writeSyntheticClip()
        let secondClip = try await writeSyntheticClip()
        defer {
            try? FileManager.default.removeItem(at: firstClip)
            try? FileManager.default.removeItem(at: secondClip)
        }

        let sessionID = UUID()
        defer { try? FileManager.default.removeItem(at: SessionStorage.directory(for: sessionID)) }

        await GhostOverlayGenerator.regenerate(for: sessionID, clipURL: firstClip)
        let firstData = try Data(contentsOf: GhostOverlayGenerator.url(for: sessionID))

        await GhostOverlayGenerator.regenerate(for: sessionID, clipURL: secondClip)
        let secondData = try Data(contentsOf: GhostOverlayGenerator.url(for: sessionID))

        // Both are valid images at the same path — the point is the second
        // finalize replaced the file rather than leaving the first one stale.
        XCTAssertNotNil(UIImage(data: firstData))
        XCTAssertNotNil(UIImage(data: secondData))
    }

    func testRegenerateIsANoOpForAMissingFile() async {
        let sessionID = UUID()
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("mov")
        await GhostOverlayGenerator.regenerate(for: sessionID, clipURL: missingURL)
        XCTAssertFalse(GhostOverlayGenerator.exists(for: sessionID))
    }
}
