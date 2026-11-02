import AppKit
import SwiftUI
import CortexCore
import UniformTypeIdentifiers

/// The Knowledge page below its options: what is in the folder, the state
/// of the git history, agents (the MCP server and the skills links), and
/// the Outline and Trello imports.
struct KnowledgeSettingsView: View {
    let service: KnowledgeService

    var body: some View {
        Section("Knowledge base") {
            LabeledContent("Contents") {
                let items = service.counts.values.reduce(0, +)
                Text("\(items) \(items == 1 ? "item" : "items") in \(service.projects.count) \(service.projects.count == 1 ? "project" : "projects")")
            }
            if service.settings.keepHistory {
                if service.isGitAvailable == false {
                    Label("No history: git needs the Command Line Tools (xcode-select --install).", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if let problem = service.historyProblem {
                    Label("The last commit failed: \(problem)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
            Text("Each note, skill and to-do is a Markdown file, one folder per project. Edit them with any editor or agent; Cortex picks up changes within a second. In the palette, ⌘E edits one in Cortex and ⌘⏎ opens it in VS Code.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section("Agents") {
            MCPCommandRow(command: service.mcpCommand)
            if service.settings.linkSkills {
                LabeledContent("Skills in Claude Code") {
                    let linked = service.skillLinksReport?.linked.count ?? 0
                    Text(linked == 1 ? "1 linked" : "\(linked) linked")
                }
                if let problem = service.skillLinksProblem {
                    Label("Linking skills failed: \(problem)", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                } else if let conflicts = service.skillLinksReport?.conflicts, !conflicts.isEmpty {
                    Label(
                        "Not linked, the name is taken in \(service.skillLinks.skills.path(percentEncoded: false).replacing(NSHomeDirectory(), with: "~")): \(conflicts.joined(separator: ", "))",
                        systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            }
        }

        Section("Import") {
            OutlineImportRow(service: service)
            TrelloImportRow(service: service)
        }
    }
}

/// The line that adds `cortex-mcp` to Claude Code, with a copy button.
struct MCPCommandRow: View {
    let command: String

    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent {
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(command, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
            } label: {
                Text("MCP server")
                Text("Gives Claude Code (and Claude Desktop, Cursor, …) tools to search and write notes, skills and to-dos, and your skills as prompts. Works when Cortex is not running. In a terminal:")
            }
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
        }
    }
}

/// Imports Trello boards from their JSON exports, each into a project
/// named after the board.
struct TrelloImportRow: View {
    let service: KnowledgeService

    @State private var isImporting = false
    @State private var message: String?

    var body: some View {
        LabeledContent {
            HStack {
                if isImporting { ProgressView().controlSize(.small) }
                Button("Import…", action: chooseBoards)
                    .disabled(isImporting)
            }
        } label: {
            Text("Trello (JSON export)")
            Text("A board’s menu → Print, export and share → Export as JSON. Each board becomes a project, each card a to-do.")
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
    }

    private func chooseBoards() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "Choose one or more boards exported from Trello as JSON."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let urls = panel.urls
        isImporting = true
        Task {
            defer { isImporting = false }
            var lines: [String] = []
            for url in urls {
                do {
                    let board = try TrelloBoard.decode(try Data(contentsOf: url))
                    lines.append(Self.describe(try await service.importTrello(board), board: board.name))
                } catch {
                    lines.append("\(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            message = lines.joined(separator: "\n\n")
        }
    }

    static func describe(_ report: TrelloImportReport, board: String) -> String {
        var text = "“\(board)” → @\(report.project)\(report.createdProject ? " (new)" : ""): "
            + "\(report.imported) \(report.imported == 1 ? "to-do" : "to-dos")"
        if report.done > 0 { text += ", \(report.done) of them done" }
        text += "."
        if !report.skipped.isEmpty {
            text += " \(report.skipped.count) already existed and \(report.skipped.count == 1 ? "was" : "were") left as \(report.skipped.count == 1 ? "it was" : "they were")."
        }
        return text
    }
}

/// Imports an Outline export, after mapping its collections to projects.
struct OutlineImportRow: View {
    let service: KnowledgeService

    @State private var pending: PendingImport?
    @State private var isReading = false
    @State private var message: String?

    struct PendingImport: Identifiable {
        let id = UUID()
        let export: OutlineExport
        /// Removed after the import: the unpacked zip.
        let temporary: URL?
    }

    var body: some View {
        LabeledContent("Outline (Markdown export)") {
            HStack {
                if isReading { ProgressView().controlSize(.small) }
                Button("Import…", action: chooseExport)
                    .disabled(isReading)
            }
        }
        .sheet(item: $pending) { pending in
            OutlineImportSheet(export: pending.export, projects: service.projects) { mapping in
                self.pending = nil
                run(pending, mapping: mapping)
            } cancel: {
                self.pending = nil
                remove(pending.temporary)
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
    }

    private func chooseExport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip, .folder]
        panel.canChooseDirectories = true
        panel.prompt = "Choose"
        panel.message = "Choose the zip from Outline’s Settings → Export (Markdown), or the folder it unpacks to."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isReading = true
        Task {
            defer { isReading = false }
            var temporary: URL?
            do {
                var directory = url
                if url.pathExtension.lowercased() == "zip" {
                    directory = try await OutlineExport.extract(zip: url, into: FileManager.default.temporaryDirectory)
                    temporary = directory
                }
                let export = try await Task.detached { [directory] in try OutlineExport.read(directory: directory) }.value
                guard !export.collections.isEmpty else {
                    message = "\(url.lastPathComponent) has no Markdown documents."
                    remove(temporary)
                    return
                }
                pending = PendingImport(export: export, temporary: temporary)
            } catch {
                message = "Reading \(url.lastPathComponent) failed: \(error.localizedDescription)"
                remove(temporary)
            }
        }
    }

    private func run(_ pending: PendingImport, mapping: [String: OutlineImportTarget]) {
        let folder = service.folder
        Task {
            defer { remove(pending.temporary) }
            do {
                let report = try await Task.detached {
                    try OutlineImporter(folder: folder).run(pending.export, mapping: mapping)
                }.value
                await service.refreshNow()
                message = Self.describe(report)
            } catch {
                await service.refreshNow()
                message = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func remove(_ temporary: URL?) {
        guard let temporary else { return }
        try? FileManager.default.removeItem(at: temporary)
    }

    static func describe(_ report: OutlineImportReport) -> String {
        var lines = ["Imported \(report.imported) \(report.imported == 1 ? "note" : "notes") and \(report.attachments) \(report.attachments == 1 ? "attachment" : "attachments")."]
        if !report.createdProjects.isEmpty {
            lines.append("New projects: \(report.createdProjects.joined(separator: ", ")).")
        }
        if !report.skipped.isEmpty {
            lines.append("\(report.skipped.count) already existed and were left as they were:\n" + report.skipped.prefix(10).joined(separator: "\n")
                + (report.skipped.count > 10 ? "\n…" : ""))
        }
        if !report.missingAttachments.isEmpty {
            lines.append("\(report.missingAttachments.count) linked files were not in the export.")
        }
        return lines.joined(separator: "\n\n")
    }
}

/// Which project each collection goes to. Collections do not map onto
/// projects one to one, so this is made by hand.
struct OutlineImportSheet: View {
    let export: OutlineExport
    let projects: [KnowledgeProject]
    let importAction: ([String: OutlineImportTarget]) -> Void
    let cancel: () -> Void

    @State private var mapping: [String: OutlineImportTarget]

    init(
        export: OutlineExport, projects: [KnowledgeProject],
        importAction: @escaping ([String: OutlineImportTarget]) -> Void, cancel: @escaping () -> Void
    ) {
        self.export = export
        self.projects = projects
        self.importAction = importAction
        self.cancel = cancel
        _mapping = State(initialValue: Dictionary(uniqueKeysWithValues: export.collections.map {
            ($0.name, Self.suggestedTarget(for: $0.name, projects: projects))
        }))
    }

    /// The project of the same name if there is one, else a new one.
    static func suggestedTarget(for collection: String, projects: [KnowledgeProject]) -> OutlineImportTarget {
        let slug = KnowledgeSlug.make(collection)
        if let project = projects.first(where: { $0.id == slug || $0.name.caseInsensitiveCompare(collection) == .orderedSame }) {
            return .project(project.id)
        }
        return .newProject
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import from Outline")
                .font(.headline)
            Text("Choose a project for each collection. Each document becomes a note; nested documents are tagged with their parent’s name. Notes that already exist are left as they are.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            List(export.collections) { collection in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(collection.name)
                        Text(collection.documents.count == 1 ? "1 document" : "\(collection.documents.count) documents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Picker("", selection: binding(for: collection.name)) {
                        Text("New project “\(collection.name)”").tag(OutlineImportTarget.newProject)
                        Text("Inbox").tag(OutlineImportTarget.inbox)
                        Divider()
                        ForEach(projects.filter { !$0.isInbox }) { project in
                            Text(project.name).tag(OutlineImportTarget.project(project.id))
                        }
                        Divider()
                        Text("Skip").tag(OutlineImportTarget.skip)
                    }
                    .labelsHidden()
                    .frame(width: 240)
                }
            }
            .frame(minHeight: 260)

            HStack {
                Text(summary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importAction(mapping) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(documentCount == 0)
            }
        }
        .padding(20)
        .frame(width: 560, height: 480)
    }

    private var documentCount: Int {
        export.collections.filter { mapping[$0.name] != .skip }.reduce(0) { $0 + $1.documents.count }
    }

    private var summary: String {
        documentCount == 1 ? "1 document to import" : "\(documentCount) documents to import"
    }

    private func binding(for name: String) -> Binding<OutlineImportTarget> {
        Binding(get: { mapping[name] ?? .skip }, set: { mapping[name] = $0 })
    }
}
