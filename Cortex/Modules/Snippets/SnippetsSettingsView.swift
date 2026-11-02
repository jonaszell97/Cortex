import AppKit
import SwiftUI
import CortexCore
import UniformTypeIdentifiers

/// The Snippets page in Settings: the editor, keyword expansion and the
/// Raycast import.
struct SnippetsSettingsView: View {
    @Bindable var settings: SnippetsSettings
    let snippets: SnippetsService
    let expander: KeywordExpander
    let accessibility: AccessibilityPermission
    let openEditor: () -> Void
    let requestAccessibility: () -> Void

    @State private var count: Int?

    var body: some View {
        Section("Snippets") {
            LabeledContent("Snippets") {
                HStack {
                    Text(count.map { $0.formatted() } ?? "–")
                    Button("Open Editor…", action: openEditor)
                }
            }
            Toggle("Expand keywords as you type", isOn: $settings.keywordExpansion)
            Text("Typing a snippet’s keyword in any app replaces it with the snippet, and the clipboard stays as it was. To spot keywords, Cortex keeps the last few typed characters in memory only, never on disk, and forgets them on every app switch, click or shortcut. Password fields are never seen.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if settings.keywordExpansion && !expander.isRunning {
                HStack {
                    Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Spacer()
                    Button("Grant Access…", action: requestAccessibility)
                }
            }
        }
        .task(id: snippets.revision) {
            count = await snippets.all().count
        }

        Section("Import") {
            RaycastSnippetImportRow(snippets: snippets)
        }
    }
}

/// Import and export of Raycast's snippet JSON, with a dry run first.
struct RaycastSnippetImportRow: View {
    let snippets: SnippetsService

    @State private var plan: IdentifiedPlan?
    @State private var message: String?

    struct IdentifiedPlan: Identifiable {
        let id = UUID()
        var plan: SnippetImportPlan
        var fileName: String
    }

    var body: some View {
        LabeledContent("Raycast snippets (JSON)") {
            HStack {
                Button("Import…", action: chooseFile)
                Button("Export…", action: export)
            }
        }
        .sheet(item: $plan) { identified in
            RaycastImportPreview(plan: identified.plan, fileName: identified.fileName) { replaceChanged in
                plan = nil
                apply(identified.plan, replaceChanged: replaceChanged)
            } cancel: {
                plan = nil
            }
        }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {}
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.prompt = "Preview Import"
        panel.message = "Choose the file from Raycast’s “Export Snippets” command."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                plan = IdentifiedPlan(plan: try await snippets.planRaycastImport(from: url), fileName: url.lastPathComponent)
            } catch {
                message = "Reading \(url.lastPathComponent) failed: \(error.localizedDescription)"
            }
        }
    }

    private func apply(_ plan: SnippetImportPlan, replaceChanged: Bool) {
        Task {
            do {
                let report = try await snippets.applyImport(plan, replaceChanged: replaceChanged)
                message = """
                    Added \(report.added), replaced \(report.replaced). \
                    \(report.unchanged) were unchanged, \(report.skipped) skipped.
                    """
            } catch {
                message = "Import failed: \(error.localizedDescription)"
            }
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Snippets.json"
        panel.message = "Snippets often hold addresses and signatures. Keep the file off cloud drives and mail."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let count = try await snippets.exportRaycast(to: url)
                message = "Exported \(count) snippets to \(url.lastPathComponent)."
            } catch {
                message = "Export failed: \(error.localizedDescription)"
            }
        }
    }
}

/// The dry run: what each entry of the file would do.
private struct RaycastImportPreview: View {
    let plan: SnippetImportPlan
    let fileName: String
    let importAction: (Bool) -> Void
    let cancel: () -> Void

    @State private var replaceChanged = true

    init(plan: SnippetImportPlan, fileName: String, importAction: @escaping (Bool) -> Void, cancel: @escaping () -> Void) {
        self.plan = plan
        self.fileName = fileName
        self.importAction = importAction
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import \(fileName)")
                .font(.headline)
            Text(summary)
                .foregroundStyle(.secondary)

            List(plan.entries) { entry in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.snippet.name.isEmpty ? "(no name)" : entry.snippet.name)
                        ForEach(entry.notes, id: \.self) { note in
                            Text(note).font(.caption).foregroundStyle(.orange)
                        }
                    }
                    Spacer()
                    if let keyword = entry.keyword {
                        Text(keyword).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                    Text(label(entry.action))
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(color(entry.action).opacity(0.2), in: .capsule)
                }
            }
            .frame(minHeight: 260)

            if plan.replaceCount > 0 {
                Toggle("Replace the \(plan.replaceCount) snippets that changed", isOn: $replaceChanged)
                Text("Their name, tags and usage count stay; text and keyword come from the file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button("Import") { importAction(replaceChanged) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(plan.addCount == 0 && (plan.replaceCount == 0 || !replaceChanged))
            }
        }
        .padding(20)
        .frame(width: 520, height: 520)
    }

    private var summary: String {
        var parts = ["\(plan.addCount) new"]
        if plan.replaceCount > 0 { parts.append("\(plan.replaceCount) changed") }
        if plan.unchangedCount > 0 { parts.append("\(plan.unchangedCount) unchanged") }
        if plan.skippedCount > 0 { parts.append("\(plan.skippedCount) skipped") }
        return parts.joined(separator: ", ") + ". Nothing is changed until you import."
    }

    private func label(_ action: SnippetImportPlan.Action) -> String {
        switch action {
        case .add: "New"
        case .replace: "Changed"
        case .unchanged: "Unchanged"
        case .duplicateInFile: "Duplicate"
        case .invalid(let reason): reason
        }
    }

    private func color(_ action: SnippetImportPlan.Action) -> Color {
        switch action {
        case .add: .green
        case .replace: .orange
        case .unchanged: .secondary
        case .duplicateInFile, .invalid: .red
        }
    }
}
