import StudyLapseCore
import SwiftData
import SwiftUI

/// Library grid (docs/UI.md §6): finished sessions newest first, each a tile
/// with a thumbnail, date, total study time, and tag chips. Tapping opens the
/// session detail sheet. Stats is its own tab (`RootTabView`). A "Merged"
/// section above the grid lists exports produced by "Merge Sessions"
/// (toolbar button, developer request 2026-09-10) — those have no owning
/// session (`ExportRecord.session == nil`, docs/DATA_MODEL.md), so they can't
/// live in any one tile and get their own strip instead.
struct LibraryView: View {
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @Query(filter: #Predicate<ExportRecord> { $0.session == nil },
           sort: \ExportRecord.createdAt, order: .reverse)
    private var mergedExports: [ExportRecord]
    @Environment(\.modelContext) private var context

    private var finishedSessions: [Session] {
        sessions.filter { $0.status == .ended }
    }

    var body: some View {
        Group {
            if finishedSessions.isEmpty && mergedExports.isEmpty {
                EmptyStateView(
                    systemImage: "film.stack",
                    title: "No sessions yet",
                    message: "Finished study sessions show up here.")
            } else {
                GeometryReader { proxy in
                    // Explicit pixel widths from measured geometry, not
                    // GridItem's own sizing — every tile gets a fixed,
                    // known-good width so its content (the thumbnail image
                    // especially) can never push it past the column, let
                    // alone the screen edge.
                    let horizontalPadding = DesignTokens.Spacing.lg
                    let spacing = DesignTokens.Spacing.md
                    let columnWidth = (proxy.size.width - horizontalPadding * 2 - spacing) / 2

                    ScrollView {
                        VStack(alignment: .leading, spacing: spacing) {
                            if !mergedExports.isEmpty {
                                mergedExportsSection
                                    .padding(.horizontal, horizontalPadding)
                            }

                            LazyVGrid(
                                columns: [
                                    GridItem(.fixed(columnWidth), spacing: spacing),
                                    GridItem(.fixed(columnWidth)),
                                ],
                                spacing: spacing
                            ) {
                                ForEach(finishedSessions) { session in
                                    NavigationLink {
                                        SessionDetailView(session: session)
                                    } label: {
                                        SessionTile(session: session, context: context, width: columnWidth)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, horizontalPadding)
                        }
                        .padding(.vertical, spacing)
                    }
                }
            }
        }
        .navigationTitle("Library")
        .screenBackground()
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                NavigationLink {
                    MergeSessionsView()
                } label: {
                    Image(systemName: "rectangle.stack.badge.plus")
                }
                .accessibilityLabel("Merge Sessions")
            }
        }
        // Stats is reached via the tab bar (RootTabView, 2026-09-08) — no
        // longer cross-linked from here.
    }

    private var mergedExportsSection: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            Text("Merged")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Color.slTextSecondary)
            ForEach(mergedExports) { export in
                MergedExportRow(export: export, context: context)
            }
        }
    }
}

private struct MergedExportRow: View {
    let export: ExportRecord
    let context: ModelContext
    @State private var confirmingDelete = false

    private var url: URL { StorageLocator.url(forRelativePath: export.relativePath) }
    private var fileExists: Bool { FileManager.default.fileExists(atPath: url.path) }
    private var sessionCount: Int { export.mergedSessionIDs?.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack {
                Text("\(sessionCount) sessions · \(export.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline)
                    .foregroundStyle(Color.slTextPrimary)
                Spacer()
                Text(String(format: "%.1fs · %.1f MB", export.durationSeconds,
                            Double(export.fileSizeBytes) / 1_000_000))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Color.slTextSecondary)
            }
            if fileExists {
                HStack(spacing: 16) {
                    NavigationLink("Preview") { PlaybackView(url: url) }
                    ShareLink("Share", item: url)
                    Button("Delete", role: .destructive) { confirmingDelete = true }
                }
                .font(.caption)
            } else {
                Text("file missing").font(.caption).foregroundStyle(Color.slTextSecondary)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
        .confirmationDialog("Delete this merged export? This can't be undone.",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                try? FileManager.default.removeItem(at: url)
                context.delete(export)
                try? context.save()
                DebugLog.write("Storage", "deleted merged export \(export.id)")
            }
        }
    }
}

private struct SessionTile: View {
    let session: Session
    let context: ModelContext
    let width: CGFloat
    @State private var thumbnail: UIImage?

    private var totalStudySeconds: Double {
        session.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration }
    }

    private var tagNames: [String] {
        Array(Set(session.tagRanges.flatMap(\.tagNames))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface2)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width, height: 150)
                        .clipped()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(Color.slTextSecondary)
                }
            }
            .frame(width: width, height: 150)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius))

            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.slTextPrimary)
                .lineLimit(1)
            Text(Formatters.studyTime(totalStudySeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.slTextSecondary)
                .lineLimit(1)
            // Fixed-height slot regardless of whether this session has tags —
            // otherwise a tagged tile is taller than an untagged one, and
            // since each tile's background sizes to its own content (not the
            // grid row), adjacent tiles in the same row end up with
            // mismatched card heights: the grid reads "offset" because the
            // shorter card's background stops short of its neighbor's.
            Group {
                if !tagNames.isEmpty {
                    TagChipRow(names: tagNames, colorFor: { tagColor($0, in: context) })
                }
            }
            .frame(width: width, height: 24, alignment: .leading)
        }
        .padding(DesignTokens.Spacing.sm)
        .frame(width: width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
        .clipped()
        .task(id: session.id) {
            thumbnail = await ThumbnailProvider.thumbnail(for: session)
        }
    }
}
