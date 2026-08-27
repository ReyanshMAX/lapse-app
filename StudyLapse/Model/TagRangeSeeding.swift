import Foundation
import StudyLapseCore
import SwiftData

/// Seeds and repairs the `TagRange` rows that tile a session's study-time axis:
/// one range per finalized clip, `origin == .segment`, created on session end
/// (BUILD.md Phase 4). Consumes `TagRangeMath` from StudyLapseCore for all
/// tiling math — never forks it (docs/UI.md §4).
enum TagRangeSeeding {

    /// Ensures `session.tagRanges` tiles `[0, totalStudySeconds)` without
    /// discarding any tagging the user has already done. Idempotent — meant to
    /// be called from `SessionCoordinator.end()` *and* again when the tagging
    /// screen opens, so a rollover clip whose `persistFinalizedClip` `Task`
    /// hadn't landed yet at `end()` time still ends up with its own range
    /// (see STATUS.md Deviations).
    ///
    /// - no ranges yet → seed from the finalized clip durations
    /// - ranges exist, none user-touched, but they don't tile the current
    ///   total (a clip landed late) → re-seed from scratch
    /// - ranges exist and *are* user-touched but the tail is uncovered →
    ///   append one untagged `.segment` range over the gap, preserving the
    ///   one-range-per-clip property criterion 3 checks
    @MainActor
    static func ensureSeeded(for session: Session, in context: ModelContext) {
        let durations = session.orderedFinalizedClips.map(\.studyDuration)
        let total = durations.reduce(0, +)
        guard total > 0 else { return }

        let existing = session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }

        if existing.isEmpty {
            insertSeed(durations: durations, session: session, context: context)
            try? context.save()
            return
        }

        let asRanges = existing.map {
            TagRangeMath.Range(start: $0.startStudySeconds, end: $0.endStudySeconds, tags: $0.tagNames)
        }
        if TagRangeMath.validate(asRanges, total: total) { return }

        let userTouched = existing.contains {
            !$0.tagNames.isEmpty || TagRangeOrigin(rawValue: $0.origin) == .manual
        }

        if userTouched {
            let covered = existing.last?.endStudySeconds ?? 0
            if covered < total - 1e-6 {
                let gap = TagRange(session: session,
                                   startStudySeconds: covered,
                                   endStudySeconds: total,
                                   tagNames: [],
                                   origin: .segment)
                context.insert(gap)
            }
        } else {
            let deletedIDs = Set(existing.map(\.id))
            for range in existing { context.delete(range) }
            session.tagRanges.removeAll { deletedIDs.contains($0.id) }
            insertSeed(durations: durations, session: session, context: context)
        }
        try? context.save()
    }

    @MainActor
    private static func insertSeed(durations: [Double], session: Session, context: ModelContext) {
        for range in TagRangeMath.seed(fromClipDurations: durations) {
            let row = TagRange(session: session,
                               startStudySeconds: range.start,
                               endStudySeconds: range.end,
                               tagNames: range.tags,
                               origin: .segment)
            context.insert(row)
        }
    }
}
