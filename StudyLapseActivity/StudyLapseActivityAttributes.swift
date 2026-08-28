import ActivityKit
import Foundation

/// Compiled into both the app target and the `StudyLapseActivity` widget
/// extension target (see project.yml — this single file is listed as a
/// source of both). No modularisation into a separate framework
/// (docs/ARCHITECTURE.md non-goals) — this is the one type that has to cross
/// the process boundary, so it is duplicated at compile time instead.
struct StudyLapseActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var studySeconds: Double
        var clipCount: Int
    }

    /// `dayKey` at the time the paused session's Live Activity was started —
    /// display only, not used for identity (docs/UI.md "Live Activity").
    var dayKey: String
}
