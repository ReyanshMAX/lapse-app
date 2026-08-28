import AVFoundation
import CoreMedia
import CoreVideo

/// The only type that touches `AVCaptureSession`. Untestable in CI by design —
/// keep it thin and free of logic (D-026, docs/TESTING.md).
protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    func start() throws
    func stop()
}

enum FrameSourceError: Error {
    case cameraUnavailable
    case configurationFailed
}

/// Real device camera. Locks exposure/white balance after a warm-up so a long
/// session doesn't strobe (docs/CAPTURE.md).
final class CameraFrameSource: NSObject, FrameSource {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let position: AVCaptureDevice.Position
    /// Not private: `SessionCoordinator.activePreviewSession` binds a
    /// `CameraPreviewView` to this same session while recording (D-028) — a
    /// second `AVCaptureSession` can't also hold the device.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "studylapse.capture.session")
    private let bufferQueue = DispatchQueue(label: "studylapse.capture.buffer")
    private var device: AVCaptureDevice?

    init(position: AVCaptureDevice.Position = .back) {
        self.position = position
        super.init()
    }

    func start() throws {
        var configError: Error?
        sessionQueue.sync {
            do {
                try configureIfNeeded()
                session.startRunning()
                DebugLog.write("Capture", "session configured and started")
                lockExposureAfterWarmup()
            } catch {
                configError = error
            }
        }
        if let configError { throw configError }
    }

    func stop() {
        sessionQueue.sync {
            session.stopRunning()
        }
        DebugLog.write("Capture", "session stopped")
    }

    private func configureIfNeeded() throws {
        guard session.inputs.isEmpty else { return }
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw FrameSourceError.cameraUnavailable
        }
        self.device = device

        session.beginConfiguration()
        session.sessionPreset = .hd1920x1080

        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            session.commitConfiguration()
            throw FrameSourceError.configurationFailed
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.setSampleBufferDelegate(self, queue: bufferQueue)
        guard session.canAddOutput(videoOutput) else {
            session.commitConfiguration()
            throw FrameSourceError.configurationFailed
        }
        session.addOutput(videoOutput)

        session.commitConfiguration()
    }

    private func lockExposureAfterWarmup() {
        guard let device else { return }
        sessionQueue.asyncAfter(deadline: .now() + 1.0) {
            do {
                try device.lockForConfiguration()
                if device.isExposureModeSupported(.locked) {
                    device.exposureMode = .locked
                }
                if device.isWhiteBalanceModeSupported(.locked) {
                    device.whiteBalanceMode = .locked
                }
                device.unlockForConfiguration()
                DebugLog.write("Capture", "exposure and white balance locked")
            } catch {
                DebugLog.write("Capture", "failed to lock exposure/white balance: \(error)")
            }
        }
    }
}

extension CameraFrameSource: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        onFrame?(pixelBuffer, pts)
    }
}

/// CI-only stand-in for the camera. Emits generated `CVPixelBuffer`s at a
/// caller-specified virtual rate so gating/chunking/writing logic is fully
/// testable without a device (docs/TESTING.md).
final class SyntheticFrameSource: FrameSource {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?

    private let size: CGSize
    private let virtualFrameRate: Double
    private var pixelBufferPool: CVPixelBufferPool?
    private var isRunning = false
    /// Monotonic across every `emit` call so PTS never goes backwards — a
    /// second `emit` (e.g. a session resume) continues the timeline rather
    /// than restarting it at zero, which would break interval gating and
    /// chunk-rollover math downstream.
    private var tickCursor: Int64 = 0

    init(size: CGSize = CGSize(width: 1920, height: 1080), virtualFrameRate: Double = 30) {
        self.size = size
        self.virtualFrameRate = virtualFrameRate
    }

    func start() throws {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as CFDictionary
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &pool)
        pixelBufferPool = pool
        isRunning = true
    }

    func stop() {
        isRunning = false
    }

    /// Advances the virtual clock by `seconds` and synchronously emits one
    /// frame per virtual tick at `virtualFrameRate`. PTS continues from wherever
    /// the previous `emit` left off.
    func emit(seconds: Double) {
        guard let pixelBufferPool else { return }
        let totalTicks = Int(seconds * virtualFrameRate)
        for _ in 0..<totalTicks {
            guard isRunning else { break }
            var pixelBuffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pixelBufferPool, &pixelBuffer)
            guard let buffer = pixelBuffer else { continue }
            let pts = CMTime(value: tickCursor, timescale: Int32(virtualFrameRate))
            tickCursor += 1
            onFrame?(buffer, pts)
        }
    }
}
