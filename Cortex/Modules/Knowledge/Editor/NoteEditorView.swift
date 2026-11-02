import SwiftUI
import CortexCore

/// The note editor: the item's fields above, its Markdown below. For quick
/// edits; ⌘⏎ opens the file in VS Code for long ones.
struct NoteEditorView: View {
    @Bindable var model: NoteEditorModel
    @FocusState private var bodyFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if model.path != nil {
                form
                Divider()
                TextEditor(text: $model.fields.body)
                    .font(.body.monospaced())
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .focused($bodyFocused)
                Divider()
                footer
            } else {
                ContentUnavailableView("Nothing open", systemImage: "doc.text", description: Text(model.error ?? ""))
            }
        }
        .frame(minWidth: 520, minHeight: 420)
        .onChange(of: model.service.revision) { model.folderChanged() }
        .onChange(of: model.path) { bodyFocused = true }
        .onAppear { bodyFocused = true }
        .alert("“\(model.fields.title)” changed on disk", isPresented: $model.hasConflict) {
            Button("Keep Editing", role: .cancel) {}
            Button("Overwrite") { Task { await model.overwrite() } }
            Button("Reload", role: .destructive) { model.revert() }
        } message: {
            Text("An editor, an agent or the other Mac changed the file since it was opened here. Overwrite it with these edits, or reload it and drop them?")
        }
    }

    private var form: some View {
        Form {
            TextField(model.kind == .skill || model.kind == .project ? "Name" : "Title", text: $model.fields.title)
                .font(.title3)
            if let summaryLabel = model.summaryLabel {
                TextField(summaryLabel, text: $model.fields.summary)
            }
            HStack(spacing: 16) {
                if model.canMove {
                    Picker("Project", selection: $model.fields.project) {
                        ForEach(model.projects) { project in
                            Text(project.name).tag(project.id)
                        }
                    }
                    .frame(maxWidth: 260)
                }
                TextField("Tags", text: $model.fields.tags, prompt: Text("comma-separated"))
            }
            if model.isTodo {
                HStack(spacing: 16) {
                    Toggle("Done", isOn: $model.fields.isDone)
                    Toggle("Due", isOn: Binding(
                        get: { model.fields.due != nil },
                        set: { model.dueDate = $0 ? (model.dueDate ?? .now) : nil }))
                    if model.fields.due != nil {
                        DatePicker("", selection: Binding(get: { model.dueDate ?? .now }, set: { model.dueDate = $0 }),
                                   displayedComponents: .date)
                            .labelsHidden()
                            .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                    }
                    Spacer()
                }
            }
        }
        .formStyle(.columns)
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if model.isGone {
                Label("The file was deleted meanwhile.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if let path = model.path {
                Text(path)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer()
            Button("Open in \(KnowledgeService.editorName)") { Task { await model.openInEditor() } }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.isGone)
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s")
                .disabled(!model.isDirty || model.isGone)
        }
        .font(.callout)
        .padding(12)
    }
}
