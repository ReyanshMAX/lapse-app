import SwiftData
import SwiftUI

/// Tag field with autocomplete from the `Tag` table (docs/UI.md §4). Multi-select
/// per range; an empty result is allowed. Returns the chosen display names to
/// the caller, which routes them through `TagEditor.setTags`.
struct TagFieldSheet: View {
    let initial: [String]
    let context: ModelContext
    let onSave: ([String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var chosen: [String]
    @State private var draft: String = ""

    init(initial: [String], context: ModelContext, onSave: @escaping ([String]) -> Void) {
        self.initial = initial
        self.context = context
        self.onSave = onSave
        _chosen = State(initialValue: initial)
    }

    private var suggestions: [Tag] {
        TagCatalog.suggestions(matching: draft, in: context)
            .filter { !chosen.contains($0.name) }
    }

    private var canAddDraft: Bool {
        let n = TagCatalog.normalize(draft)
        return !n.isEmpty && !chosen.contains(n)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Tags on this segment") {
                    if chosen.isEmpty {
                        Text("Untagged").foregroundStyle(.secondary)
                    }
                    ForEach(chosen, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button(role: .destructive) {
                                chosen.removeAll { $0 == name }
                            } label: {
                                Image(systemName: "minus.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                Section("Add a tag") {
                    HStack {
                        TextField("Subject", text: $draft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .onSubmit(addDraft)
                        Button("Add", action: addDraft).disabled(!canAddDraft)
                    }
                    ForEach(suggestions, id: \.name) { tag in
                        Button {
                            chosen.append(tag.name)
                            draft = ""
                        } label: {
                            HStack {
                                Text(tag.displayName)
                                Spacer()
                                Text("\(tag.useCount)").foregroundStyle(.secondary).font(.caption)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Tags")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(chosen)
                        dismiss()
                    }
                }
            }
        }
    }

    private func addDraft() {
        guard canAddDraft else { return }
        chosen.append(TagCatalog.normalize(draft))
        draft = ""
    }
}
