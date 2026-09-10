import Foundation
import SwiftData

/// Per-session export settings.
@Model
final class ExportProfile {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var speedModeRaw: String        // "multiplier" | "fitToDuration"
    var speedMultiplier: Double     // used when speedModeRaw == "multiplier"
    var targetDurationSeconds: Double // used when speedModeRaw == "fitToDuration"
    var aspectRaw: String           // "portrait9x16" | "square1x1" | "original"
    /// Quarter turns clockwise applied to the source before the crop and
    /// overlay (0/90/180/270 — `VideoRotation`). Lightweight-migratable,
    /// added 2026-09-09: the clock overlay is positioned in output-render
    /// space *after* this rotation, so rotating here is what makes the
    /// overlay's corner track the displayed orientation instead of staying
    /// stuck relative to the raw recorded orientation. The inline `= 0`
    /// default (not just the initializer's) is what SwiftData needs to
    /// backfill this column on rows that predate it.
    var rotationDegreesRaw: Int = 0
    /// Horizontal flip, applied after `rotationDegreesRaw`. Lightweight-
    /// migratable, added 2026-09-09 — see `rotationDegreesRaw` on the inline
    /// default.
    var isMirrored: Bool = false
    var overlayStyleRaw: String     // "minimal" | "boxed" | "mono"
    var overlayCornerRaw: String    // "topLeft" | "topRight" | "bottomLeft" | "bottomRight"
    var includeIntroCard: Bool
    var includeOutroCard: Bool

    init(id: UUID = UUID(), session: Session? = nil,
         speedModeRaw: String = "multiplier",
         speedMultiplier: Double = 100,
         targetDurationSeconds: Double = 30,
         aspectRaw: String = "portrait9x16",
         rotationDegreesRaw: Int = 0,
         isMirrored: Bool = false,
         overlayStyleRaw: String = "minimal",
         overlayCornerRaw: String = "topRight",
         includeIntroCard: Bool = false,
         includeOutroCard: Bool = false) {
        self.id = id
        self.session = session
        self.speedModeRaw = speedModeRaw
        self.speedMultiplier = speedMultiplier
        self.targetDurationSeconds = targetDurationSeconds
        self.aspectRaw = aspectRaw
        self.rotationDegreesRaw = rotationDegreesRaw
        self.isMirrored = isMirrored
        self.overlayStyleRaw = overlayStyleRaw
        self.overlayCornerRaw = overlayCornerRaw
        self.includeIntroCard = includeIntroCard
        self.includeOutroCard = includeOutroCard
    }
}
