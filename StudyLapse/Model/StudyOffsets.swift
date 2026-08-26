import Foundation

/// Recomputes the study-time axis offsets that position each clip's frame 0.
enum StudyOffsets {
    /// Recompute and persist `studyOffsetStart` for every finalized clip in
    /// `session` so the tiling invariant in docs/DATA_MODEL.md holds: clips in
    /// index order satisfy `studyOffsetStart[n] == studyOffsetStart[n-1] +
    /// studyDuration[n-1]`, with `studyOffsetStart[0] == 0`.
    ///
    /// Must be called whenever a clip is finalized, recovered, or deleted
    /// (docs/CAPTURE.md). Non-finalized clips are skipped — an in-progress
    /// clip's offset is provisionally the running total and is corrected here
    /// once it finalizes.
    @MainActor
    static func recompute(for session: Session) {
        var running = 0.0
        for clip in session.clips.filter(\.isFinalized).sorted(by: { $0.index < $1.index }) {
            clip.studyOffsetStart = running
            running += clip.studyDuration
        }
    }

    /// The study-axis offset a newly opened clip should start at: the sum of
    /// every already-finalized clip's study duration.
    @MainActor
    static func runningTotal(for session: Session) -> Double {
        session.clips.filter(\.isFinalized).reduce(0) { $0 + $1.studyDuration }
    }
}
