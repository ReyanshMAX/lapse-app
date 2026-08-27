import StudyLapseCore
import SwiftData
import SwiftUI

/// Library grid (docs/UI.md §7): finished sessions newest first, each a tile
/// with a thumbnail, date, total study time, and tag chips. Tapping opens the
/// session detail sheet. Stats hangs off the toolbar (docs/UI.md §8).
struct LibraryView: View {
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    private var finishedSessions: [Session] {
        sessions.filter { $0.status == .ended }
    }

    var body: some View {
        Group {
            if finishedSessions.isEmpty {
                ContentUnavailableView(
                    "No sessions yet",
                    systemImage: "film.stack",
                    description: Text("Finished study sessions show up here."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(finishedSessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionTile(session: session)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding()
                }
            }
        }
        .navigationTitle("Library")
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
    @State private var thumbnail: UIImage?

    private var totalStudySeconds: Double {
        session.orderedFinalizedClips.reduce(0) { $0 + $1.studyDuration }
    }

    private var tagNames: [String] {
        Array(Set(session.tagRanges.flatMap(\.tagNames))).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(.quaternary)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "film")
                        .font(.title)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))

            Text(session.startedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.subheadline.weight(.medium))
            Text(Formatters.studyTime(totalStudySeconds))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            if !tagNames.isEmpty {
                Text(tagNames.joined(separator: " · "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .task(id: session.id) {
            thumbnail = await ThumbnailProvider.thumbnail(for: session)
        }
    }
}
