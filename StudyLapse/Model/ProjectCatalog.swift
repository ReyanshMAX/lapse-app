import Foundation
import SwiftData

/// Read/write helpers for the `Project` table — `TagCatalog`'s counterpart
/// for `Session.projectName`. `useCount` is derived the same way
/// `TagCatalog.refreshUseCounts` derives `Tag.useCount`: recomputed from the
/// live `Session` rows rather than incremented, so it can't drift when a
/// session's project is changed back and forth.
enum ProjectCatalog {
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Same auto-assigned palette `TagCatalog` uses — projects and tags are
    /// both user-typed labels colored for scannability, not a second
    /// palette a project would need to be visually distinguished from a tag.
    static var palette: [String] { TagCatalog.palette }

    /// Existing projects, most-used first — the "New Project…" picker's list.
    @MainActor
    static func suggestions(in context: ModelContext, limit: Int = 20) -> [Project] {
        var descriptor = FetchDescriptor<Project>(
            sortBy: [SortDescriptor(\.useCount, order: .reverse),
                     SortDescriptor(\.lastUsedAt, order: .reverse)])
        descriptor.fetchLimit = limit
        return (try? context.fetch(descriptor)) ?? []
    }

    @MainActor
    static func existingProject(named normalizedName: String, in context: ModelContext) -> Project? {
        var descriptor = FetchDescriptor<Project>(predicate: #Predicate { $0.name == normalizedName })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Ensures a `Project` row exists for `displayName` and returns it (nil
    /// for a blank name). Does not touch `useCount` — call
    /// `refreshUseCounts` once the assignment has been persisted.
    @MainActor
    @discardableResult
    static func ensure(_ displayName: String, in context: ModelContext) -> Project? {
        let name = normalize(displayName)
        guard !name.isEmpty else { return nil }
        if let existing = existingProject(named: name, in: context) { return existing }
        let count = (try? context.fetchCount(FetchDescriptor<Project>())) ?? 0
        let project = Project(name: name,
                              displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                              colorHex: palette[count % palette.count])
        context.insert(project)
        try? context.save()
        return project
    }

    /// Recompute `useCount` (and bump `lastUsedAt` for projects still in use)
    /// from every `Session.projectName` in the store.
    @MainActor
    static func refreshUseCounts(in context: ModelContext) {
        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        var counts: [String: Int] = [:]
        for session in sessions {
            if let name = session.projectName { counts[name, default: 0] += 1 }
        }
        let projects = (try? context.fetch(FetchDescriptor<Project>())) ?? []
        for project in projects {
            let n = counts[project.name] ?? 0
            if project.useCount != n { project.useCount = n }
            if n > 0 { project.lastUsedAt = .now }
        }
        try? context.save()
    }
}
