import Foundation
import SwiftData

/// A single voiceover recording, stored as a separate audio layer keyed to
/// the session and composited at export — never baked into stored video
/// (D-011). `outputStartSeconds` is a position on the exported timeline.
@Model
final class VoiceoverTake {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var relativePath: String        // "sessions/<uuid>/voiceovers/<uuid>.m4a"
    var outputStartSeconds: Double  // position on the EXPORTED timeline, not the study axis
    var durationSeconds: Double
    var recordedAgainstProfileRevision: Int
    var isMuted: Bool
    var createdAt: Date

    init(id: UUID = UUID(), session: Session? = nil, relativePath: String,
         outputStartSeconds: Double, durationSeconds: Double,
         recordedAgainstProfileRevision: Int, isMuted: Bool = false,
         createdAt: Date = .now) {
        self.id = id
        self.session = session
        self.relativePath = relativePath
        self.outputStartSeconds = outputStartSeconds
        self.durationSeconds = durationSeconds
        self.recordedAgainstProfileRevision = recordedAgainstProfileRevision
        self.isMuted = isMuted
        self.createdAt = createdAt
    }
}
