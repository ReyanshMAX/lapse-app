import Foundation
import SwiftData

/// A reusable label for grouping sessions across days (developer request,
/// 2026-09-09 — "multiple study projects as first-class objects"), e.g.
/// "MCAT prep" vs "Thesis". Denormalized onto `Session.projectName` (a plain
/// normalized-name string, not a SwiftData relationship) rather than
/// `@Relationship`, mirroring how `TagRange.tagNames` already references
/// `Tag` — one session belongs to at most one project, so this is simpler
/// than the many-tags case, but the same reasoning applies: color assignment
/// and a stable display name live in one small catalog table instead of a
/// relationship SwiftData would have to cascade/nullify on delete.
@Model
final class Project {
    @Attribute(.unique) var name: String
    var displayName: String
    var colorHex: String
    var useCount: Int
    var lastUsedAt: Date
    var createdAt: Date

    init(name: String, displayName: String, colorHex: String,
         useCount: Int = 0, lastUsedAt: Date = .now, createdAt: Date = .now) {
        self.name = name
        self.displayName = displayName
        self.colorHex = colorHex
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}
