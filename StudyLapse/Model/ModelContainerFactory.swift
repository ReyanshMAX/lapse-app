import Foundation
import SwiftData

/// Single place that builds the SwiftData stack. The full entity list lives
/// here so the app and the simulator test target register exactly the same
/// schema (docs/DATA_MODEL.md).
enum ModelContainerFactory {
    static let schema = Schema([
        Session.self,
        Clip.self,
        TagRange.self,
        Tag.self,
        ExportProfile.self,
        VoiceoverTake.self,
        ExportRecord.self,
    ])

    /// The on-disk container backing the running app. The store file sits in
    /// Application Support alongside the media root (D-021).
    static func makeShared() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    /// An ephemeral in-memory container for tests — no file, no leakage
    /// between test cases (docs/TESTING.md).
    static func makeInMemory() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }
}
