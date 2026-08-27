import AVKit
import StudyLapseCore
import SwiftUI

/// Session detail sheet (docs/UI.md §7): clip list, exports with re-export,
/// manual source purge (D-005), and delete (rows + directory together via
/// `SessionStorage`).
struct SessionDetailView: View {
    let session: Session

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var confirmingDelete = false
    @State private var confirmingPurge = false

    private var finalizedClips: [Clip] { session.orderedFinalizedClips }
    private var exports: [ExportRecord] { session.exports.sorted { $0.createdAt > $1.createdAt } }
    private var totalStudySeconds: Double {
        finalizedClips.reduce(0) { $0 + $1.studyDuration }
    }
    private var tagNames: [String] {
        Array(Set(session.tagRanges.flatMap(\.tagNames))).sorted()
    }

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("Date", value: session.startedAt.formatted(date: .long, time: .shortened))
                LabeledContent("Day", value: session.dayKey)
                LabeledContent("Study time", value: Formatters.studyTime(totalStudySeconds))
                LabeledContent("Clips", value: "\(finalizedClips.count)")
                if !tagNames.isEmpty {
                    LabeledContent("Tags", value: tagNames.joined(separator: ", "))
                }
            }

            Section("Tag ranges") {
                NavigationLink {
                    TaggingView(session: session)
                } label: {
                    Label("Edit tags", systemImage: "tag")
                }
                ForEach(session.tagRanges.sorted { $0.startStudySeconds < $1.startStudySeconds }) { range in
                    HStack {
                        Text("\(Formatters.minutesSeconds(range.startStudySeconds)) – \(Formatters.minutesSeconds(range.endStudySeconds))")
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(range.tagNames.isEmpty ? "untagged" : range.tagNames.joined(separator: " · "))
                            .font(.caption)
                            .foregroundStyle(range.tagNames.isEmpty ? .secondary : .primary)
                    }
                }
            }

            Section("Clips") {
                if finalizedClips.isEmpty {
                    Text("No finished clips").foregroundStyle(.secondary)
                }
                ForEach(finalizedClips) { clip in
                    clipRow(clip)
                }
            }

            Section("Exports") {
                if exports.isEmpty {
                    Text("No exports yet").foregroundStyle(.secondary)
                }
                ForEach(exports) { export in
                    exportRow(export)
                }
                if session.canReExport {
                    NavigationLink {
                        ExportView(session: session)
                    } label: {
                        Label(exports.isEmpty ? "Export" : "Re-export",
                              systemImage: "square.and.arrow.up")
                    }
                    .disabled(finalizedClips.isEmpty)
                } else {
                    Label("Sources purged — re-export unavailable", systemImage: "xmark.bin")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                if session.canReExport && !finalizedClips.isEmpty {
                    Button("Purge source clips", role: .destructive) { confirmingPurge = true }
                }
                Button("Delete session", role: .destructive) { confirmingDelete = true }
            } footer: {
                Text("Purging removes the recorded source clips to reclaim storage. Existing exports keep working, but the session can no longer be re-exported.")
            }
        }
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this session? Its clips, tags, and exports are removed for good.",
                            isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete session", role: .destructive) {
                SessionStorage.deleteSession(session, in: context)
                dismiss()
            }
        }
        .confirmationDialog("Purge source clips? This can't be undone and disables re-export.",
                            isPresented: $confirmingPurge, titleVisibility: .visible) {
            Button("Purge sources", role: .destructive) {
                SessionStorage.purgeSources(session, in: context)
            }
        }
    }

    @ViewBuilder
    private func clipRow(_ clip: Clip) -> some View {
        let url = StorageLocator.url(forRelativePath: clip.relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let label = VStack(alignment: .leading, spacing: 2) {
            Text("Clip \(clip.index) · \(clip.frameCount) frames")
                .font(.system(.subheadline, design: .monospaced))
            Text("offset \(Int(clip.studyOffsetStart))s"
                 + (clip.wasRecovered ? " · recovered" : "")
                 + (exists ? "" : " · file purged"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        if exists {
            NavigationLink { PlaybackView(url: url) } label: { label }
        } else {
            label
        }
    }

    @ViewBuilder
    private func exportRow(_ export: ExportRecord) -> some View {
        let url = StorageLocator.url(forRelativePath: export.relativePath)
        let exists = FileManager.default.fileExists(atPath: url.path)
        let sizeMB = Double(export.fileSizeBytes) / 1_000_000
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(export.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline)
                Spacer()
                Text(String(format: "%.1fs · %.1f MB", export.durationSeconds, sizeMB))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            if exists {
                HStack(spacing: 16) {
                    NavigationLink("Preview") { PlaybackView(url: url) }
                    ShareLink("Share", item: url)
                    NavigationLink("Voiceover") {
                        VoiceoverView(session: session, export: export)
                    }
                }
                .font(.caption)
            } else {
                Text("file missing").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
