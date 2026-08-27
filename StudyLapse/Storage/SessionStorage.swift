import Foundation
import SwiftData

/// On-disk lifecycle for a session's media directory: delete (rows + directory
/// together), manual source-clip purge (D-005), and the launch-time orphan
/// sweep. SwiftData's cascade delete does not touch files — that is this
/// type's job (docs/DATA_MODEL.md Notes).
enum SessionStorage {

    /// `StudyLapse/sessions/<uuid>/` — the root of one session's media tree.
    static func directory(for sessionID: UUID) -> URL {
        StorageLocator.url(forRelativePath: "sessions/\(sessionID.uuidString)")
    }

    /// Delete a session: its SwiftData rows (clips / tag ranges / exports /
    /// voiceovers / profile cascade) and its on-disk directory, together.
    @MainActor
    static func deleteSession(_ session: Session, in context: ModelContext) {
        let id = session.id
        let directory = directory(for: id)

        context.delete(session)
        try? context.save()

        if FileManager.default.fileExists(atPath: directory.path) {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                DebugLog.write("Storage", "delete \(id): directory removal failed: \(error)")
            }
        }
        DebugLog.write("Storage", "deleted session \(id) and its directory")
    }

    /// Manual per-session source-clip purge (D-005). Removes the files under
    /// `clips/` to reclaim storage but keeps every `Clip` row — they carry
    /// `frameCount` / `studyOffsetStart`, which every study-time total, stat,
    /// streak, and tag range depends on. Stamps `sourcesPurgedAt` so
    /// re-export is refused. Exports and voiceovers are left untouched.
    @MainActor
    static func purgeSources(_ session: Session, in context: ModelContext) {
        let clipsDirectory = directory(for: session.id)
            .appendingPathComponent("clips", isDirectory: true)
        if FileManager.default.fileExists(atPath: clipsDirectory.path) {
            do {
                try FileManager.default.removeItem(at: clipsDirectory)
            } catch {
                DebugLog.write("Storage", "purge \(session.id): clips removal failed: \(error)")
            }
        }
        session.sourcesPurgedAt = .now
        try? context.save()
        DebugLog.write("Storage", "purged source clips for session \(session.id)")
    }

    /// Launch-time sweep: a directory under `sessions/` whose name is a UUID
    /// with no matching `Session` row is orphaned — a delete that removed rows
    /// but not files, or a crash mid-write — so remove it. Names that don't
    /// parse as a UUID, and anything outside `sessions/`, are left strictly
    /// alone (this runs on every launch and deletes user data).
    @MainActor
    @discardableResult
    static func sweepOrphanedDirectories(in context: ModelContext) -> [String] {
        let sessionsRoot = StorageLocator.url(forRelativePath: "sessions")
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]) else { return [] }

        let knownIDs = Set(((try? context.fetch(FetchDescriptor<Session>())) ?? []).map(\.id))

        var removed: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard let id = UUID(uuidString: name), !knownIDs.contains(id) else { continue }
            do {
                try FileManager.default.removeItem(at: entry)
                removed.append(name)
                DebugLog.write("Storage", "swept orphaned session directory \(name)")
            } catch {
                DebugLog.write("Storage", "sweep: failed to remove \(name): \(error)")
            }
        }
        if !removed.isEmpty {
            DebugLog.write("Storage", "orphan sweep removed \(removed.count) director\(removed.count == 1 ? "y" : "ies")")
        }
        return removed
    }
}
