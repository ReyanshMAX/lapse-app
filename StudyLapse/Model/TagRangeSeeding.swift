import Foundation
import StudyLapseCore
import SwiftData

/// Seeds and repairs the `TagRange` rows that tile a session's study-time axis:
/// **one untagged range for the whole session**, `origin == .segment`, created
/// on session end. The user splits it into blocks manually from there (docs/UI.md
/// §4's Split control) rather than starting from one auto-created block per
/// clip/pause cycle — changed 2026-09-07 at the developer's request (see
/// STATUS.md Deviations); BUILD.md Phase 4 criterion 3 originally specified
/// one range per finalized clip, which fragmented the timeline into many tiny
/// blocks on a session with several pause/resume cycles. Consumes
/// `TagRangeMath` from StudyLapseCore for all tiling math — never forks it.
enum TagRangeSeeding {

    /// Ensures `session.tagRanges` tiles `[0, totalStudySeconds)` without
    /// discarding any tagging the user has already done. Idempotent — meant to
    /// be called from `SessionCoordinator.end()` *and* again when the tagging
    /// screen opens, so a rollover clip whose `persistFinalizedClip` `Task`
    /// hadn't landed yet at `end()` time still ends up covered (see STATUS.md
    /// Deviations).
    ///
    /// - no ranges yet → seed one untagged range covering the whole total
    /// - ranges exist, none user-touched, but they don't tile the current
    ///   total (a clip landed late) → re-seed from scratch (still one range)
    /// - ranges exist and *are* user-touched but the tail is uncovered →
    ///   append one untagged `.segment` range over the gap, preserving every
    ///   block the user already split out
    @MainActor
    static func ensureSeeded(for session: Session, in context: ModelContext) {
        let total = session.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration }
        guard total > 0 else { return }

        let existing = session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }

        if existing.isEmpty {
            insertSeed(total: total, session: session, context: context)
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
            insertSeed(total: total, session: session, context: context)
        }
        try? context.save()
    }

    @MainActor
    private static func insertSeed(total: Double, session: Session, context: ModelContext) {
        let row = TagRange(session: session,
                           startStudySeconds: 0,
                           endStudySeconds: total,
                           tagNames: [],
                           origin: .segment)
        context.insert(row)
    }
}
