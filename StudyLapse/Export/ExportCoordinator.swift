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
    private(set) var lastError: String?
    private(set) var isExporting = false

    private let context: ModelContext
    private let exporter: AVFoundationSessionExporter

    init(context: ModelContext,
         exporter: AVFoundationSessionExporter = AVFoundationSessionExporter()) {
        self.context = context
        self.exporter = exporter
    }

    /// Live estimate for the export UI — the exact duration the file will have,
    /// including the minimum-speed clamp. The same value the composition is
    /// scaled to (`TimeAxis.outputDuration`).
    static func estimatedOutputDuration(session: Session, profile: ExportProfile) -> Double {
        let total = session.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration }
        return TimeAxis.outputDuration(mode: Self.speedMode(profile),
                                       totalStudySeconds: total,
                                       interval: session.captureIntervalSeconds,
                                       fps: session.outputFrameRate)
    }

    /// True when the requested speed/target can't be met and the output is
    /// clamped to the minimum-speed floor (docs/DATA_MODEL.md).
    static func isClampedToFloor(session: Session, profile: ExportProfile) -> Bool {
        let interval = session.captureIntervalSeconds
        let fps = session.outputFrameRate
        let total = session.orderedFinalizedClips.reduce(0.0) { $0 + $1.studyDuration }
        let floor = TimeAxis.minimumSpeed(interval: interval, fps: fps)

        let rawSpeed: Double
        switch speedMode(profile) {
        case .multiplier(let m):
            rawSpeed = m
        case .fitToDuration(let target):
            guard target > 0 else { return false }
            rawSpeed = TimeAxis.baseOutputSeconds(totalStudySeconds: total,
                                                  interval: interval, fps: fps) / target
        }
        return rawSpeed < floor - 1e-6
    }

    func export(session: Session, profile: ExportProfile) async {
        guard !isExporting else { return }
        isExporting = true
        progress = 0
        lastError = nil
        defer { isExporting = false }

        do {
            let plan = try Self.buildPlan(session: session, profile: profile)
            let url = try await exporter.export(
                ExportRequest(plan: plan),
                progress: { [weak self] value in self?.progress = value })

            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
            let record = ExportRecord(
                session: session,
                relativePath: StorageLocator.relativePath(for: url),
                profileRevision: profile.revision,
                durationSeconds: plan.outputDuration,
                fileSizeBytes: size)
            context.insert(record)
            try? context.save()

            lastExportURL = url
            progress = 1
            DebugLog.write("Export", "wrote \(url.lastPathComponent), \(plan.outputDuration)s, \(size) bytes")
        } catch {
            progress = nil
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            DebugLog.write("Export", "failed: \(error)")
        }
    }

    func cancel() {
        exporter.cancel()
    }

    // MARK: Plan construction (main actor — reads @Model state)

    static func buildPlan(session: Session, profile: ExportProfile) throws -> ExportPlan {
        let clips = session.orderedFinalizedClips.filter { $0.frameCount > 0 }
        guard !clips.isEmpty else { throw ExportError.noFinalizedClips }

        let planClips = clips.map { clip in
            ExportPlan.Clip(url: StorageLocator.url(forRelativePath: clip.relativePath),
                            frameCount: clip.frameCount)
        }
        let total = clips.reduce(0.0) { $0 + $1.studyDuration }
        let tagNames = Array(Set(session.tagRanges.flatMap(\.tagNames))).sorted()

        return ExportPlan(
            sessionID: session.id,
            sessionStartedAt: session.startedAt,
            dayKey: session.dayKey,
            clips: planClips,
            captureIntervalSeconds: session.captureIntervalSeconds,
            outputFrameRate: session.outputFrameRate,
            totalStudySeconds: total,
            speedMode: speedMode(profile),
            aspect: AspectPreset(raw: profile.aspectRaw),
            overlayStyle: OverlayStyle(raw: profile.overlayStyleRaw),
            overlayCorner: OverlayCorner(raw: profile.overlayCornerRaw),
            includeIntroCard: profile.includeIntroCard,
            includeOutroCard: profile.includeOutroCard,
            profileRevision: profile.revision,
            tagNames: tagNames)
    }

    static func speedMode(_ profile: ExportProfile) -> SpeedMode {
        profile.speedModeRaw == "fitToDuration"
            ? .fitToDuration(targetSeconds: profile.targetDurationSeconds)
            : .multiplier(profile.speedMultiplier)
    }
}
