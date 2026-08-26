import Foundation

/// Pure tiling math over a session's tag ranges: contiguous, non-overlapping
/// intervals on the study-time axis that cover [0, total) exactly. See
/// docs/DATA_MODEL.md (`TagRange`) and BUILD.md Phase 4.
public enum TagRangeMath {
    public struct Range: Equatable {
        public var start: Double
        public var end: Double
        public var tags: [String]

        public init(start: Double, end: Double, tags: [String]) {
            self.start = start
            self.end = end
            self.tags = tags
        }
    }

    /// One range per clip, tiling [0, total) in clip order. Matches
    /// `TagRangeOrigin.segment` — auto-created at clip boundaries, untagged.
    public static func seed(fromClipDurations durations: [Double]) -> [Range] {
        var ranges: [Range] = []
        var cursor = 0.0
        for duration in durations {
            ranges.append(Range(start: cursor, end: cursor + duration, tags: []))
            cursor += duration
        }
        return ranges
    }

    /// Splits the range containing `position` into two ranges at `position`,
    /// both carrying the original range's tags. A no-op if `position` is
    /// already a boundary or falls outside every range.
    public static func split(_ ranges: [Range], at position: Double) -> [Range] {
        guard let index = ranges.firstIndex(where: { $0.start < position && position < $0.end }) else {
            return ranges
        }
        let original = ranges[index]
        let left = Range(start: original.start, end: position, tags: original.tags)
        let right = Range(start: position, end: original.end, tags: original.tags)
        var result = ranges
        result.replaceSubrange(index...index, with: [left, right])
        return result
    }

    /// Merges the range at `index` with the one immediately after it into a
    /// single range spanning both, with the union of their tags. A no-op if
    /// there is no range at `index + 1`.
    public static func merge(_ ranges: [Range], at index: Int) -> [Range] {
        guard ranges.indices.contains(index), ranges.indices.contains(index + 1) else {
            return ranges
        }
        let first = ranges[index]
        let second = ranges[index + 1]
        let mergedTags = (first.tags + second.tags.filter { !first.tags.contains($0) })
        let merged = Range(start: first.start, end: second.end, tags: mergedTags)
        var result = ranges
        result.replaceSubrange(index...(index + 1), with: [merged])
        return result
    }

    /// Moves the boundary between `ranges[boundaryIndex]` and
    /// `ranges[boundaryIndex + 1]` to `position`, clamped to stay strictly
    /// inside both neighbors so no range ever becomes zero-length or negative.
    public static func resize(_ ranges: [Range], boundaryIndex: Int, to position: Double) -> [Range] {
        guard ranges.indices.contains(boundaryIndex), ranges.indices.contains(boundaryIndex + 1) else {
            return ranges
        }
        var result = ranges
        let lowerBound = result[boundaryIndex].start.nextUp
        let upperBound = result[boundaryIndex + 1].end.nextDown
        guard lowerBound < upperBound else { return ranges }
        let clamped = min(max(position, lowerBound), upperBound)
        result[boundaryIndex].end = clamped
        result[boundaryIndex + 1].start = clamped
        return result
    }

    /// True if `ranges` tile [0, total) exactly: sorted, contiguous, no gaps
    /// or overlaps, and every range has positive length.
    public static func validate(_ ranges: [Range], total: Double) -> Bool {
        guard !ranges.isEmpty else { return total == 0 }
        guard ranges[0].start == 0, ranges[ranges.count - 1].end == total else { return false }
        for range in ranges where range.start >= range.end {
            return false
        }
        for i in 1..<ranges.count where ranges[i].start != ranges[i - 1].end {
            return false
        }
        return true
    }
}
