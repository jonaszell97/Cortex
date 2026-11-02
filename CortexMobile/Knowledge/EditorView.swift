import SwiftUI
import CortexCore

/// The note editor: the front matter as fields, the body as plain Markdown.
/// The same model as the Mac's editor; there is no rich text to keep in
/// step with the file.
struct EditorView: View {
    @Environment(EditorPresenter.self) private var editor
    @Environment(KnowledgeStore.self) private var knowledge
    @State private var confirmingDiscard = false
    @FocusState private var titleFocused: Bool
    @State private var bodyFocused = false

    var body: some View {
        if let draft = editor.draft {
            NavigationStack {
                form(draft)
                    .navigationTitle(title(draft))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { toolbar(draft) }
            }
            .interactiveDismissDisabled(draft.isDirty)
            .onChange(of: editor.draft?.fields) { editor.draftChanged() }
            .onChange(of: knowledge.revision) { editor.folderChanged() }
            .onAppear {
                if draft.isNew { titleFocused = true }
            }
            .confirmationDialog("Discard your changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { editor.close() }
            }
            .alert("Save anyway?", isPresented: Bindable(editor).confirmingSensitive) {
                Button("Save") { Task { await editor.save(confirmedSensitive: true) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("It looks like a password or key. Notes and to-dos are plain files: they are kept in the git history on your Macs, synced and readable by any app.")
            }
            .alert(conflictTitle, isPresented: conflictShown) {
                conflictButtons(draft)
            } message: {
                Text(conflictMessage(draft))
            }
        }
    }

    private func title(_ draft: EditorDraft) -> String {
        switch (draft.isNew, draft.kind) {
        case (true, .todo): "New To-Do"
        case (true, _): "New Note"
        case (false, .todo): "Edit To-Do"
        case (false, .skill): "Edit Skill"
        case (false, .project): "Edit Project"
        case (false, _): "Edit Note"
        }
    }

    // MARK: - The form

    private func form(_ draft: EditorDraft) -> some View {
        @Bindable var editor = editor
        let fields = Binding { editor.draft?.fields ?? draft.fields } set: { editor.draft?.fields = $0 }
        return Form {
            Section {
                TextField(draft.kind == .skill ? "Name" : "Title", text: fields.title)
                    .font(.headline)
                    .focused($titleFocused)
                    .submitLabel(.next)
                    .onSubmit { bodyFocused = true }
                if let label = draft.summaryLabel {
                    TextField(label, text: fields.summary, axis: .vertical)
                }
            }
            Section {
                if draft.canMove {
                    Picker("Project", selection: fields.project) {
                        ForEach(knowledge.projects) { project in
                            Label(project.name, systemImage: project.displaySymbol).tag(project.id)
                        }
                    }
                }
                TextField("Tags, separated by commas", text: fields.tags)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if draft.isTodo {
                    Toggle("Done", isOn: fields.isDone)
                    Toggle("Due Date", isOn: Binding { fields.wrappedValue.due != nil } set: { on in
                        fields.wrappedValue.due = on ? FrontMatter.formatDay(.now) : nil
                    })
                    if let due = fields.wrappedValue.due {
                        // Days are written without a time zone; picked and
                        // shown in UTC so the day stays the day.
                        DatePicker("Due", selection: Binding {
                            FrontMatter.parseDate(String(due.prefix(10))) ?? .now
                        } set: {
                            fields.wrappedValue.due = FrontMatter.formatDay($0, timeZone: .utc)
                        }, displayedComponents: .date)
                        .environment(\.timeZone, .utc)
                    }
                }
            }
            Section {
                MarkdownTextEditor(text: fields.body, isFocused: $bodyFocused, minHeight: 240)
            } header: {
                Text("Markdown")
            } footer: {
                if let error = editor.error {
                    Text(error).foregroundStyle(.red)
                }
            }
        }
    }

    @ToolbarContentBuilder
    private func toolbar(_ draft: EditorDraft) -> some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") {
                if draft.isDirty { confirmingDiscard = true } else { editor.close() }
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save") { Task { await editor.save() } }
                .disabled(editor.isSaving || (draft.isNew && draft.fields.title.trimmingCharacters(in: .whitespaces).isEmpty))
        }
    }

    // MARK: - Conflicts

    private var conflictShown: Binding<Bool> {
        Binding { editor.conflict != nil } set: { if !$0 { editor.conflict = nil } }
    }

    private var conflictTitle: String {
        editor.conflict == .gone ? "It's gone" : "Changed meanwhile"
    }

    private func conflictMessage(_ draft: EditorDraft) -> String {
        switch editor.conflict {
        case .gone?:
            "It was deleted or moved on another device while you were editing. Your text can be saved as a new \(draft.isTodo ? "to-do" : "note")."
        default:
            "It changed while you were editing, most likely on a Mac. Keep yours and overwrite theirs, take theirs and drop yours, or keep both with yours as a copy."
        }
    }

    @ViewBuilder
    private func conflictButtons(_ draft: EditorDraft) -> some View {
        switch editor.conflict {
        case .gone?:
            Button("Save as New") { Task { await editor.copyMine() } }
            Button("Discard Mine", role: .destructive) { editor.takeTheirs() }
        default:
            Button("Keep Mine") { Task { await editor.keepMine() } }
            Button("Take Theirs", role: .destructive) { editor.takeTheirs() }
            Button("Copy Mine") { Task { await editor.copyMine() } }
            Button("Not Now", role: .cancel) {}
        }
    }
}

private extension TimeZone {
    static let utc = TimeZone(identifier: "UTC")!
}
