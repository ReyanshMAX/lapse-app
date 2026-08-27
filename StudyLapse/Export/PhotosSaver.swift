import Photos

/// Saves an exported video to the user's photo library, add-only. Requires
/// `NSPhotoLibraryAddUsageDescription` (set in project.yml) and
/// `.addOnly` authorization (docs/EXPORT.md).
enum PhotosSaver {
    enum SaveError: LocalizedError {
        case notAuthorized
        case failed(String)

        var errorDescription: String? {
            switch self {
            case .notAuthorized: return "Photos access wasn't granted."
            case .failed(let detail): return "Couldn't save to Photos: \(detail)"
            }
        }
    }

    static func save(_ url: URL) async throws {
        let status = await withCheckedContinuation { (continuation: CheckedContinuation<PHAuthorizationStatus, Never>) in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
        guard status == .authorized || status == .limited else {
            throw SaveError.notAuthorized
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                PHAssetCreationRequest.creationRequestForAssetFromVideo(atFileURL: url)
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: SaveError.failed(error?.localizedDescription ?? "unknown"))
                }
            }
        }
    }
}
