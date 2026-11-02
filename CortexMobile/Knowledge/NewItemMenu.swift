import SwiftUI
import CortexCore

/// The compose button in the knowledge screens' toolbars: a new note or
/// to-do in the project on screen (the inbox elsewhere), and on the project
/// list a new project.
struct NewItemMenu: View {
    var project: String?
    var offersProject = false
    @State private var creatingProject = false

    var body: some View {
        Menu("New", systemImage: "plus") {
            NewItemButtons(project: project)
            if offersProject {
                Button("New Project…", systemImage: "folder.badge.plus") { creatingProject = true }
            }
        }
        .sheet(isPresented: $creatingProject) { NewProjectView() }
    }
}

/// New Note and New To-Do, for a menu.
struct NewItemButtons: View {
    var project: String?
    @Environment(EditorPresenter.self) private var editor

    var body: some View {
        Button("New Note", systemImage: "square.and.pencil") { editor.new(.note, project: project) }
        Button("New To-Do", systemImage: "checklist") { editor.new(.todo, project: project) }
    }
}

/// A project folder with a README: its name and an optional summary. The
/// colour is the one fewest projects have, as on the Mac; the rest is
/// edited in the README or in the Mac's Settings → Projects.
private struct NewProjectView: View {
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var summary = ""
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .focused($nameFocused)
                    TextField("Summary", text: $summary, axis: .vertical)
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(.red)
                    } else if !trimmedName.isEmpty {
                        Text("A folder named “\(knowledge.folder.newProjectID(for: trimmedName))” in the knowledge folder.")
                    }
                }
            }
            .navigationTitle("New Project")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task {
                            do {
                                _ = try await knowledge.createProject(name: trimmedName, summary: summary)
                                dismiss()
                            } catch {
                                self.error = error.localizedDescription
                            }
                        }
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear { nameFocused = true }
        }
        .presentationDetents([.medium])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
