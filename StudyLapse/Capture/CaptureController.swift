import AVFoundation
import CoreMedia
import CoreVideo

enum CaptureControllerError: Error {
    case noActiveClip
    case writerFinishFailed(String)
}

/// Consumes a `FrameSource` — never owns `AVCaptureSession` directly (D-026).
/// Gates incoming frames to `intervalSeconds` apart, synthesizes sequential
/// output timestamps, and writes an HEVC clip via `AVAssetWriter`.
///
/// All gating/writer state is only ever touched on `queue`, so it is safe
/// whether frames arrive from a real capture buffer queue (device) or
/// synchronously from the calling thread (`SyntheticFrameSource` in tests).
final class CaptureController {
    private let source: FrameSource
    private let clock: Clock
    private let queue = DispatchQueue(label: "studylapse.capture.controller")

    private var writer: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var currentURL: URL?
    private var intervalSeconds: Double = 3
    private var outputFrameRate: Int32 = 30
    private var lastAcceptedPTS: CMTime?
    private var frameIndex: Int = 0

    private static let gatingTolerance = 0.02

    init(source: FrameSource, clock: Clock = SystemClock()) {
        self.source = source
        self.clock = clock
    }

    func startClip(to url: URL, intervalSeconds: Double, outputFrameRate: Int32) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)

        queue.sync {
            self.writer = writer
            self.writerInput = nil
            self.pixelBufferAdaptor = nil
            self.currentURL = url
            self.intervalSeconds = intervalSeconds
            self.outputFrameRate = outputFrameRate
            self.lastAcceptedPTS = nil
            self.frameIndex = 0
        }

        source.onFrame = { [weak self] pixelBuffer, pts in
            self?.queue.async {
                self?.handleFrame(pixelBuffer, pts: pts)
            }
        }
        try source.start()
        DebugLog.write(
            "Capture",
            "clip started: \(url.lastPathComponent), interval \(intervalSeconds)s, fps \(outputFrameRate)"
        )
    }

    func finishClip() async throws -> (frameCount: Int, url: URL) {
        source.stop()
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let writer = self.writer, let input = self.writerInput, let url = self.currentURL else {
                    continuation.resume(throwing: CaptureControllerError.noActiveClip)
                    return
                }
                let finalFrameCount = self.frameIndex
                input.markAsFinished()
                writer.finishWriting {
                    if writer.status == .completed {
                        DebugLog.write("Capture", "writer finished: \(finalFrameCount) frames -> \(url.lastPathComponent)")
                        continuation.resume(returning: (finalFrameCount, url))
                    } else {
                        let message = writer.error?.localizedDescription ?? "unknown writer error"
                        DebugLog.write("Capture", "writer failed: \(message)")
                        continuation.resume(throwing: CaptureControllerError.writerFinishFailed(message))
                    }
                }
            }
        }
    }

    /// Runs only on `queue`.
    private func handleFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let writer else { return }

        if writer.status == .unknown {
            setUpWriterInputIfNeeded()
            guard writer.startWriting() else {
                DebugLog.write("Capture", "startWriting failed: \(writer.error?.localizedDescription ?? "unknown")")
                return
            }
            writer.startSession(atSourceTime: .zero)
        }

        guard writer.status == .writing else {
            DebugLog.write("Capture", "frame dropped, writer status \(writer.status.rawValue)")
            return
        }

        let accept: Bool
        if let lastAcceptedPTS {
            let delta = CMTimeGetSeconds(CMTimeSubtract(pts, lastAcceptedPTS))
            accept = delta >= intervalSeconds - Self.gatingTolerance
        } else {
            accept = true
        }

        guard accept else {
            DebugLog.write("Capture", "frame gated out at pts \(CMTimeGetSeconds(pts))s")
            return
        }

        guard let writerInput, let pixelBufferAdaptor else { return }

        // Frames arrive on `queue` in a burst (synthetic frames aren't real-time
        // paced; real device frames are ~3s apart so this rarely engages). The
        // writer's internal encoder briefly lags behind append calls with
        // expectsMediaDataInRealTime = false — wait for it rather than dropping
        // an accepted frame outright.
        var waitAttempts = 0
        while !writerInput.isReadyForMoreMediaData && waitAttempts < 200 {
            Thread.sleep(forTimeInterval: 0.005)
            waitAttempts += 1
        }
        guard writerInput.isReadyForMoreMediaData else {
            DebugLog.write("Capture", "frame dropped, writer input not ready after waiting")
            return
        }

        let writtenTime = CMTime(value: Int64(frameIndex), timescale: outputFrameRate)
        if pixelBufferAdaptor.append(pixelBuffer, withPresentationTime: writtenTime) {
            lastAcceptedPTS = pts
            DebugLog.write("Capture", "frame accepted at pts \(CMTimeGetSeconds(pts))s, written index \(frameIndex)")
            frameIndex += 1
        } else {
            DebugLog.write("Capture", "frame append failed: \(writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Runs only on `queue`.
    private func setUpWriterInputIfNeeded() {
        guard writerInput == nil, let writer else { return }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 8_000_000,
                AVVideoExpectedSourceFrameRateKey: 30,
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ]
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
        )
        writer.add(input)
        writerInput = input
        pixelBufferAdaptor = adaptor
    }
}
