import AVFoundation
import Foundation
import SwiftData

/// Launch-time repair of clips whose writer never finished — a force-quit or
/// power failure mid-chunk (D-015, docs/CAPTURE.md). Chunked writing caps the
/// worst case at one chunk (~120s).
enum ClipRecovery {
    /// Find every `Clip` with `isFinalized == false` and either repair it from
    /// whatever the writer managed to flush, or delete the row and file if
    /// nothing usable is there. Recomputes `studyOffsetStart` for every
    /// affected session. Returns the clips that were repaired.
    @MainActor
    @discardableResult
    static func recoverUnfinalized(in context: ModelContext) async -> [Clip] {
        let allClips = (try? context.fetch(FetchDescriptor<Clip>())) ?? []
        let unfinalized = allClips.filter { !$0.isFinalized }
        guard !unfinalized.isEmpty else { return [] }

        var repaired: [Clip] = []
        var affectedSessions: [UUID: Session] = [:]

        for clip in unfinalized {
            if let session = clip.session {
                affectedSessions[session.id] = session
            }

            let url = StorageLocator.url(forRelativePath: clip.relativePath)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            let fileSize = (attributes?[.size] as? Int) ?? 0
            let fileExists = FileManager.default.fileExists(atPath: url.path)

            if !fileExists || fileSize == 0 {
                if fileExists { try? FileManager.default.removeItem(at: url) }
                context.delete(clip)
                DebugLog.write("Recovery", "clip \(clip.index): missing or zero-length, row deleted")
                continue
            }

            let asset = AVURLAsset(url: url)
            let isReadable = (try? await asset.load(.isReadable)) ?? false
            let duration = (try? await asset.load(.duration)) ?? .zero
            let seconds = duration.isNumeric ? CMTimeGetSeconds(duration) : 0

            if isReadable && seconds > 0 {
                let fps = Double(clip.session?.outputFrameRate ?? 30)
                clip.frameCount = Int(seconds * fps)   // rounded down
                clip.isFinalized = true
                clip.wasRecovered = true
                if clip.endedAt == nil { clip.endedAt = Date() }
                repaired.append(clip)
                DebugLog.write("Recovery", "clip \(clip.index): repaired to \(clip.frameCount) frames from \(seconds)s")
            } else {
                try? FileManager.default.removeItem(at: url)
                context.delete(clip)
                DebugLog.write("Recovery", "clip \(clip.index): unreadable, row and file deleted")
            }
        }

        for session in affectedSessions.values {
            StudyOffsets.recompute(for: session)
        }
        try? context.save()
        return repaired
    }

    /// Any session still marked `.recording` at launch was not actually
    /// recording — the app wasn't running. Move it to `.paused`
    /// (docs/CAPTURE.md). Returns the sessions that were demoted.
    @MainActor
    @discardableResult
    static func demoteRecordingSessions(in context: ModelContext) -> [Session] {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let recording = sessions.filter { $0.status == .recording }
        for session in recording {
            session.status = .paused
            DebugLog.write("Recovery", "session \(session.id) was .recording at launch, moved to .paused")
        }
        if !recording.isEmpty { try? context.save() }
        return recording
    }
}
