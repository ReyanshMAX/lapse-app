import AVFoundation

/// A standalone `AVCaptureSession` used only to drive the idle/paused-screen
/// live preview (docs/UI.md screen 1's camera preview + framing guide, and
/// screen 3's "dimmed preview"). Deliberately separate from
/// `CaptureController`/`CameraFrameSource`: recording itself never shows a
/// preview (docs/UI.md screen 2, Q-005 — unchanged by this), so keeping the
/// two sessions isolated means nothing here can affect the tested capture
/// pipeline, and vice versa.
///
/// `start`/`stop` block on their own serial queue exactly like
/// `CameraFrameSource.start`/`stop` — callers that need the device released
/// before starting the *real* capture session (`RecordView.beginRecording`)
/// can call `stop()` synchronously first and be sure the hardware is free.
final class CameraPreviewController {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "studylapse.preview.session")
    private var configuredPosition: AVCaptureDevice.Position?

    func start(position: AVCaptureDevice.Position = .back) {
        sessionQueue.sync {
            configureIfNeeded(position: position)
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.sync {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    /// Runs only on `sessionQueue`.
    private func configureIfNeeded(position: AVCaptureDevice.Position) {
        guard configuredPosition != position else { return }

        session.beginConfiguration()
        for input in session.inputs { session.removeInput(input) }
        session.sessionPreset = .high

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            session.commitConfiguration()
            DebugLog.write("Capture", "preview session: no camera available at position \(position.rawValue)")
            return
        }
        session.addInput(input)
        session.commitConfiguration()
        configuredPosition = position
    }
}
