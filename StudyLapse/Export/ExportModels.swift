import CoreGraphics
import Foundation
import StudyLapseCore

/// Aspect presets from docs/EXPORT.md. Raw values match `ExportProfile.aspectRaw`.
enum AspectPreset: String, Sendable, CaseIterable {
    case portrait9x16
    case square1x1
    case original

    init(raw: String) { self = AspectPreset(rawValue: raw) ?? .portrait9x16 }

    /// Render size for the video composition. The source is centre-cropped and
    /// scaled to fill this (`original` is an identity transform).
    var renderSize: CGSize {
        switch self {
        case .portrait9x16: return CGSize(width: 1080, height: 1920)
        case .square1x1:    return CGSize(width: 1080, height: 1080)
        case .original:     return CGSize(width: 1920, height: 1080)
        }
    }

    var label: String {
        switch self {
        case .portrait9x16: return "9:16"
        case .square1x1:    return "1:1"
        case .original:     return "16:9"
        }
    }
}

/// Overlay timer styles from docs/EXPORT.md. Raw values match
/// `ExportProfile.overlayStyleRaw`.
enum OverlayStyle: String, Sendable, CaseIterable {
    case minimal
    case boxed
    case mono

    init(raw: String) { self = OverlayStyle(rawValue: raw) ?? .minimal }

    var label: String { rawValue.capitalized }
}

/// User-chosen quarter-turn rotation applied to the source video before the
/// centre-crop and the overlay are computed (developer request, 2026-09-09 —
/// "otherwise the clock's position is stuck relative to the video's recorded
/// orientation"). Raw values match `ExportProfile.rotationDegreesRaw`. Applied
/// in `AVFoundationSessionExporter.cropTransform` ahead of the crop scale, so
/// the overlay corner (`OverlayCorner`, chosen in the same render space) is
/// always relative to the *displayed* orientation, never the sensor's.
enum VideoRotation: Int, Sendable, CaseIterable {
    case none = 0
    case quarter = 90
    case half = 180
    case threeQuarter = 270

    init(raw: Int) { self = VideoRotation(rawValue: raw) ?? .none }

    var label: String { "\(rawValue)°" }
}

/// Corner the timer sits in, inset 48pt on each axis. Raw values match
/// `ExportProfile.overlayCornerRaw`.
enum OverlayCorner: String, Sendable, CaseIterable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    init(raw: String) { self = OverlayCorner(rawValue: raw) ?? .topRight }

    var label: String {
        switch self {
        case .topLeft:     return "Top Left"
        case .topRight:    return "Top Right"
        case .bottomLeft:  return "Bottom Left"
        case .bottomRight: return "Bottom Right"
        }
    }
}

/// Typed export failures — surfaced to the UI, never a crash (docs/EXPORT.md:
/// "Export must refuse to run on a session with zero finalized clips").
enum ExportError: LocalizedError, Equatable {
    case noFinalizedClips
    case sourcesPurged
    case unreadableClip(String)
    case compositionFailed(String)
    case renderFailed(String)
    case cancelled
    /// A merge was requested across sessions whose `captureIntervalSeconds`
    /// or `outputFrameRate` don't all match. Mixing them would need each
    /// source clip individually speed-compensated to a common rate before
    /// concatenation — out of scope for v1 (developer request, 2026-09-10);
    /// the merge picker disables incompatible sessions so this is a backstop,
    /// not the primary guard.
    case mismatchedCaptureSettings

    var errorDescription: String? {
        switch self {
        case .noFinalizedClips:
            return "This session has no finished clips to export yet."
        case .sourcesPurged:
            return "This session's source clips were purged, so it can't be re-exported."
        case .unreadableClip(let path):
            return "A clip could not be read: \(path)"
        case .compositionFailed(let detail):
            return "Could not assemble the video: \(detail)"
        case .renderFailed(let detail):
            return "The export failed to render: \(detail)"
        case .cancelled:
            return "Export cancelled."
        case .mismatchedCaptureSettings:
            return "These sessions were recorded with different capture settings and can't be merged."
        }
    }
}

/// A flat, `Sendable` snapshot of everything the exporter needs, built on the
/// main actor from the `Session` + `ExportProfile` `@Model` objects before any
/// AVFoundation work begins.
///
/// Deviation from BUILD.md's `ExportRequest { let session: Session; ... }`
/// contract: the exporter runs its composition off the main actor
/// (docs/ARCHITECTURE.md threading table) and SwiftData `@Model` types are not
/// safe to touch there. Flattening to a value type is the same resolution used
/// for `CaptureController` in Phase 2. See docs/EXPORT.md.
struct ExportPlan: Sendable {
    struct Clip: Sendable {
        let url: URL
        let frameCount: Int
    }

    /// This export's own identity, generated fresh per export call — used
    /// only to key the output file path (`AVFoundationSessionExporter
    /// .outputURL`), independent of which session(s) contributed clips.
    let exportID: UUID
    /// The single owning session, for a normal export. Nil for a merged
    /// export (developer request, 2026-09-10) — there the clips came from
    /// `sourceSessionIDs.count > 1` sessions and none of them owns the
    /// result (see `ExportRecord.mergedSessionIDs`).
    let primarySessionID: UUID?
    /// Every contributing session's id, chronological — one entry for a
    /// normal export, two or more for a merge.
    let sourceSessionIDs: [UUID]
    let sessionStartedAt: Date      // earliest contributing session's start
    let sessionEndedAt: Date?       // latest contributing session's end
    let dayKey: String              // earliest contributing session's dayKey
    let clips: [Clip]
    let captureIntervalSeconds: Double
    let outputFrameRate: Int32
    let totalStudySeconds: Double

    let speedMode: SpeedMode
    let aspect: AspectPreset
    let rotation: VideoRotation
    let isMirrored: Bool
    let overlayStyle: OverlayStyle
    let overlayCorner: OverlayCorner
    let includeIntroCard: Bool
    let includeOutroCard: Bool
    let tagNames: [String]

    var isMerged: Bool { sourceSessionIDs.count > 1 }

    /// The exact duration the exported file will have, after the minimum-speed
    /// floor is applied. Both the UI and the composition scale read this.
    var outputDuration: Double {
        TimeAxis.outputDuration(mode: speedMode,
                                totalStudySeconds: totalStudySeconds,
                                interval: captureIntervalSeconds,
                                fps: outputFrameRate)
    }
}

struct ExportRequest: Sendable {
    let plan: ExportPlan
}

@MainActor
protocol SessionExporter {
    func export(_ request: ExportRequest,
                progress: @escaping (Double) -> Void) async throws -> URL
}
