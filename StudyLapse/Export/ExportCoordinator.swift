import AVFoundation
import Foundation
import Observation
import StudyLapseCore
import SwiftData

/// Owns an export run for the UI: builds the `Sendable` `ExportPlan` from the
/// live `@Model` objects on the main actor, drives `SessionExporter`, writes
/// the `ExportRecord`, and surfaces progress. See docs/ARCHITECTURE.md.
@MainActor
@Observable
final class ExportCoordinator {
    private(set) var progress: Double?
    private(set) var lastExportURL: URL?
    private(set) var lastExportRecord: ExportRecord?
    private(set) var lastError: String?
    private(set) var isExporting = false

    private let context: ModelContext
    private let exporter: AVFoundationSessionExporter

    init(context: ModelContext, exporter: AVFoundationSessionExporter? = nil) {
        self.context = context
        self.exporter = exporter ?? AVFoundationSessionExporter()
    }

    /// Live estimate for the export UI — the exact duration the file will have,
    /// including the minimum-speed clamp. The same value the composition is
    /// scaled to (`TimeAxis.outputDuration`).
    static func estimatedOutputDuration(sessions: [Session], profile: ExportProfile) -> Double {
        guard let first = sessions.first else { return 0 }
        let total = sessions.reduce(0.0) { $0 + $1.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration } }
        return TimeAxis.outputDuration(mode: Self.speedMode(profile),
                                       totalStudySeconds: total,
                                       interval: first.captureIntervalSeconds,
                                       fps: first.outputFrameRate)
    }

    static func estimatedOutputDuration(session: Session, profile: ExportProfile) -> Double {
        estimatedOutputDuration(sessions: [session], profile: profile)
    }

    /// True when the requested net speed is slower than the minimum-speed floor
    /// and the output has been clamped (so it's longer than asked for) —
    /// docs/DATA_MODEL.md.
    static func isClampedToFloor(sessions: [Session], profile: ExportProfile) -> Bool {
        guard let first = sessions.first else { return false }
        let interval = first.captureIntervalSeconds
        let fps = first.outputFrameRate
        let total = sessions.reduce(0.0) { $0 + $1.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration } }
        guard total > 0 else { return false }
        let floor = TimeAxis.minimumSpeed(interval: interval, fps: fps)

        let requestedSpeed: Double
        switch speedMode(profile) {
        case .multiplier(let m):
            requestedSpeed = m
        case .fitToDuration(let target):
            guard target > 0 else { return false }
            requestedSpeed = total / target
        }
        return requestedSpeed < floor - 1e-6
    }

    static func isClampedToFloor(session: Session, profile: ExportProfile) -> Bool {
        isClampedToFloor(sessions: [session], profile: profile)
    }

    func export(session: Session, profile: ExportProfile) async {
        await export(sessions: [session], profile: profile)
    }

    /// One or more sessions, chronological. A single session behaves exactly
    /// as before; two or more produce a merged export with no owning session
    /// (`ExportRecord.mergedSessionIDs` — developer request, 2026-09-10).
    func export(sessions: [Session], profile: ExportProfile) async {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        lastError = nil
        defer { isExporting = false }

        do {
            let plan = try Self.buildPlan(sessions: sessions, profile: profile)
            let url = try await exporter.export(
                ExportRequest(plan: plan),
                progress: { [weak self] value in self?.progress = value })

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let record = ExportRecord(
                session: plan.isMerged ? nil : sessions.first,
                mergedSessionIDs: plan.isMerged ? plan.sourceSessionIDs : nil,
                relativePath: StorageLocator.relativePath(for: url),
                durationSeconds: plan.outputDuration,
                fileSizeBytes: size)
            context.insert(record)
            try? context.save()

            lastExportRecord = record
            lastExportURL = url
            progress = 1
            DebugLog.write("Export", "wrote \(url.lastPathComponent), \(plan.outputDuration)s, \(size) bytes")
            await logTrackSummary(of: url)
        } catch {
            progress = nil
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugLog.write("Export", "failed: \(error)")
        }
    }

    func cancel() {
        exporter.cancel()
    }

    /// Reads the finished file's tracks back and logs them — the render can't
    /// run in CI, so this is how BUILD.md Phase 3 criterion 3 ("an audio track
    /// of the full duration") gets verified on device: check the debug log.
    private func logTrackSummary(of url: URL) async {
        let asset = AVURLAsset(url: url)
        let fileSeconds = ((try? await asset.load(.duration))?.seconds) ?? 0
        let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
        let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
        var audioSeconds = 0.0
        if let track = audio.first {
            audioSeconds = ((try? await track.load(.timeRange))?.duration.seconds) ?? 0
        }
        DebugLog.write("Export", String(format:
            "verify: %d video + %d audio track(s); file %.2fs, audio track %.2fs",
            video.count, audio.count, fileSeconds, audioSeconds))
    }

    // MARK: Plan construction (main actor — reads @Model state)

    static func buildPlan(session: Session, profile: ExportProfile) throws -> ExportPlan {
        try buildPlan(sessions: [session], profile: profile)
    }

    /// `sessions` need not already be in order — sorted here by `startedAt`
    /// so a merge always concatenates chronologically regardless of pick
    /// order in the merge picker.
    static func buildPlan(sessions: [Session], profile: ExportProfile) throws -> ExportPlan {
        guard !sessions.isEmpty else { throw ExportError.noFinalizedClips }
        for session in sessions {
            guard session.sourcesPurgedAt == nil else { throw ExportError.sourcesPurged }
        }
        let ordered = sessions.sorted { $0.startedAt < $1.startedAt }
        if Set(ordered.map(\.captureIntervalSeconds)).count > 1
            || Set(ordered.map(\.outputFrameRate)).count > 1 {
            throw ExportError.mismatchedCaptureSettings
        }

        let clips = ordered.flatMap { $0.orderedFinalizedClips.filter { $0.frameCount > 0 } }
        guard !clips.isEmpty else { throw ExportError.noFinalizedClips }

        let planClips = clips.map { clip in
            ExportPlan.Clip(url: StorageLocator.url(forRelativePath: clip.relativePath),
                            frameCount: clip.frameCount)
        }
        let total = clips.reduce(0.0) { $0 + $1.studyDuration }
        let tagNames = Array(Set(ordered.flatMap { $0.tagRanges.flatMap(\.tagNames) })).sorted()
        let first = ordered[0]

        return ExportPlan(
            exportID: UUID(),
            primarySessionID: ordered.count == 1 ? first.id : nil,
            sourceSessionIDs: ordered.map(\.id),
            sessionStartedAt: first.startedAt,
            sessionEndedAt: ordered.last?.endedAt,
            dayKey: first.dayKey,
            clips: planClips,
            captureIntervalSeconds: first.captureIntervalSeconds,
            outputFrameRate: first.outputFrameRate,
            totalStudySeconds: total,
            speedMode: speedMode(profile),
            aspect: AspectPreset(raw: profile.aspectRaw),
            rotation: VideoRotation(raw: profile.rotationDegreesRaw),
            isMirrored: profile.isMirrored,
            overlayStyle: OverlayStyle(raw: profile.overlayStyleRaw),
            overlayCorner: OverlayCorner(raw: profile.overlayCornerRaw),
            includeIntroCard: profile.includeIntroCard,
            includeOutroCard: profile.includeOutroCard,
            tagNames: tagNames)
    }

    static func speedMode(_ profile: ExportProfile) -> SpeedMode {
        profile.speedModeRaw == "fitToDuration"
            ? .fitToDuration(targetSeconds: profile.targetDurationSeconds)
            : .multiplier(profile.speedMultiplier)
    }
}
