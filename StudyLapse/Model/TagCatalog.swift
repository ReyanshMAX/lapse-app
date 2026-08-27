import Foundation
import SwiftData

/// Read/write helpers for the `Tag` table: name normalisation, autocomplete
/// suggestions, colour assignment, and keeping `useCount` in sync with the
/// number of `TagRange`s that currently carry each name.
///
/// `useCount` is treated as a **derived** count, recomputed from the live
/// `TagRange` rows on every write, rather than an incrementing counter. The
/// increment semantics were never specified (docs/DATA_MODEL.md only declares
/// the field) and a derived value cannot drift when a tag is added, removed,
/// then re-added. Noted in docs/DATA_MODEL.md.
enum TagCatalog {

    /// Lowercased, whitespace-trimmed — the unique key for a `Tag` row.
    static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Auto-assigned colour palette (docs/UI.md §4: "an auto-assigned palette",
    /// no user colour picking in Phase 4). Icy-blue accent first, then warm/cool
    /// alternates that read distinctly on the dark surfaces.
    static let palette: [String] = [
        "#6FA3D9", "#E5A15C", "#7FB98B", "#C77FB4",
        "#D98F8F", "#8F8FD9", "#5FB0B0", "#B0A85F",
    ]

    /// Autocomplete candidates for a partially typed tag, most-used first.
    /// Substring match on the normalised name; an empty query returns the
    /// most-used tags outright.
    @MainActor
    static func suggestions(matching raw: String, in context: ModelContext,
                            limit: Int = 6) -> [Tag] {
        let query = normalize(raw)
        var descriptor = FetchDescriptor<Tag>(
            sortBy: [SortDescriptor(\.useCount, order: .reverse),
                     SortDescriptor(\.lastUsedAt, order: .reverse)])
        descriptor.fetchLimit = 200
        let all = (try? context.fetch(descriptor)) ?? []
        let matched = query.isEmpty ? all : all.filter { $0.name.contains(query) }
        return Array(matched.prefix(limit))
    }

    /// The existing `Tag` for a normalised name, if any.
    @MainActor
    static func existingTag(named normalizedName: String, in context: ModelContext) -> Tag? {
        var descriptor = FetchDescriptor<Tag>(predicate: #Predicate { $0.name == normalizedName })
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Ensures a `Tag` row exists for `displayName` and returns it (nil for a
    /// blank name). Does not touch `useCount` — call `refreshUseCounts` once the
    /// range edit has been persisted.
    @MainActor
    @discardableResult
    static func ensure(_ displayName: String, in context: ModelContext) -> Tag? {
        let name = normalize(displayName)
        guard !name.isEmpty else { return nil }
        if let existing = existingTag(named: name, in: context) { return existing }
        let count = (try? context.fetchCount(FetchDescriptor<Tag>())) ?? 0
        let tag = Tag(name: name,
                      displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
                      colorHex: palette[count % palette.count])
        context.insert(tag)
        return tag
    }

    /// Recompute `useCount` (and bump `lastUsedAt` for tags still in use) from
    /// every `TagRange` row in the store. Cheap — the tag table is tiny.
    @MainActor
    static func refreshUseCounts(in context: ModelContext) {
        let ranges = (try? context.fetch(FetchDescriptor<TagRange>())) ?? []
        var counts: [String: Int] = [:]
        for range in ranges {
            for name in range.tagNames { counts[name, default: 0] += 1 }
        }
        let tags = (try? context.fetch(FetchDescriptor<Tag>())) ?? []
        for tag in tags {
            let n = counts[tag.name] ?? 0
            if tag.useCount != n { tag.useCount = n }
            if n > 0 { tag.lastUsedAt = .now }
        }
        try? context.save()
    }
}
