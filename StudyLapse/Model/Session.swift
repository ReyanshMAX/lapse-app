import Foundation
import SwiftData

/// A study session: a container of N clips spanning one study day (D-002).
/// Durations are always measured on the study-time axis (sum of clip
/// durations, pauses excluded) — never wall clock (D-003).
@Model
final class Session {
    @Attribute(.unique) var id: UUID
    var startedAt: Date              // wall clock, first clip start
    var endedAt: Date?              // wall clock, nil while open
    var dayKey: String              // "2026-08-24", derived via DayBoundary
    var captureIntervalSeconds: Double   // frozen at session creation, D-006
    var outputFrameRate: Int32      // frozen at session creation, default 30
    var statusRaw: String           // SessionStatus.rawValue
    var noteText: String?
    /// Set when the user manually purges this session's source clips to reclaim
    /// storage (D-005, docs/UI.md §7). Non-nil means the `clips/` files are gone
    /// but the `Clip` rows remain (they carry `frameCount` / `studyOffsetStart`,
    /// which every stat and tag range depends on); re-export is refused.
    var sourcesPurgedAt: Date?

    @Relationship(deleteRule: .cascade, inverse: \Clip.session)
    var clips: [Clip] = []
    @Relationship(deleteRule: .cascade, inverse: \TagRange.session)
    var tagRanges: [TagRange] = []
    @Relationship(deleteRule: .cascade, inverse: \VoiceoverTake.session)
    var voiceoverTakes: [VoiceoverTake] = []
    @Relationship(deleteRule: .cascade, inverse: \ExportRecord.session)
    var exports: [ExportRecord] = []
    @Relationship(deleteRule: .cascade, inverse: \ExportProfile.session)
    var exportProfile: ExportProfile?

    init(id: UUID = UUID(), startedAt: Date, dayKey: String,
         captureIntervalSeconds: Double, outputFrameRate: Int32 = 30) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = nil
        self.dayKey = dayKey
        self.captureIntervalSeconds = captureIntervalSeconds
        self.outputFrameRate = outputFrameRate
        self.statusRaw = SessionStatus.recording.rawValue
        self.noteText = nil
        self.sourcesPurgedAt = nil
    }

    /// False once the source clips have been purged (D-005) — the library
    /// detail sheet hides re-export and the exporter refuses.
    var canReExport: Bool { sourcesPurgedAt == nil }

    var status: SessionStatus {
        get { SessionStatus(rawValue: statusRaw) ?? .ended }
        set { statusRaw = newValue.rawValue }
    }

    /// Finalized clips in capture order.
    var orderedFinalizedClips: [Clip] {
        clips.filter(\.isFinalized).sorted { $0.index < $1.index }
    }
}

enum SessionStatus: String, Codable {
    case recording, paused, ended
}
