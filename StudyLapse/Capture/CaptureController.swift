import AVFoundation
import CoreMedia
import CoreVideo

enum CaptureControllerError: Error {
    case noActiveClip
    case writerFinishFailed(String)
}

/// A clip that finished writing to disk. A plain value so it can cross from the
/// capture queue to the main actor without dragging a non-Sendable `@Model`
/// type along (docs/ARCHITECTURE.md threading rules).
struct FinalizedClip: Sendable {
    let index: Int
    let url: URL
    let frameCount: Int
}

/// Consumes a `FrameSource` — never owns `AVCaptureSession` directly (D-026).
/// Gates incoming frames to `intervalSeconds` apart, synthesizes sequential
/// output timestamps, and writes HEVC clips via `AVAssetWriter`.
///
/// Two modes:
/// - `startClip` / `finishClip`: a single clip, used by the Phase 1 thin slice.
/// - `startRecording` / `stopRecording`: continuous capture with chunk
///   rollover every `maxSegmentSeconds` of recorded time or `maxSegmentFrames`
///   frames (D-015). Each finalized chunk is delivered through
///   `onClipFinalized`; the caller persists it on the main actor.
///
/// All gating/writer state is only ever touched on `queue`, so it is safe
/// whether frames arrive from a real capture buffer queue (device) or
/// synchronously from the calling thread (`SyntheticFrameSource` in tests).
/// `@unchecked Sendable`: the compiler can't see that `queue` serializes every
/// mutable access, which is exactly what makes this safe to capture in the
/// `@Sendable` closures passed to `DispatchQueue.async`.
final class CaptureController: @unchecked Sendable {
    /// Rollover thresholds (D-015 / docs/CAPTURE.md).
    static let maxSegmentSeconds: Double = 120
    static let maxSegmentFrames: Int = 1000
    private static let gatingTolerance = 0.02

    private let source: FrameSource
    private let clock: Clock
    private let queue = DispatchQueue(label: "studylapse.capture.controller")

    /// One writer + its bookkeeping. Reference type so completion closures can
    /// hold it alive past a rollover until `finishWriting` returns.
    private final class Segment {
        let writer: AVAssetWriter
        let input: AVAssetWriterInput
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let url: URL
        let index: Int
        var frameIndex = 0
        var startPTS: CMTime?
        var started = false

        init(writer: AVAssetWriter, input: AVAssetWriterInput,
             adaptor: AVAssetWriterInputPixelBufferAdaptor, url: URL, index: Int) {
            self.writer = writer
            self.input = input
            self.adaptor = adaptor
            self.url = url
            self.index = index
        }
    }

    private var current: Segment?
    private var intervalSeconds: Double = 3
    private var outputFrameRate: Int32 = 30
    private var lastAcceptedPTS: CMTime?
    private var rolloverEnabled = false
    private var nextIndex = 0
    private var urlForClip: (@Sendable (Int) -> URL)?
    private var onClipFinalized: (@Sendable (FinalizedClip) -> Void)?

    init(source: FrameSource, clock: Clock = SystemClock()) {
        self.source = source
        self.clock = clock
    }

    // MARK: Single-clip API (Phase 1)

    func startClip(to url: URL, intervalSeconds: Double, outputFrameRate: Int32) throws {
        let segment = try makeSegment(url: url, index: 0)
        queue.sync {
            self.current = segment
            self.intervalSeconds = intervalSeconds
            self.outputFrameRate = outputFrameRate
            self.lastAcceptedPTS = nil
            self.rolloverEnabled = false
            self.onClipFinalized = nil
            self.urlForClip = nil
        }
        attachFrameHandler()
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
                guard let self, let segment = self.current, segment.started else {
                    continuation.resume(throwing: CaptureControllerError.noActiveClip)
                    return
                }
                self.current = nil
                let count = segment.frameIndex
                let url = segment.url
                segment.input.markAsFinished()
                segment.writer.finishWriting {
                    if segment.writer.status == .completed {
                        DebugLog.write("Capture", "writer finished: \(count) frames -> \(url.lastPathComponent)")
                        continuation.resume(returning: (count, url))
                    } else {
                        let message = segment.writer.error?.localizedDescription ?? "unknown writer error"
                        DebugLog.write("Capture", "writer failed: \(message)")
                        continuation.resume(throwing: CaptureControllerError.writerFinishFailed(message))
                    }
                }
            }
        }
    }

    // MARK: Chunked recording API (Phase 2, D-015)

    func startRecording(
        firstClipIndex: Int,
        urlForClip: @escaping @Sendable (Int) -> URL,
        intervalSeconds: Double,
        outputFrameRate: Int32,
        onClipFinalized: @escaping @Sendable (FinalizedClip) -> Void
    ) throws {
        let segment = try makeSegment(url: urlForClip(firstClipIndex), index: firstClipIndex)
        queue.sync {
            self.current = segment
            self.intervalSeconds = intervalSeconds
            self.outputFrameRate = outputFrameRate
            self.lastAcceptedPTS = nil
            self.rolloverEnabled = true
            self.nextIndex = firstClipIndex + 1
            self.urlForClip = urlForClip
            self.onClipFinalized = onClipFinalized
        }
        attachFrameHandler()
        try source.start()
        DebugLog.write(
            "Capture",
            "recording started at index \(firstClipIndex), interval \(intervalSeconds)s, fps \(outputFrameRate)"
        )
    }

    /// Finalizes the current chunk and returns it once `finishWriting`
    /// completes. Unlike a rollover chunk (which is delivered through
    /// `onClipFinalized`), the trailing chunk is returned directly so the
    /// caller can persist it inside the same awaited call — no detached Task,
    /// no window where a session teardown races the persist.
    @discardableResult
    func stopRecording() async -> FinalizedClip? {
        source.stop()
        return await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let segment = self.current else {
                    continuation.resume(returning: nil)
                    return
                }
                self.current = nil
                self.rolloverEnabled = false

                guard segment.started, segment.frameIndex > 0 else {
                    try? FileManager.default.removeItem(at: segment.url)
                    DebugLog.write("Capture", "stopRecording: dropped empty trailing segment \(segment.index)")
                    continuation.resume(returning: nil)
                    return
                }

                let index = segment.index
                let count = segment.frameIndex
                let url = segment.url
                segment.input.markAsFinished()
                segment.writer.finishWriting {
                    if segment.writer.status == .completed {
                        DebugLog.write("Capture", "segment \(index) finalized on stop: \(count) frames")
                        continuation.resume(returning: FinalizedClip(index: index, url: url, frameCount: count))
                    } else {
                        let message = segment.writer.error?.localizedDescription ?? "unknown writer error"
                        DebugLog.write("Capture", "segment \(index) stop-finalize failed: \(message)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    // MARK: Frame handling — runs only on `queue`

    private func attachFrameHandler() {
        source.onFrame = { [weak self] pixelBuffer, pts in
            self?.queue.async {
                self?.handleFrame(pixelBuffer, pts: pts)
            }
        }
    }

    private func handleFrame(_ pixelBuffer: CVPixelBuffer, pts: CMTime) {
        guard let segment = current else { return }

        if !segment.started {
            guard segment.writer.startWriting() else {
                DebugLog.write("Capture", "startWriting failed: \(segment.writer.error?.localizedDescription ?? "unknown")")
                return
            }
            segment.writer.startSession(atSourceTime: .zero)
            segment.started = true
        }

        guard segment.writer.status == .writing else {
            DebugLog.write("Capture", "frame dropped, writer status \(segment.writer.status.rawValue)")
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

        // Roll over *before* appending so the triggering frame becomes frame 0
        // of the next chunk — no frame is lost at the boundary (docs/CAPTURE.md).
        if rolloverEnabled, let start = segment.startPTS {
            let recorded = CMTimeGetSeconds(CMTimeSubtract(pts, start))
            if recorded >= Self.maxSegmentSeconds || segment.frameIndex >= Self.maxSegmentFrames {
                rollOver()
            }
        }

        guard let active = current else { return }
        append(pixelBuffer, pts: pts, to: active)
    }

    private func append(_ pixelBuffer: CVPixelBuffer, pts: CMTime, to segment: Segment) {
        // The writer's encoder briefly lags append calls with
        // expectsMediaDataInRealTime = false — wait rather than drop an
        // already-accepted frame (see STATUS.md Phase 1 deviations).
        var waitAttempts = 0
        while !segment.input.isReadyForMoreMediaData && waitAttempts < 200 {
            Thread.sleep(forTimeInterval: 0.005)
            waitAttempts += 1
        }
        guard segment.input.isReadyForMoreMediaData else {
            DebugLog.write("Capture", "frame dropped, writer input not ready after waiting")
            return
        }

        let writtenTime = CMTime(value: Int64(segment.frameIndex), timescale: outputFrameRate)
        if segment.adaptor.append(pixelBuffer, withPresentationTime: writtenTime) {
            if segment.startPTS == nil { segment.startPTS = pts }
            lastAcceptedPTS = pts
            DebugLog.write("Capture", "frame accepted at pts \(CMTimeGetSeconds(pts))s, segment \(segment.index) index \(segment.frameIndex)")
            segment.frameIndex += 1
        } else {
            DebugLog.write("Capture", "frame append failed: \(segment.writer.error?.localizedDescription ?? "unknown")")
        }
    }

    /// Finalize the current chunk asynchronously and open the next one so the
    /// caller's frame keeps flowing. Runs only on `queue`.
    private func rollOver() {
        guard let finishing = current else { return }
        let index = finishing.index
        let count = finishing.frameIndex
        let url = finishing.url
        let callback = onClipFinalized

        finishing.input.markAsFinished()
        finishing.writer.finishWriting {
            if finishing.writer.status == .completed {
                DebugLog.write("Capture", "segment \(index) finalized on rollover: \(count) frames")
                callback?(FinalizedClip(index: index, url: url, frameCount: count))
            } else {
                let message = finishing.writer.error?.localizedDescription ?? "unknown writer error"
                DebugLog.write("Capture", "segment \(index) rollover-finalize failed: \(message)")
            }
        }

        let newIndex = nextIndex
        let newURL = urlForClip?(newIndex) ?? url
        do {
            let segment = try makeSegment(url: newURL, index: newIndex)
            guard segment.writer.startWriting() else {
                DebugLog.write("Capture", "rollover startWriting failed: \(segment.writer.error?.localizedDescription ?? "unknown")")
                current = nil
                return
            }
            segment.writer.startSession(atSourceTime: .zero)
            segment.started = true
            current = segment
            nextIndex = newIndex + 1
            DebugLog.write("Capture", "rolled over to segment \(newIndex)")
        } catch {
            DebugLog.write("Capture", "rollover failed to open next segment: \(error)")
            current = nil
        }
    }

    private func makeSegment(url: URL, index: Int) throws -> Segment {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
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
        return Segment(writer: writer, input: input, adaptor: adaptor, url: url, index: index)
    }
}
