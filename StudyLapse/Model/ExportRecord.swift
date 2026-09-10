import Foundation
import SwiftData

/// A rendered export written to disk. Sources are retained after export
/// (D-005), so a session can be re-exported at a different speed or overlay
/// and each render gets its own record.
///
/// `session` is nil for a merged export (developer request, 2026-09-10 —
/// "merge multiple study sessions at export... not merge the source clips").
/// A merge draws clips from several sessions, so it has no single owner to
/// cascade-delete it or hold it in `Session.exports`; `mergedSessionIDs`
/// records which sessions contributed, by id only (no relationship), so
/// deleting one of those sessions later doesn't touch this export — the same
/// "already-made exports survive a source purge" rule a normal export
/// already gets (docs/DATA_MODEL.md Notes).
@Model
final class ExportRecord {
    @Attribute(.unique) var id: UUID
    var session: Session?
    /// Non-nil (2+ ids, chronological) only for a merged export. Nil for a
    /// normal single-session export, where `session` is the source of truth.
    var mergedSessionIDs: [UUID]?
    var relativePath: String        // "sessions/<uuid>/exports/<uuid>.mov", or "merged-exports/<uuid>.mov"
    var createdAt: Date
    var durationSeconds: Double
    var fileSizeBytes: Int64

    init(id: UUID = UUID(), session: Session? = nil, mergedSessionIDs: [UUID]? = nil,
         relativePath: String, createdAt: Date = .now,
         durationSeconds: Double, fileSizeBytes: Int64) {
        self.id = id
        self.session = session
        self.mergedSessionIDs = mergedSessionIDs
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
    }
}
