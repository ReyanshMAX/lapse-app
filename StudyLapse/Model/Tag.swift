import Foundation
import SwiftData

/// A reusable subject label. `name` is the unique key, always lowercased and
/// trimmed on write; `displayName` preserves what the user typed.
@Model
final class Tag {
    @Attribute(.unique) var name: String
    var displayName: String
    var colorHex: String
    var useCount: Int
    var lastUsedAt: Date

    init(name: String, displayName: String, colorHex: String,
         useCount: Int = 0, lastUsedAt: Date = .now) {
        self.name = name
        self.displayName = displayName
        self.colorHex = colorHex
        self.useCount = useCount
        self.lastUsedAt = lastUsedAt
    }
}
