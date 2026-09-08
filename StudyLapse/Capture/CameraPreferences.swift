import AVFoundation
import Foundation

/// Persisted front/back camera choice (docs/UI.md screen 1's flip control,
/// deferred at Phase 7 — see STATUS.md Deviations for why, and for when this
/// filled the gap). Read by both the idle preview (`CameraPreviewController`,
/// via `RecordView`) and the real capture session (`CameraFrameSource`, via
/// `SessionCoordinator`'s default `makeFrameSource`) so flipping while
/// idle/paused also applies to the next recording.
enum CameraPreferences {
    static let positionKey = "cameraPositionRawValue"

    static var position: AVCaptureDevice.Position {
        get {
            let raw = UserDefaults.standard.object(forKey: positionKey) as? Int
            return raw.flatMap(AVCaptureDevice.Position.init(rawValue:)) ?? .back
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: positionKey) }
    }
}
