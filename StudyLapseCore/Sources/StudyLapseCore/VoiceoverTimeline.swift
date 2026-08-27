import Foundation

/// Pure interval math over voiceover takes on the **output** timeline (the
/// exported video's seconds, not the study axis — the user records takes while
/// watching the finished cut). See docs/EXPORT.md "Voiceover mixing" and
/// BUILD.md Phase 6.
///
/// Foundation only — no CoreMedia. The exporter converts these `Double` seconds
/// to `CMTime` at the AVFoundation boundary.
public enum VoiceoverTimeline {
    /// Linear fade applied at each take's edges so mixing produces no click
    /// (docs/EXPORT.md: "a 50 ms linear fade in and out at each take's edges").
    public static let fadeSeconds: Double = 0.05

    /// A take reduced to what the timeline math needs. Mirrors
    /// `TagRangeMath.Range` — a value type the app maps its `@Model` rows onto.
    public struct Take: Equatable, Sendable {
        public var id: UUID
        /// Position of the take's first sample on the output timeline.
        public var start: Double
        public var duration: Double
        /// Tiebreaker for `resolveOverlaps` — the newer take wins.
        public var createdAt: Date

        public init(id: UUID, start: Double, duration: Double, createdAt: Date) {
            self.id = id
            self.start = start
            self.duration = duration
            self.createdAt = createdAt
        }

        public var end: Double { start + duration }
    }

    /// True when `playhead` sits within any existing take, so a new recording
    /// started here would begin inside one (BUILD.md Phase 6 criterion 3 — the
    /// record button is disabled in this state). The end edge is exclusive: a
    /// playhead exactly at a take's end can start a new take.
    public static func isPlayheadInsideAnyTake(_ playhead: Double,
                                               takes: [Take],
                                               epsilon: Double = 1e-6) -> Bool {
        takes.contains { playhead >= $0.start - epsilon && playhead < $0.end - epsilon }
    }

    /// True if a take occupying `[start, start + duration)` would intersect any
    /// existing take. Touching end-to-start is allowed.
    public static func wouldOverlap(start: Double,
                                    duration: Double,
                                    existing: [Take],
                                    epsilon: Double = 1e-6) -> Bool {
        let end = start + duration
        return existing.contains { start < $0.end - epsilon && $0.start < end - epsilon }
    }

    /// Drops overlapping takes, keeping the newer (`createdAt`) of any
    /// overlapping pair. The UI prevents overlaps at creation; this is the
    /// export-time backstop (docs/EXPORT.md: "if found at export time, keep the
    /// newer take and log a deviation"). Result is sorted by `start`.
    public static func resolveOverlaps(_ takes: [Take], epsilon: Double = 1e-6) -> [Take] {
        var kept: [Take] = []
        // Newest first, so an accepted take always beats a later-considered
        // older one that overlaps it.
        for take in takes.sorted(by: { $0.createdAt > $1.createdAt }) {
            let clashes = kept.contains {
                take.start < $0.end - epsilon && $0.start < take.end - epsilon
            }
            if !clashes { kept.append(take) }
        }
        return kept.sorted { $0.start < $1.start }
    }

    /// True when `resolveOverlaps` would discard at least one take.
    public static func hasOverlaps(_ takes: [Take], epsilon: Double = 1e-6) -> Bool {
        resolveOverlaps(takes, epsilon: epsilon).count != takes.count
    }

    /// Absolute output-second positions of a take's fade ramps. For a take
    /// shorter than `2 * fadeSeconds` the in and out ramps meet at the midpoint
    /// rather than crossing, so volume never inverts.
    public struct Fade: Equatable, Sendable {
        public var inStart: Double
        public var inEnd: Double
        public var outStart: Double
        public var outEnd: Double

        public init(inStart: Double, inEnd: Double, outStart: Double, outEnd: Double) {
            self.inStart = inStart
            self.inEnd = inEnd
            self.outStart = outStart
            self.outEnd = outEnd
        }
    }

    public static func fade(start: Double,
                            duration: Double,
                            fadeSeconds: Double = fadeSeconds) -> Fade {
        let end = start + duration
        let f = min(fadeSeconds, max(duration / 2, 0))
        return Fade(inStart: start, inEnd: start + f,
                    outStart: end - f, outEnd: end)
    }
}
