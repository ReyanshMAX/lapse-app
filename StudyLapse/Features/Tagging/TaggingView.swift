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
    /// Project assignment (developer request, 2026-09-09 — "projects"): a
    /// session-level label, unlike per-range tags, so it lives here at the
    /// top of the screen rather than in `TagFieldSheet`.
    @State private var showingNewProjectAlert = false
    @State private var newProjectDraft = ""

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
        .alert("New Project", isPresented: $showingNewProjectAlert) {
            TextField("Project name", text: $newProjectDraft)
            Button("Create") { setProject(newProjectDraft); newProjectDraft = "" }
            Button("Cancel", role: .cancel) { newProjectDraft = "" }
        }
    }

    private var currentProjectDisplayName: String {
        session.projectName.flatMap { ProjectCatalog.existingProject(named: $0, in: context)?.displayName }
            ?? "No Project"
    }

    private func setProject(_ displayName: String?) {
        guard let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            session.projectName = nil
            try? context.save()
            return
        }
        guard let project = ProjectCatalog.ensure(displayName, in: context) else { return }
        session.projectName = project.name
        ProjectCatalog.refreshUseCounts(in: context)
    }

    @ViewBuilder
    private var projectRow: some View {
        HStack {
            Text("Project").foregroundStyle(Color.slTextSecondary)
            Spacer()
            Menu {
                Button("No Project") { setProject(nil) }
                ForEach(ProjectCatalog.suggestions(in: context), id: \.name) { project in
                    Button(project.displayName) { setProject(project.displayName) }
                }
                Button("New Project…") { showingNewProjectAlert = true }
            } label: {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(currentProjectDisplayName)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2)
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, DesignTokens.Spacing.sm)
    }

    @ViewBuilder
    private func content(_ editor: TagEditor) -> some View {
        VStack(spacing: 0) {
            projectRow
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
                .swipeActions(edge: .leading) {
                    // A session now starts as a single untagged block
                    // covering the whole video (STATUS.md Deviations,
                    // 2026-09-07) rather than one block per clip, so
                    // splitting is no longer a rare refinement — it's the
                    // primary way to make more than one block at all. Split
                    // was previously Slider-only (docs/UI.md §4); this
                    // mirrors that control here so the default List mode
                    // doesn't strand the user without it.
                    Button("Split") { editor.split(at: (range.start + range.end) / 2) }
                        .tint(Color.slAccent)
                }
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
