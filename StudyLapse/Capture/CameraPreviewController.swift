import AVFoundation

/// A standalone `AVCaptureSession` used only to drive the idle/paused-screen
/// live preview (docs/UI.md screen 1's camera preview + framing guide, and
/// screen 3's "dimmed preview"). Deliberately separate from
/// `CaptureController`/`CameraFrameSource`: recording itself never shows a
/// preview (docs/UI.md screen 2, Q-005 — unchanged by this), so keeping the
/// two sessions isolated means nothing here can affect the tested capture
/// pipeline, and vice versa.
///
/// `start`/`stop` suspend until their work completes on their own serial
/// queue, exactly like `CameraFrameSource.start`/`stop` — callers that need
/// the device released before starting the *real* capture session
/// (`RecordView.beginRecording`) can `await stop()` first and be sure the
/// hardware is free. Never blocks the calling thread: `AVCaptureSession
/// .startRunning()`/`stopRunning()` are blocking hardware calls that can take
/// a real, variable amount of time, and blocking the main thread with them
/// (as a plain `DispatchQueue.sync` from a `@MainActor` caller would) risks
/// an iOS watchdog termination — which reads to the user as the app randomly
/// closing, not just a stutter.
final class CameraPreviewController {
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "studylapse.preview.session")
    private var configuredPosition: AVCaptureDevice.Position?
    private var notificationObservers: [NSObjectProtocol] = []

    /// Runtime-error/interruption logging plus an auto-restart on interruption
    /// end — this session shares physical camera hardware with the real
    /// capture session every pause/resume cycle, and AVFoundation's handoff
    /// between two different `AVCaptureSession` instances on the same device
    /// is the likeliest source of "preview just doesn't come back" — these
    /// notifications are how to tell whether that's actually happening
    /// (check the in-app Debug Log) rather than guess blind.
    init() {
        let center = NotificationCenter.default
        notificationObservers = [
            center.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { notification in
                let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
                DebugLog.write("Capture", "preview session runtime error: \(error?.localizedDescription ?? "unknown")")
            },
            center.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { notification in
                let reason = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int
                DebugLog.write("Capture", "preview session interrupted, reason \(reason.map(String.init) ?? "unknown")")
            },
            center.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
                DebugLog.write("Capture", "preview session interruption ended")
                self?.sessionQueue.async {
                    guard let self, !self.session.isRunning else { return }
                    self.session.startRunning()
                    DebugLog.write("Capture", "preview session restarted after interruption, isRunning=\(self.session.isRunning)")
                }
            }
        ]
    }

    deinit {
        let center = NotificationCenter.default
        for observer in notificationObservers { center.removeObserver(observer) }
    }

    func start(position: AVCaptureDevice.Position = .back) async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                configureIfNeeded(position: position)
                // Documented as a no-op if already running — call
                // unconditionally rather than gate on `isRunning`, which only
                // reflects whether *this* session was told to start, not
                // whether the hardware handoff from the other session (real
                // capture, on pause/resume) actually landed.
                session.startRunning()
                DebugLog.write("Capture", "preview session startRunning() called, isRunning=\(session.isRunning)")
                continuation.resume()
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in
            sessionQueue.async { [self] in
                if session.isRunning { session.stopRunning() }
                continuation.resume()
            }
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
        DebugLog.write("Capture", "preview session configured for position \(position.rawValue)")
    }
}
