import Foundation
import Observation
import StudyLapseCore
import SwiftData

/// Owns voiceover take recording for the UI (docs/ARCHITECTURE.md). Takes are
/// positioned on the **output** timeline (the exported video's seconds), stored
/// as separate audio files, and mixed in at re-export — never baked into stored
/// video (D-011). See BUILD.md Phase 6.
@MainActor
@Observable
final class VoiceoverCoordinator {
    private(set) var isRecording = false
    private(set) var lastError: String?

    private let context: ModelContext
    private let session: Session
    /// The profile revision of the rendered file the user is recording over.
    /// Takes stamp against this, not the live profile — the profile may have
    /// moved since that render, which would misplace every word (advisor / see
    /// docs/DATA_MODEL.md).
    private let recordedAgainstRevision: Int
    private let makeRecorder: () -> VoiceoverRecording

    private var recorder: VoiceoverRecording?
    private var pendingStart: Double?
    private var pendingURL: URL?
    private var pendingCreatedAt: Date?

    init(context: ModelContext,
         session: Session,
         recordedAgainstRevision: Int,
         makeRecorder: @escaping () -> VoiceoverRecording = { AVAudioRecorderVoiceover() }) {
        self.context = context
        self.session = session
        self.recordedAgainstRevision = recordedAgainstRevision
        self.makeRecorder = makeRecorder
    }

    /// All takes for this session, earliest output position first.
    var takes: [VoiceoverTake] {
        session.voiceoverTakes.sorted { $0.outputStartSeconds < $1.outputStartSeconds }
    }

    private func timelineTakes() -> [VoiceoverTimeline.Take] {
        session.voiceoverTakes.map {
            VoiceoverTimeline.Take(id: $0.id, start: $0.outputStartSeconds,
                                   duration: $0.durationSeconds, createdAt: $0.createdAt)
        }
    }

    /// True when the record button must be disabled: a new recording started at
    /// `outputSeconds` would begin inside an existing take (BUILD.md Phase 6
    /// criterion 3).
    func playheadIsInsideTake(_ outputSeconds: Double) -> Bool {
        VoiceoverTimeline.isPlayheadInsideAnyTake(outputSeconds, takes: timelineTakes())
    }

    func startTake(at outputSeconds: Double) throws {
        guard !isRecording else { throw VoiceoverError.alreadyRecording }
        guard !playheadIsInsideTake(outputSeconds) else {
            throw VoiceoverError.playheadInsideExistingTake
        }

        let relativePath = "sessions/\(session.id.uuidString)/voiceovers/\(UUID().uuidString).m4a"
        let url = StorageLocator.url(forRelativePath: relativePath)
        let recorder = makeRecorder()
        do {
            try recorder.start(to: url)
        } catch {
            lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            throw error
        }
        self.recorder = recorder
        pendingStart = outputSeconds
        pendingURL = url
        pendingCreatedAt = Date()
        isRecording = true
        lastError = nil
        DebugLog.write("Voiceover", String(format: "take started at output %.2fs", outputSeconds))
    }

    /// Stop the in-flight take and persist it. Returns `nil` when nothing was
    /// recording or the take was too short to keep.
    ///
    /// Contract deviation: BUILD.md's Phase 6 surface is `stopTake() async ->
    /// VoiceoverTake` (non-optional). There is no take to return when the caller
    /// stops nothing. Same media-only / value-returning resolution as
    /// `CaptureController` (Phase 2) and `SessionExporter` (Phase 3) — logged in
    /// STATUS.md.
    @discardableResult
    func stopTake() async -> VoiceoverTake? {
        guard let recorder, let start = pendingStart, let url = pendingURL,
              let createdAt = pendingCreatedAt else { return nil }
        let duration = recorder.stop()
        self.recorder = nil
        pendingStart = nil
        pendingURL = nil
        pendingCreatedAt = nil
        isRecording = false

        guard duration > 0.05 else {
            try? FileManager.default.removeItem(at: url)
            DebugLog.write("Voiceover", "discarded a sub-50ms take")
            return nil
        }

        let take = VoiceoverTake(
            session: session,
            relativePath: StorageLocator.relativePath(for: url),
            outputStartSeconds: start,
            durationSeconds: duration,
            recordedAgainstProfileRevision: recordedAgainstRevision,
            createdAt: createdAt)
        context.insert(take)
        try? context.save()
        DebugLog.write("Voiceover", String(format: "persisted take %.2fs @ %.2fs (rev %d)",
                                            duration, start, recordedAgainstRevision))
        return take
    }

    func delete(_ take: VoiceoverTake) {
        let url = StorageLocator.url(forRelativePath: take.relativePath)
        try? FileManager.default.removeItem(at: url)
        let removedAt = take.outputStartSeconds
        context.delete(take)
        session.voiceoverTakes.removeAll { $0.id == take.id }
        try? context.save()
        DebugLog.write("Voiceover", "deleted take at \(Int(removedAt))s")
    }

    func setMuted(_ muted: Bool, for take: VoiceoverTake) {
        take.isMuted = muted
        try? context.save()
        DebugLog.write("Voiceover", "take at \(Int(take.outputStartSeconds))s muted=\(muted)")
    }

    /// Takes recorded against a now-stale profile revision. Excluded from export
    /// and surfaced in the UI as misaligned — never silently re-timed
    /// (docs/DATA_MODEL.md).
    func staleTakes(for profile: ExportProfile) -> [VoiceoverTake] {
        session.voiceoverTakes
            .filter { $0.recordedAgainstProfileRevision != profile.revision }
            .sorted { $0.outputStartSeconds < $1.outputStartSeconds }
    }

    func deleteStaleTakes(for profile: ExportProfile) {
        for take in staleTakes(for: profile) { delete(take) }
    }

    /// The take snapshots the exporter mixes in: non-muted, matching the current
    /// profile revision, overlaps resolved keep-newer. Feeds
    /// `ExportRequest.voiceoverTakes`.
    static func exportSnapshots(session: Session, profile: ExportProfile) -> [VoiceoverTakeSnapshot] {
        let eligible = session.voiceoverTakes.filter {
            !$0.isMuted && $0.recordedAgainstProfileRevision == profile.revision
        }
        let timeline = eligible.map {
            VoiceoverTimeline.Take(id: $0.id, start: $0.outputStartSeconds,
                                   duration: $0.durationSeconds, createdAt: $0.createdAt)
        }
        let keptIDs = Set(VoiceoverTimeline.resolveOverlaps(timeline).map(\.id))
        return eligible
            .filter { keptIDs.contains($0.id) }
            .sorted { $0.outputStartSeconds < $1.outputStartSeconds }
            .map {
                VoiceoverTakeSnapshot(
                    id: $0.id,
                    url: StorageLocator.url(forRelativePath: $0.relativePath),
                    outputStartSeconds: $0.outputStartSeconds,
                    durationSeconds: $0.durationSeconds,
                    createdAt: $0.createdAt)
            }
    }
}

enum VoiceoverError: LocalizedError, Equatable {
    case alreadyRecording
    case playheadInsideExistingTake
    case recorderFailedToStart
    case permissionDenied

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            return "A take is already recording."
        case .playheadInsideExistingTake:
            return "Move the playhead outside the existing takes to record here."
        case .recorderFailedToStart:
            return "Couldn't start the microphone."
        case .permissionDenied:
            return "Microphone access is off. Enable it in Settings to record a voiceover."
        }
    }
}
