import Foundation
import SwiftData

/// A contiguous span on the study-time axis carrying zero or more tag names.
/// Ranges tile the whole session with no gaps or overlaps (D-010); an empty
/// `tagNames` is a real "untagged" state, not an error.
@Model
final class TagRange {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var startStudySeconds: Double
    var endStudySeconds: Double
    var tagNames: [String]          // may be empty (untagged range)
    var origin: String              // TagRangeOrigin.rawValue

    init(id: UUID = UUID(), session: Session? = nil,
         startStudySeconds: Double, endStudySeconds: Double,
         tagNames: [String] = [], origin: TagRangeOrigin = .segment) {
        self.id = id
        self.session = session
        self.startStudySeconds = startStudySeconds
        self.endStudySeconds = endStudySeconds
        self.tagNames = tagNames
        self.origin = origin.rawValue
    }
}

enum TagRangeOrigin: String, Codable {
    case segment    // auto-created at clip boundaries, editable
    case manual     // created or resized via the slider
}
