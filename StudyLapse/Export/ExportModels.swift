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

    let sessionID: UUID
    let sessionStartedAt: Date
    let dayKey: String
    let clips: [Clip]
    let captureIntervalSeconds: Double
    let outputFrameRate: Int32
    let totalStudySeconds: Double

    let speedMode: SpeedMode
    let aspect: AspectPreset
    let overlayStyle: OverlayStyle
    let overlayCorner: OverlayCorner
    let includeIntroCard: Bool
    let includeOutroCard: Bool
    let profileRevision: Int
    let tagNames: [String]

    /// The exact duration the exported file will have, after the minimum-speed
    /// floor is applied. Both the UI and the composition scale read this.
    var outputDuration: Double {
        TimeAxis.outputDuration(mode: speedMode,
                                totalStudySeconds: totalStudySeconds,
                                interval: captureIntervalSeconds,
                                fps: outputFrameRate)
    }
}

/// A voiceover take flattened for the exporter. Phase 6 populates these; the
/// type exists now so `ExportRequest` matches its final shape.
struct VoiceoverTakeSnapshot: Sendable {
    let url: URL
    let outputStartSeconds: Double
    let durationSeconds: Double
}

struct ExportRequest: Sendable {
    let plan: ExportPlan
    /// Non-muted, non-stale takes only. Empty until Phase 6.
    var voiceoverTakes: [VoiceoverTakeSnapshot] = []
}

@MainActor
protocol SessionExporter {
    func export(_ request: ExportRequest,
                progress: @escaping (Double) -> Void) async throws -> URL
}
