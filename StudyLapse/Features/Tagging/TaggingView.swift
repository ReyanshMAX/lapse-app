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
                SegmentListView(editor: editor, context: context, onEditTags: { editing = EditingTarget(index: $0) })
            case .slider:
                TagSliderView(editor: editor, context: context, onEditTags: { editing = EditingTarget(index: $0) })
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
        .screenBackground()
    }
}

// MARK: - Segment list (default)

private struct SegmentListView: View {
    @Bindable var editor: TagEditor
    let context: ModelContext
    let onEditTags: (Int) -> Void

    var body: some View {
        List {
            ForEach(Array(editor.ranges.enumerated()), id: \.offset) { index, range in
                Button {
                    onEditTags(index)
                } label: {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack {
                            Text("\(Formatters.minutesSeconds(range.start)) – \(Formatters.minutesSeconds(range.end))")
                                .font(.system(.subheadline, design: .monospaced))
                                .foregroundStyle(Color.slTextPrimary)
                            Spacer()
                            Text(Formatters.studyTime(range.end - range.start))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.slTextSecondary)
                        }
                        if range.tags.isEmpty {
                            Text("Untagged").font(.callout).foregroundStyle(Color.slTextSecondary)
                        } else {
                            TagChipRow(names: range.tags, colorFor: { tagColor($0, in: context) })
                        }
                    }
                    .padding(.vertical, DesignTokens.Spacing.xs)
                }
                .listRowBackground(Color.slSurface)
                .swipeActions(edge: .trailing) {
                    if index < editor.ranges.count - 1 {
                        Button("Merge →") { editor.merge(at: index) }
                    }
                }
            }
        }
        .listStyle(.plain)
        .tokenizedListStyle()
    }
}

/// Looks up the persisted color for a tag name (`Tag.colorHex`, assigned from
/// `TagCatalog.palette`) so the same tag reads as the same color everywhere —
/// segment list chips, slider segments, and the Library grid. Falls back to
/// the plain accent for a name with no `Tag` row yet (mid-edit, not yet saved).
@MainActor
func tagColor(_ name: String, in context: ModelContext) -> Color {
    guard let tag = TagCatalog.existingTag(named: TagCatalog.normalize(name), in: context) else {
        return .slAccent
    }
    return Color(hex: tag.colorHex)
}
