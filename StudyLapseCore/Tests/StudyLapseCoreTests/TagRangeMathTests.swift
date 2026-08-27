import XCTest
@testable import StudyLapseCore

/// Deterministic PRNG so property-test failures reproduce from the seed alone.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return state
    }
}

final class TagRangeMathTests: XCTestCase {
    typealias Range = TagRangeMath.Range

    func testSeedTilesClipDurations() {
        let ranges = TagRangeMath.seed(fromClipDurations: [120, 300, 60])
        XCTAssertEqual(ranges, [
            Range(start: 0, end: 120, tags: []),
            Range(start: 120, end: 420, tags: []),
            Range(start: 420, end: 480, tags: [])
        ])
        XCTAssertTrue(TagRangeMath.validate(ranges, total: 480))
    }

    func testSplitAtBoundaryIsNoOp() {
        let ranges = TagRangeMath.seed(fromClipDurations: [120, 300])
        let result = TagRangeMath.split(ranges, at: 120)
        XCTAssertEqual(result, ranges)
    }

    func testSplitInsideRangeProducesTwoRanges() {
        let ranges = TagRangeMath.seed(fromClipDurations: [120])
        let result = TagRangeMath.split(ranges, at: 50)
        XCTAssertEqual(result, [
            Range(start: 0, end: 50, tags: []),
            Range(start: 50, end: 120, tags: [])
        ])
    }

    func testResizeNeverProducesZeroLengthOrNegativeRange() {
        var ranges = TagRangeMath.seed(fromClipDurations: [10, 10])
        ranges = TagRangeMath.resize(ranges, boundaryIndex: 0, to: 10) // requested boundary == neighbors' shared edges
        for range in ranges {
            XCTAssertGreaterThan(range.end, range.start)
        }
        ranges = TagRangeMath.resize(ranges, boundaryIndex: 0, to: -100) // wildly out of bounds
        for range in ranges {
            XCTAssertGreaterThan(range.end, range.start)
        }
    }

    /// BUILD.md Phase 4 criterion 2: resizing a boundary never yields a
    /// zero-length or negative range, under any random sequence of resizes
    /// (interleaved with splits so boundary indices and neighbour widths vary
    /// widely, including boundaries between already-narrow ranges).
    func testResizeNeverProducesDegenerateRangeOverRandomSequences() {
        var generator = SeededGenerator(seed: 0x5EED_1234)
        let total = 9 * 60 * 60.0
        for trial in 0..<50 {
            var ranges = TagRangeMath.seed(
                fromClipDurations: Array(repeating: total / 6, count: 6))
            for _ in 0..<400 {
                if Int.random(in: 0..<4, using: &generator) == 0 {
                    let position = Double.random(in: 0...total, using: &generator)
                    ranges = TagRangeMath.split(ranges, at: position)
                } else {
                    let boundaryIndex = Int.random(in: -2...(ranges.count + 1), using: &generator)
                    // Aim at both neighbours' interiors and well outside them.
                    let position = Double.random(in: -total...(2 * total), using: &generator)
                    let before = ranges
                    ranges = TagRangeMath.resize(ranges, boundaryIndex: boundaryIndex, to: position)
                    XCTAssertEqual(ranges.count, before.count,
                                   "resize must never add or drop a range (trial \(trial))")
                }
                for (i, range) in ranges.enumerated() {
                    XCTAssertGreaterThan(range.end, range.start,
                                         "range \(i) degenerate after op (trial \(trial)): \(ranges)")
                }
                XCTAssertTrue(TagRangeMath.validate(ranges, total: total),
                              "tiling broken (trial \(trial)): \(ranges)")
            }
        }
    }

    func testValidateRejectsGapsAndOverlaps() {
        let gap = [Range(start: 0, end: 10, tags: []), Range(start: 15, end: 20, tags: [])]
        XCTAssertFalse(TagRangeMath.validate(gap, total: 20))

        let overlap = [Range(start: 0, end: 10, tags: []), Range(start: 5, end: 20, tags: [])]
        XCTAssertFalse(TagRangeMath.validate(overlap, total: 20))

        let zeroLength = [Range(start: 0, end: 0, tags: []), Range(start: 0, end: 20, tags: [])]
        XCTAssertFalse(TagRangeMath.validate(zeroLength, total: 20))
    }

    /// Applies a long random sequence of split/merge/resize operations and
    /// asserts the tiling invariant holds after every single one — the
    /// property test required by BUILD.md Phase 0.
    func testTilingInvariantHoldsUnderRandomOperationSequences() {
        var generator = SeededGenerator(seed: 0xC0FFEE)
        let total = 9 * 60 * 60.0 // a 9-hour session, matching the doc's canonical example
        let clipCount = 12
        let clipDuration = total / Double(clipCount)
        var ranges = TagRangeMath.seed(fromClipDurations: Array(repeating: clipDuration, count: clipCount))
        XCTAssertTrue(TagRangeMath.validate(ranges, total: total))

        for _ in 0..<1000 {
            switch Int.random(in: 0..<3, using: &generator) {
            case 0:
                let position = Double.random(in: 0...total, using: &generator)
                ranges = TagRangeMath.split(ranges, at: position)
            case 1:
                let index = Int.random(in: -1..<(ranges.count + 1), using: &generator)
                ranges = TagRangeMath.merge(ranges, at: index)
            default:
                let boundaryIndex = Int.random(in: -1..<ranges.count, using: &generator)
                let position = Double.random(in: -total...(2 * total), using: &generator)
                ranges = TagRangeMath.resize(ranges, boundaryIndex: boundaryIndex, to: position)
            }
            XCTAssertTrue(TagRangeMath.validate(ranges, total: total),
                           "tiling invariant broken: \(ranges)")
        }
    }
}
