import AppKit
import SwiftUI
import CortexCore

/// Settings → Projects: every project with its colour and symbol, an editor
/// for each and one for a new project. What it saves goes into the
/// project's README (`KnowledgeFolder.saveProject`), so the files stay the
/// source of truth.
struct ProjectsSettingsView: View {
    let service: KnowledgeService

    @State private var editing: ProjectDraft?

    var body: some View {
        Form {
            Section {
                ForEach(service.projects) { project in
                    ProjectSettingsRow(project: project, count: service.counts[project.id] ?? 0) {
                        editing = ProjectDraft(project)
                    }
                }
            } header: {
                Text("Projects")
            } footer: {
                HStack {
                    Text("Kept in each project's README.md, as name, summary, symbol, color and folders.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("New Project…") {
                        var draft = ProjectDraft()
                        draft.color = ProjectColor.leastUsed(by: service.projects)
                        editing = draft
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { draft in
            ProjectEditor(draft: draft, folder: service.folder, save: { project in
                try await service.saveProject(project)
            })
        }
    }
}

private struct ProjectSettingsRow: View {
    let project: KnowledgeProject
    let count: Int
    let edit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            ProjectSymbolTile(symbol: project.displaySymbol, tint: project.tintColor, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            TintedTag(project: project)
            Button("Edit…", action: edit)
        }
        .contentShape(.rect)
        .onTapGesture(count: 2, perform: edit)
    }

    private var subtitle: String {
        let items = count == 1 ? "1 item" : "\(count) items"
        return ["@\(project.id)", items, project.summary].compactMap { $0 }.joined(separator: " · ")
    }
}

/// The symbol, white on the colour, as in the module pages' headers.
private struct ProjectSymbolTile: View {
    let symbol: String
    let tint: Color
    let size: CGFloat

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.24))
    }
}

/// What the editor changes: a project as the README will hold it.
struct ProjectDraft: Identifiable {
    /// nil for a new project.
    var existingID: String?
    var id: String { existingID ?? "new" }
    /// A new project's folder name as typed; empty takes it from the name.
    var folderName = ""
    var name = ""
    var summary = ""
    /// Empty for the default (a folder, the inbox's tray).
    var symbol = ""
    /// nil for automatic.
    var color: ProjectColor?
    var folders: [String] = []

    init() {}

    init(_ project: KnowledgeProject) {
        existingID = project.id
        name = project.name
        summary = project.summary ?? ""
        symbol = project.symbol ?? ""
        color = project.color
        folders = project.folders
    }

    var isNew: Bool { existingID == nil }

    /// The ID it is shown with: an existing one's, else the folder name as
    /// a slug, else the name's.
    var projectID: String {
        if let existingID { return existingID }
        let typed = folderName.trimmingCharacters(in: .whitespaces)
        return KnowledgeSlug.make(typed.isEmpty ? name : typed)
    }

    func project(id: String) -> KnowledgeProject {
        KnowledgeProject(
            id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            summary: summary.trimmingCharacters(in: .whitespacesAndNewlines),
            symbol: symbol.trimmingCharacters(in: .whitespaces), color: color, folders: folders)
    }

    /// A project as drawn while it is edited.
    var preview: KnowledgeProject {
        var project = project(id: projectID)
        if project.name.isEmpty { project.name = isNew ? "New project" : KnowledgeProject.defaultName(for: projectID) }
        if project.symbol?.isEmpty == true || !ProjectEditor.isSymbol(project.symbol ?? "") { project.symbol = nil }
        return project
    }
}

private struct ProjectEditor: View {
    @State var draft: ProjectDraft
    let folder: KnowledgeFolder
    let save: (KnowledgeProject) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isSaving = false
    @State private var failure: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("Server config"))
                    if draft.isNew {
                        TextField("Folder", text: $draft.folderName, prompt: Text(draft.projectID))
                    } else {
                        LabeledContent("Folder", value: "\(draft.projectID)/")
                    }
                    TextField("Summary", text: $draft.summary, prompt: Text("What it is about, in one line"))
                } footer: {
                    if let problem = idProblem {
                        Text(problem).foregroundStyle(.orange)
                    }
                }
                Section("Color") {
                    ColorSwatches(selection: $draft.color, automatic: ProjectColor.automatic(for: draft.projectID))
                }
                Section("Symbol") {
                    SymbolGrid(selection: $draft.symbol, tint: draft.preview.tintColor, fallback: draft.projectID == KnowledgeProject.inboxID ? "tray" : "folder")
                    TextField("SF Symbol", text: $draft.symbol, prompt: Text("Any SF Symbol name, like server.rack"))
                    if !draft.symbol.isEmpty, !Self.isSymbol(draft.symbol) {
                        Text("No SF Symbol is called “\(draft.symbol)”.").font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    ForEach(Array(draft.folders.enumerated()), id: \.offset) { index, path in
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button {
                                draft.folders.remove(at: index)
                            } label: {
                                Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .help("Unlink this folder")
                        }
                    }
                    Button("Add Folder…", action: addFolder)
                } header: {
                    Text("Linked folders")
                } footer: {
                    Text("An agent working inside one of these folders files into this project.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if let failure {
                    Label(failure, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.isNew ? "Create" : "Save") { Task { await commit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(16)
        }
        .frame(width: 540, height: 640)
    }

    private var header: some View {
        HStack(spacing: 12) {
            let preview = draft.preview
            ProjectSymbolTile(symbol: preview.displaySymbol, tint: preview.tintColor, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text(draft.isNew ? "New Project" : preview.name).font(.headline)
                TintedTag(project: preview)
            }
            Spacer()
        }
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 4)
    }

    /// Why a new project's folder name cannot be used.
    private var idProblem: String? {
        guard draft.isNew, !(draft.name.isEmpty && draft.folderName.isEmpty) else { return nil }
        if folder.exists(draft.projectID) || folder.projectIDs().contains(draft.projectID) {
            return "The folder \(draft.projectID)/ is taken by another project."
        }
        return nil
    }

    private var canSave: Bool {
        !isSaving && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && idProblem == nil
            && (draft.symbol.isEmpty || Self.isSymbol(draft.symbol))
    }

    private func commit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            try await save(draft.project(id: draft.projectID))
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Link"
        guard panel.runModal() == .OK else { return }
        let home = NSHomeDirectory()
        for url in panel.urls {
            var path = url.path(percentEncoded: false)
            if path.hasSuffix("/"), path.count > 1 { path.removeLast() }
            if path == home || path.hasPrefix(home + "/") { path = "~" + path.dropFirst(home.count) }
            if !draft.folders.contains(path) { draft.folders.append(path) }
        }
    }

    static func isSymbol(_ name: String) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        return !name.isEmpty && NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil
    }
}

/// Automatic, then every colour; the selected one has a ring.
private struct ColorSwatches: View {
    @Binding var selection: ProjectColor?
    let automatic: ProjectColor

    var body: some View {
        HStack(spacing: 8) {
            swatch(nil, fill: automatic.color, help: "Automatic (\(automatic.title)), picked from the folder name")
                .overlay {
                    Image(systemName: "wand.and.sparkles")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white)
                        .allowsHitTesting(false)
                }
            Divider().frame(height: 18)
            ForEach(ProjectColor.allCases, id: \.self) { color in
                swatch(color, fill: color.color, help: color.title)
            }
        }
        .padding(.vertical, 2)
    }

    private func swatch(_ color: ProjectColor?, fill: Color, help: String) -> some View {
        let isSelected = selection == color
        return Button {
            selection = color
        } label: {
            Circle()
                .fill(fill.gradient)
                .frame(width: 20, height: 20)
                .overlay { Circle().strokeBorder(.black.opacity(0.12), lineWidth: 0.5) }
                .padding(3)
                .overlay { Circle().strokeBorder(isSelected ? Color.primary.opacity(0.6) : .clear, lineWidth: 2) }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A choice of symbols that suit projects; the default first.
private struct SymbolGrid: View {
    @Binding var selection: String
    let tint: Color
    let fallback: String

    static let symbols = [
        "server.rack", "desktopcomputer", "laptopcomputer", "iphone", "terminal", "chevron.left.forwardslash.chevron.right",
        "hammer", "wrench.and.screwdriver", "gearshape", "cpu", "network", "cloud",
        "externaldrive", "lock", "key", "house", "building.2", "briefcase",
        "book", "books.vertical", "graduationcap", "pencil", "paintbrush", "paintpalette",
        "camera", "photo", "music.note", "film", "gamecontroller", "heart",
        "leaf", "globe", "airplane", "car", "cart", "creditcard",
        "chart.bar", "calendar", "person.2", "star", "flag", "lightbulb",
        "flask", "brain", "sparkles", "fork.knife", "figure.run",
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 12), alignment: .leading, spacing: 6) {
            cell("", symbol: fallback, help: "Default")
            ForEach(Self.symbols, id: \.self) { symbol in
                cell(symbol, symbol: symbol, help: symbol)
            }
        }
        .padding(.vertical, 2)
    }

    private func cell(_ value: String, symbol: String, help: String) -> some View {
        let isSelected = selection.trimmingCharacters(in: .whitespaces) == value
        return Button {
            selection = value
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .frame(width: 30, height: 26)
                .foregroundStyle(isSelected ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 6).fill(tint.gradient)
                    } else {
                        RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5))
                    }
                }
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}
