import Foundation

/// Wall-clock time as a seam, so log timestamps don't call `Date()` directly.
protocol Clock {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}
