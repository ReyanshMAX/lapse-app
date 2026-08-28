import AVFoundation
import UIKit

/// docs/CAPTURE.md "Framing continuity": `ghost.jpg`, the last frame of the
/// most recently finalized clip, shown as a low-opacity overlay on resume so
/// the user can re-align the phone. Unlike `ThumbnailProvider` (clip 000,
/// generated once, lazily), this regenerates on **every** finalized clip —
/// `SessionCoordinator.persistFinalizedClip` calls `regenerate` right after
/// persisting — so it always reflects where the camera last left off, not
/// just the start of the session.
@MainActor
enum GhostOverlayGenerator {
    static func url(for sessionID: UUID) -> URL {
        SessionStorage.directory(for: sessionID).appendingPathComponent("ghost.jpg")
    }

    static func exists(for sessionID: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: sessionID).path)
    }

    /// Extracts the last readable frame of `clipURL` and writes it to
    /// `sessions/<sessionID>/ghost.jpg`, overwriting any previous ghost frame.
    /// Best-effort: a failure here must never interrupt capture, so every step
    /// just gives up quietly and logs.
    static func regenerate(for sessionID: UUID, clipURL: URL) async {
        guard FileManager.default.fileExists(atPath: clipURL.path) else { return }
        let asset = AVURLAsset(url: clipURL)
        guard let duration = try? await asset.load(.duration), duration.seconds > 0 else {
            DebugLog.write("Capture", "ghost.jpg: unreadable duration for \(clipURL.lastPathComponent)")
            return
        }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)

        // A hair before the exact end — some assets fail to decode the final
        // instant, and a whole frame of slack is imperceptible for a ghost.
        let target = CMTime(seconds: max(duration.seconds - 0.05, 0), preferredTimescale: 600)
        guard let cgImage = try? await generator.image(at: target).image else {
            DebugLog.write("Capture", "ghost.jpg: frame extraction failed for \(clipURL.lastPathComponent)")
            return
        }
        guard let jpeg = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.7) else { return }

        let directory = SessionStorage.directory(for: sessionID)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try jpeg.write(to: url(for: sessionID))
            DebugLog.write("Capture", "ghost.jpg regenerated from \(clipURL.lastPathComponent)")
        } catch {
            DebugLog.write("Capture", "ghost.jpg write failed: \(error)")
        }
    }
}
