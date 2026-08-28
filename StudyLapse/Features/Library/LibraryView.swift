import StudyLapseCore
import SwiftData
import SwiftUI

/// Library grid (docs/UI.md §7): finished sessions newest first, each a tile
/// with a thumbnail, date, total study time, and tag chips. Tapping opens the
/// session detail sheet. Stats hangs off the toolbar (docs/UI.md §8).
struct LibraryView: View {
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]
    @Environment(\.modelContext) private var context

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: DesignTokens.Spacing.md)]

    private var finishedSessions: [Session] {
        sessions.filter { $0.status == .ended }
    }

    var body: some View {
        Group {
            if finishedSessions.isEmpty {
                EmptyStateView(
                    systemImage: "film.stack",
                    title: "No sessions yet",
                    message: "Finished study sessions show up here.")
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: DesignTokens.Spacing.md) {
                        ForEach(finishedSessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionTile(session: session, context: context)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
        .screenBackground()
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                NavigationLink {
                    StatsView()
                } label: {
                    Label("Stats", systemImage: "chart.bar.xaxis")
                }
            }
        }
    }
}

private struct SessionTile: View {
    let session: Session
    let context: ModelContext
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
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(Color.slTextSecondary)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius))

            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.slTextPrimary)
            Text(Formatters.studyTime(totalStudySeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Color.slTextSecondary)
            if !tagNames.isEmpty {
                TagChipRow(names: tagNames, colorFor: { tagColor($0, in: context) })
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .background(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius).fill(Color.slSurface))
        .task(id: session.id) {
            thumbnail = await ThumbnailProvider.thumbnail(for: session)
        }
    }
}
