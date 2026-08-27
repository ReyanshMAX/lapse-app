import AVKit
import SwiftData
import SwiftUI

/// Debug-only browser over every session's clips on disk, with tap-to-play.
/// Not a product screen — the real library is Phase 5. This exists so capture
/// output can be eyeballed on device during the no-Mac period (same rationale
/// as the debug log, D-024).
struct ClipsDebugView: View {
    @Query(sort: \Session.startedAt, order: .reverse) private var sessions: [Session]

    var body: some View {
        List {
            if sessions.isEmpty {
                Text("No sessions recorded yet.")
                    .foregroundStyle(.secondary)
            }
            ForEach(sessions) { session in
                Section(header: Text(sessionHeader(session))) {
                    let clips = session.clips.sorted { $0.index < $1.index }
                    if clips.isEmpty {
                        Text("no clips").foregroundStyle(.secondary)
                    }
                    ForEach(clips) { clip in
                        clipRow(clip)
                    }
                    if !session.clips.filter(\.isFinalized).isEmpty {
                        NavigationLink {
                            ExportView(session: session)
                        } label: {
                            Label("Export this session", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .navigationTitle("Clips")
    }

    @ViewBuilder
    private func clipRow(_ clip: Clip) -> some View {
        let url = StorageLocator.url(forRelativePath: clip.relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let subtitle = "offset \(Int(clip.studyOffsetStart))s · "
            + (clip.isFinalized ? "finalized" : "unfinalized")
            + (clip.wasRecovered ? " · recovered" : "")
            + (exists ? "" : " · file missing")

        Group {
            if exists {
                NavigationLink {
                    PlaybackView(url: url)
                } label: {
                    clipLabel(clip, subtitle: subtitle)
                }
            } else {
                clipLabel(clip, subtitle: subtitle)
            }
        }
    }

    private func clipLabel(_ clip: Clip, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("clip \(clip.index) · \(clip.frameCount) frames")
                .font(.system(.body, design: .monospaced))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func sessionHeader(_ session: Session) -> String {
        let finalized = session.clips.filter(\.isFinalized).count
        let studySeconds = session.clips.filter(\.isFinalized).reduce(0.0) { $0 + $1.studyDuration }
        return "\(session.dayKey) · \(session.status.rawValue) · \(finalized) clip\(finalized == 1 ? "" : "s") · \(Int(studySeconds))s"
    }
}
