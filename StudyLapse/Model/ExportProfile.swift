import Foundation
import SwiftData

/// Per-session export settings. `revision` bumps on any field change and
/// invalidates voiceover takes recorded against an older revision, since a
/// speed change moves every word on the output timeline.
@Model
final class ExportProfile {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var speedModeRaw: String        // "multiplier" | "fitToDuration"
    var speedMultiplier: Double     // used when speedModeRaw == "multiplier"
    var targetDurationSeconds: Double // used when speedModeRaw == "fitToDuration"
    var aspectRaw: String           // "portrait9x16" | "square1x1" | "original"
    var overlayStyleRaw: String     // "minimal" | "boxed" | "mono"
    var overlayCornerRaw: String    // "topLeft" | "topRight" | "bottomLeft" | "bottomRight"
    var includeIntroCard: Bool
    var includeOutroCard: Bool
    var revision: Int               // bumped on any change; invalidates voiceover takes

    init(id: UUID = UUID(), session: Session? = nil,
         speedModeRaw: String = "multiplier",
         speedMultiplier: Double = 100,
         targetDurationSeconds: Double = 30,
         aspectRaw: String = "portrait9x16",
         overlayStyleRaw: String = "minimal",
         overlayCornerRaw: String = "topRight",
         includeIntroCard: Bool = false,
         includeOutroCard: Bool = false,
         revision: Int = 0) {
        self.id = id
        self.session = session
        self.speedModeRaw = speedModeRaw
        self.speedMultiplier = speedMultiplier
        self.targetDurationSeconds = targetDurationSeconds
        self.aspectRaw = aspectRaw
        self.overlayStyleRaw = overlayStyleRaw
        self.overlayCornerRaw = overlayCornerRaw
        self.includeIntroCard = includeIntroCard
        self.includeOutroCard = includeOutroCard
        self.revision = revision
    }
}
