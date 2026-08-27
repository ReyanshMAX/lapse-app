import Foundation
import Observation
import StudyLapseCore
import SwiftData

/// Backs the tagging screens (docs/UI.md §4). Holds the working set of ranges
/// as plain `TagRangeMath.Range` values and routes **every** mutation through
/// `TagRangeMath` in StudyLapseCore — no View touches that math directly, so
/// the `simulator` job can prove the tiling logic end to end.
///
/// Persistence reconciles the value array back onto `TagRange` `@Model` rows by
/// index (update in place, insert/delete only the tail) so row `id`s and the
/// `origin` of untouched rows survive. Drag gestures call `previewResize`
/// (memory only) on every frame and `commitResize` once on release, so a
/// 9-hour / many-range session doesn't write to SwiftData per frame
/// (criterion 4).
@MainActor
@Observable
final class TagEditor {
    private(set) var ranges: [TagRangeMath.Range] = []
    let totalStudySeconds: Double

    private let session: Session
    private let context: ModelContext

    init(session: Session, context: ModelContext) {
        self.session = session
        self.context = context
        TagRangeSeeding.ensureSeeded(for: session, in: context)

        let rows = Self.sortedRows(session)
        self.ranges = rows.map {
            TagRangeMath.Range(start: $0.startStudySeconds, end: $0.endStudySeconds, tags: $0.tagNames)
        }
        self.totalStudySeconds = rows.last?.endStudySeconds
            ?? session.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration }
        TagCatalog.refreshUseCounts(in: context)
    }

    // MARK: Boundary edits — all via TagRangeMath

    func split(at position: Double) {
        ranges = TagRangeMath.split(ranges, at: position)
        persist(markMovedManual: true)
    }

    func merge(at index: Int) {
        ranges = TagRangeMath.merge(ranges, at: index)
        persist(markMovedManual: true)
    }

    /// Memory-only — call on `DragGesture.onChanged`.
    func previewResize(boundaryIndex: Int, to position: Double) {
        ranges = TagRangeMath.resize(ranges, boundaryIndex: boundaryIndex, to: position)
    }

    /// Write the current ranges back — call once on `DragGesture.onEnded`.
    func commitResize() {
        persist(markMovedManual: true)
    }

    // MARK: Tag edits

    func setTags(_ tags: [String], at index: Int) {
        guard ranges.indices.contains(index) else { return }
        let normalized = tags
            .map { TagCatalog.normalize($0) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        ranges[index].tags = normalized.filter { seen.insert($0).inserted }
        for raw in tags { TagCatalog.ensure(raw, in: context) }
        persist(markMovedManual: false)
        TagCatalog.refreshUseCounts(in: context)
    }

    var isFullyTagged: Bool { ranges.allSatisfy { !$0.tags.isEmpty } }

    // MARK: Persistence

    private static func sortedRows(_ session: Session) -> [TagRange] {
        session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }
    }

    private func persist(markMovedManual: Bool) {
        let rows = Self.sortedRows(session)
        let shared = min(rows.count, ranges.count)

        for i in 0..<shared {
            let row = rows[i]
            let r = ranges[i]
            let moved = abs(row.startStudySeconds - r.start) > 1e-9
                || abs(row.endStudySeconds - r.end) > 1e-9
            row.startStudySeconds = r.start
            row.endStudySeconds = r.end
            row.tagNames = r.tags
            if markMovedManual && moved { row.origin = TagRangeOrigin.manual.rawValue }
        }

        if rows.count > ranges.count {
            let doomed = Array(rows[ranges.count...])
            let doomedIDs = Set(doomed.map(\.id))
            for row in doomed { context.delete(row) }
            session.tagRanges.removeAll { doomedIDs.contains($0.id) }
        } else if ranges.count > rows.count {
            for r in ranges[rows.count...] {
                let row = TagRange(session: session,
                                   startStudySeconds: r.start, endStudySeconds: r.end,
                                   tagNames: r.tags,
                                   origin: markMovedManual ? .manual : .segment)
                context.insert(row)
            }
        }
        try? context.save()
    }
}
