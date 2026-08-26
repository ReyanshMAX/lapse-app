import Foundation
import SwiftData

/// A rendered export written to disk. Sources are retained after export
/// (D-005), so a session can be re-exported at a different speed or overlay
/// and each render gets its own record.
@Model
final class ExportRecord {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var relativePath: String        // "sessions/<uuid>/exports/<uuid>.mov"
    var createdAt: Date
    var profileRevision: Int
    var durationSeconds: Double
    var fileSizeBytes: Int64

    init(id: UUID = UUID(), session: Session? = nil, relativePath: String,
         createdAt: Date = .now, profileRevision: Int,
         durationSeconds: Double, fileSizeBytes: Int64) {
        self.id = id
        self.session = session
        self.relativePath = relativePath
        self.createdAt = createdAt
        self.profileRevision = profileRevision
        self.durationSeconds = durationSeconds
        self.fileSizeBytes = fileSizeBytes
    }
}
