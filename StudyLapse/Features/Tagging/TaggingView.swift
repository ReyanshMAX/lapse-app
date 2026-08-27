import StudyLapseCore
import SwiftData
import SwiftUI

/// Tagging screen (docs/UI.md §4). Two modes over the same `TagRange` data
/// (D-010): a segment list (default) and a drag slider (refine). Every boundary
/// mutation goes through `TagEditor` → `TagRangeMath`.
struct TaggingView: View {
    let session: Session
    @Environment(\.modelContext) private var context

    @State private var editor: TagEditor?
    @State private var mode: Mode = .list
    @State private var editing: EditingTarget?

    private enum Mode: String, CaseIterable { case list = "List", slider = "Slider" }
    private struct EditingTarget: Identifiable { let id = UUID(); let index: Int }

    var body: some View {
        Group {
            if let editor {
                content(editor)
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Tag your session")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if editor == nil { editor = TagEditor(session: session, context: context) }
        }
        .sheet(item: $editing) { target in
            if let editor {
                TagFieldSheet(
                    initial: editor.ranges.indices.contains(target.index) ? editor.ranges[target.index].tags : [],
                    context: context,
                    onSave: { editor.setTags($0, at: target.index) }
                )
            }
        }
    }

    @ViewBuilder
    private func content(_ editor: TagEditor) -> some View {
        VStack(spacing: 0) {
            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding()

            switch mode {
            case .list:
                SegmentListView(editor: editor, onEditTags: { editing = EditingTarget(index: $0) })
            case .slider:
                TagSliderView(editor: editor, onEditTags: { editing = EditingTarget(index: $0) })
            }

            Divider()
            NavigationLink {
                ExportView(session: session)
            } label: {
                Text("Continue to Export")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding()
        }
    }
}

// MARK: - Segment list (default)

private struct SegmentListView: View {
    @Bindable var editor: TagEditor
    let onEditTags: (Int) -> Void

    var body: some View {
        List {
            ForEach(Array(editor.ranges.enumerated()), id: \.offset) { index, range in
                Button {
                    onEditTags(index)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(Formatters.minutesSeconds(range.start)) – \(Formatters.minutesSeconds(range.end))")
                                .font(.system(.subheadline, design: .monospaced))
                            Spacer()
                            Text(Formatters.studyTime(range.end - range.start))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        if range.tags.isEmpty {
                            Text("Untagged").font(.callout).foregroundStyle(.secondary)
                        } else {
                            TagChips(names: range.tags)
                        }
                    }
                }
                .swipeActions(edge: .trailing) {
                    if index < editor.ranges.count - 1 {
                        Button("Merge →") { editor.merge(at: index) }
                    }
                }
            }
        }
        .listStyle(.plain)
    }
}

private struct TagChips: View {
    let names: [String]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(names, id: \.self) { name in
                    Text(name)
                        .font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.22)))
                }
            }
        }
    }
}
