import AVFoundation
import UIKit

/// Library-grid thumbnails (docs/UI.md §7). Reads `sessions/<id>/thumbnail.jpg`
/// if present; otherwise generates one lazily from the first frame of clip 000,
/// caches it in memory, and writes it back to disk so every later launch is a
/// plain file read.
///
/// Lazy generation is deliberate: sessions recorded before Phase 5 have no
/// `thumbnail.jpg` (STATUS.md deferred it), and purged sessions (D-005) whose
/// thumbnail was already written keep showing it.
@MainActor
enum ThumbnailProvider {
    private static var cache: [UUID: UIImage] = [:]

    static func thumbnail(for session: Session) async -> UIImage? {
        if let hit = cache[session.id] { return hit }

        let directory = SessionStorage.directory(for: session.id)
        let thumbnailURL = directory.appendingPathComponent("thumbnail.jpg")
        if let data = try? Data(contentsOf: thumbnailURL), let image = UIImage(data: data) {
            cache[session.id] = image
            return image
        }

        guard let firstClip = session.orderedFinalizedClips.first else { return nil }
        let clipURL = StorageLocator.url(forRelativePath: firstClip.relativePath)
        guard FileManager.default.fileExists(atPath: clipURL.path) else { return nil }

        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: clipURL))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 640, height: 640)
        guard let cgImage = try? await generator.image(at: .zero).image else { return nil }

        let image = UIImage(cgImage: cgImage)
        cache[session.id] = image
        if let jpeg = image.jpegData(compressionQuality: 0.7) {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? jpeg.write(to: thumbnailURL)
        }
        return image
    }
}
