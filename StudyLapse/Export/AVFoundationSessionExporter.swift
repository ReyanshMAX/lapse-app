import AVFoundation
import StudyLapseCore
import UIKit

/// Concatenates a session's finalized clips into an `AVMutableComposition`,
/// scales to the requested speed (clamped to the minimum-speed floor), burns in
/// the study-time overlay via `AVVideoCompositionCoreAnimationTool`, adds a
/// full-length silent audio track (D-014), and writes a finished `.mov`.
/// See docs/EXPORT.md for the stage-by-stage spec.
///
/// `@MainActor`: it reads a `Sendable` `ExportPlan` snapshot (never a SwiftData
/// `@Model`) and builds the CALayer overlay tree, both of which want the main
/// actor. The heavy render is `AVAssetExportSession`'s own work — awaiting it
/// does not block the main actor.
@MainActor
final class AVFoundationSessionExporter: SessionExporter {
    private weak var activeExport: AVAssetExportSession?
    private var isCancelled = false

    func cancel() {
        isCancelled = true
        activeExport?.cancelExport()
    }

    func export(_ request: ExportRequest,
                progress: @escaping (Double) -> Void) async throws -> URL {
        isCancelled = false
        let plan = request.plan

        guard !plan.clips.isEmpty else { throw ExportError.noFinalizedClips }

        // MARK: 1 — compose video
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ExportError.compositionFailed("no video track")
        }

        var cursor = CMTime.zero
        var sourceNaturalSize = CGSize(width: 1920, height: 1080)
        var sourceTransform = CGAffineTransform.identity

        for clip in plan.clips {
            let asset = AVURLAsset(url: clip.url)
            let tracks = try await asset.loadTracks(withMediaType: .video)
            guard let assetTrack = tracks.first else {
                throw ExportError.unreadableClip(clip.url.lastPathComponent)
            }
            let duration = try await asset.load(.duration)
            guard duration.isValid, duration.seconds > 0 else {
                throw ExportError.unreadableClip(clip.url.lastPathComponent)
            }
            try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: duration),
                                           of: assetTrack, at: cursor)
            cursor = CMTimeAdd(cursor, duration)

            let loaded = try await assetTrack.load(.naturalSize, .preferredTransform)
            sourceNaturalSize = loaded.0
            sourceTransform = loaded.1
        }

        try checkCancelled()

        let composedDuration = composition.duration

        // MARK: 2 — speed scale (video only; the audio track is inserted after
        // this so it isn't scaled too)
        let outputDuration = plan.outputDuration
        guard outputDuration > 0 else {
            throw ExportError.compositionFailed("computed output duration is zero")
        }
        let scaledDuration = CMTime(seconds: outputDuration, preferredTimescale: 600)
        composition.scaleTimeRange(CMTimeRange(start: .zero, duration: composedDuration),
                                   toDuration: scaledDuration)

        // MARK: 3 — full-length silent audio track (D-014)
        let fullDuration = composition.duration
        let silentURL = try SilentAudio.makeFile(duration: fullDuration.seconds)
        defer { try? FileManager.default.removeItem(at: silentURL) }
        let silentAsset = AVURLAsset(url: silentURL)
        let silentTracks = try await silentAsset.loadTracks(withMediaType: .audio)
        if let silentTrack = silentTracks.first,
           let audioTrack = composition.addMutableTrack(
               withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let silentDuration = try await silentAsset.load(.duration)
            let usable = CMTimeMinimum(silentDuration, fullDuration)
            try audioTrack.insertTimeRange(CMTimeRange(start: .zero, duration: usable),
                                           of: silentTrack, at: .zero)
        }

        try checkCancelled()

        // MARK: 4 — video composition + centre-crop transform
        let renderSize = plan.aspect.renderSize
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = CMTime(value: 1, timescale: 30)

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: composition.duration)
        instruction.backgroundColor = UIColor.black.cgColor
        let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
        layerInstruction.setTransform(
            Self.cropTransform(naturalSize: sourceNaturalSize,
                               preferredTransform: sourceTransform,
                               renderSize: renderSize),
            at: .zero)
        instruction.layerInstructions = [layerInstruction]
        videoComposition.instructions = [instruction] as [any AVVideoCompositionInstructionProtocol]

        // MARK: 5 — overlay
        let overlay = OverlayLayerBuilder.build(
            renderSize: renderSize,
            style: plan.overlayStyle,
            corner: plan.overlayCorner,
            totalStudySeconds: plan.totalStudySeconds,
            outputDuration: outputDuration,
            includeIntroCard: plan.includeIntroCard,
            introText: Self.introText(plan),
            includeOutroCard: plan.includeOutroCard,
            outroText: Self.outroText(plan))
        videoComposition.animationTool = AVVideoCompositionCoreAnimationTool(
            postProcessingAsVideoLayer: overlay.video, in: overlay.parent)

        try checkCancelled()

        // MARK: 6 — render
        let outURL = try Self.outputURL(for: plan.sessionID)

        // HEVC first (docs/EXPORT.md); fall back to H.264 if the render fails —
        // the simulator's software HEVC encoder is unreliable (STATUS.md Phase 1
        // encoder history).
        var lastError: String? = nil
        for preset in [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHighestQuality] {
            guard let exporter = AVAssetExportSession(asset: composition, presetName: preset) else {
                lastError = "could not create an export session for preset \(preset)"
                continue
            }
            exporter.videoComposition = videoComposition
            exporter.outputURL = outURL
            exporter.outputFileType = .mov
            exporter.shouldOptimizeForNetworkUse = true
            activeExport = exporter

            // `exportAsynchronously` kicks off the render on AVFoundation's own
            // threads; poll status/progress from the main actor between sleeps.
            // Everything here stays on the main actor — no non-Sendable capture.
            exporter.exportAsynchronously {}
            var polls = 0
            while true {
                let status = exporter.status
                progress(Double(exporter.progress))
                if status == .completed || status == .failed || status == .cancelled { break }
                if polls > 6000 { exporter.cancelExport(); break }   // ~10 min ceiling
                polls += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            activeExport = nil

            switch exporter.status {
            case .completed:
                progress(1)
                return outURL
            case .cancelled:
                try? FileManager.default.removeItem(at: outURL)
                throw ExportError.cancelled
            default:
                lastError = exporter.error?.localizedDescription ?? "unknown render failure"
                try? FileManager.default.removeItem(at: outURL)
                if isCancelled { throw ExportError.cancelled }
                // try the next preset
            }
        }
        throw ExportError.renderFailed(lastError ?? "no usable export preset")
    }

    // MARK: Helpers

    private func checkCancelled() throws {
        if isCancelled { throw ExportError.cancelled }
    }

    private static func outputURL(for sessionID: UUID) throws -> URL {
        let relative = "sessions/\(sessionID.uuidString)/exports/\(UUID().uuidString).mov"
        let url = StorageLocator.url(forRelativePath: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        return url
    }

    /// Fill the render rect by scaling the source up (centre-crop), never
    /// stretching. `original` resolves to the identity transform.
    static func cropTransform(naturalSize: CGSize,
                              preferredTransform: CGAffineTransform,
                              renderSize: CGSize) -> CGAffineTransform {
        let oriented = naturalSize.applying(preferredTransform)
        let srcW = abs(oriented.width)
        let srcH = abs(oriented.height)
        guard srcW > 0, srcH > 0 else { return preferredTransform }

        let scale = max(renderSize.width / srcW, renderSize.height / srcH)
        let scaledW = srcW * scale
        let scaledH = srcH * scale
        let tx = (renderSize.width - scaledW) / 2
        let ty = (renderSize.height - scaledH) / 2

        return preferredTransform
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: tx, y: ty))
    }

    private static func introText(_ plan: ExportPlan) -> String {
        let date = plan.sessionStartedAt.formatted(date: .abbreviated, time: .omitted)
        let study = Formatters.studyTime(plan.totalStudySeconds)
        let tags = plan.tagNames.isEmpty ? "" : "\n" + plan.tagNames.joined(separator: " · ")
        return "\(date)\n\(study)\(tags)"
    }

    private static func outroText(_ plan: ExportPlan) -> String {
        Formatters.studyTime(plan.totalStudySeconds)
    }
}
