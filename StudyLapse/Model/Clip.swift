import Foundation
import SwiftData

/// One recorded clip file. A session is a container of these (D-002): every
/// resume produces a new clip, and chunked writing (D-015) rolls a new clip
/// every ~120s of recorded time so worst-case power-failure loss is one chunk.
@Model
final class Clip {
    @Attribute(.unique) var id: UUID
    var session: Session?
    var index: Int                  // 0-based, ordering within the session
    var relativePath: String        // "sessions/<uuid>/clips/000_<uuid>.mov"
    var startedAt: Date             // wall clock
    var endedAt: Date?
    var frameCount: Int             // frames actually written
    var studyOffsetStart: Double    // study-axis seconds at this clip's frame 0
    var isFinalized: Bool           // false until AVAssetWriter.finishWriting succeeds
    var wasRecovered: Bool          // true if repaired on launch, D-015

    init(id: UUID = UUID(), session: Session? = nil, index: Int,
         relativePath: String, startedAt: Date, endedAt: Date? = nil,
         frameCount: Int = 0, studyOffsetStart: Double = 0,
         isFinalized: Bool = false, wasRecovered: Bool = false) {
        self.id = id
        self.session = session
        self.index = index
        self.relativePath = relativePath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.frameCount = frameCount
        self.studyOffsetStart = studyOffsetStart
        self.isFinalized = isFinalized
        self.wasRecovered = wasRecovered
    }

    /// Study-axis seconds this clip represents.
    var studyDuration: Double { Double(frameCount) * (session?.captureIntervalSeconds ?? 3) }
    /// Output-video seconds this clip contributes at 1x composition speed.
    var outputDuration: Double { Double(frameCount) / Double(session?.outputFrameRate ?? 30) }
}
