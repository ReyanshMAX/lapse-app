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
    /// The `settingsFingerprint` captured when `revision` last changed.
    /// Lightweight-migratable optional added in Phase 6 (docs/DATA_MODEL.md):
    /// nil means "never reconciled", and the first `reconcileRevision()` stamps
    /// it without bumping, so a fresh profile's takes stamp against revision 0.
    var fingerprintAtRevision: String?

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
        self.fingerprintAtRevision = nil
    }

    /// A signature of every user-visible export setting. `reconcileRevision()`
    /// bumps `revision` whenever this changes, which marks voiceover takes
    /// recorded against the old revision as stale (docs/DATA_MODEL.md). All
    /// fields are included, not only the timing ones — BUILD.md Phase 6
    /// criterion 2 is "changing the export profile bumps `revision`".
    var settingsFingerprint: String {
        [speedModeRaw,
         String(format: "%.4f", speedMultiplier),
         String(format: "%.4f", targetDurationSeconds),
         aspectRaw, overlayStyleRaw, overlayCornerRaw,
         includeIntroCard ? "1" : "0",
         includeOutroCard ? "1" : "0"].joined(separator: "|")
    }

    /// Bumps `revision` if any setting changed since the last reconcile.
    /// Idempotent — safe to call on every export and on every settings edit.
    /// Returns true when the revision actually advanced.
    @discardableResult
    func reconcileRevision() -> Bool {
        let current = settingsFingerprint
        guard fingerprintAtRevision != current else { return false }
        let firstReconcile = (fingerprintAtRevision == nil)
        fingerprintAtRevision = current
        guard !firstReconcile else { return false }
        revision += 1
        return true
    }
}
