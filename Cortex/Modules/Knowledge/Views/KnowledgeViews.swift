import SwiftUI
import CortexCore

/// The `?` scope: projects, items and capture rows, and the selected one's
/// Markdown with its code blocks.
struct KnowledgeView: View {
    let scope: KnowledgeScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: PaletteEmptyState(
                    title: "Nothing here yet",
                    systemImage: "books.vertical",
                    description: "Type a title and press ⏎ to save a note, or import from Outline in Settings."),
                onActivate: { scope.choose($0) }
            ) { row, _, isSelected in
                KnowledgeRowView(row: row, project: { scope.project($0) ?? KnowledgeProject(id: $0) }, isSelected: isSelected)
            }
        } preview: {
            KnowledgePreviewView(row: scope.list.selected, blocks: scope.codeBlocks, project: { scope.project($0) })
        }
    }
}

struct KnowledgeRowView: View {
    let row: KnowledgeRow
    let project: (String) -> KnowledgeProject
    let isSelected: Bool

    var body: some View {
        switch row {
        case .project(let project, let count):
            PaletteRow(
                symbol: project.displaySymbol, title: project.name,
                subtitle: project.summary ?? (count == 1 ? "1 item" : "\(count) items"),
                badge: "@\(project.id)", shortcutNumber: nil, isSelected: isSelected, symbolTint: project.tintColor)
        case .item(let hit):
            PaletteRow(
                symbol: Self.symbol(for: hit.item), title: hit.item.title,
                subtitle: subtitle(hit), badge: "@\(hit.item.project)",
                tag: hit.item.kind == .project ? nil : TintedTag(project: project(hit.item.project)),
                shortcutNumber: nil, isSelected: isSelected,
                symbolTint: hit.item.kind == .project ? project(hit.item.project).tintColor : nil)
        case .capture(let capture):
            PaletteRow(
                symbol: capture.isSensitive ? "exclamationmark.lock" : capture.fromClipboard ? "doc.on.clipboard" : "square.and.pencil",
                title: capture.fromClipboard ? "Save clipboard as note “\(capture.title)”" : "Save as note “\(capture.title)”",
                subtitle: captureSubtitle(capture),
                tag: TintedTag(project: project(capture.project)), shortcutNumber: nil, isSelected: isSelected)
        case .newProject(let project):
            PaletteRow(
                symbol: "folder.badge.plus", title: "New project “\(project.name)”",
                subtitle: "Creates the folder \(project.id)/ with a README", badge: "@\(project.id)",
                shortcutNumber: nil, isSelected: isSelected)
        }
    }

    static func symbol(for item: KnowledgeItem) -> String {
        switch item.kind {
        case .note: "doc.text"
        case .skill: "wand.and.sparkles"
        case .todo: item.status == .done ? "checkmark.circle" : "circle"
        case .project: "folder"
        }
    }

    private func subtitle(_ hit: KnowledgeHit) -> String {
        if let snippet = hit.snippet, !snippet.isEmpty { return snippet }
        if let summary = hit.item.summary, !summary.isEmpty { return summary }
        let firstLine = PaletteRow.firstLine(of: hit.item.body)
        return firstLine.isEmpty ? hit.item.updated.formatted(.relative(presentation: .named)) : firstLine
    }

    private func captureSubtitle(_ capture: KnowledgeCapture) -> String {
        if capture.isSensitive { return "Looks like a password or key" }
        let tags = capture.tags.map { "#\($0)" }.joined(separator: " ")
        let body = capture.fromClipboard ? PaletteRow.firstLine(of: capture.body) : "An empty note"
        return tags.isEmpty ? body : "\(tags) · \(body)"
    }
}

/// The selected row: an item's Markdown and code blocks, a project's
/// summary and README, or what a capture will write.
struct KnowledgePreviewView: View {
    let row: KnowledgeRow?
    let blocks: [KnowledgeMarkdown.CodeBlock]
    let project: (String) -> KnowledgeProject?

    var body: some View {
        switch row {
        case .item(let hit) where hit.item.kind != .project:
            VStack(alignment: .leading, spacing: 0) {
                header(hit.item)
                Divider()
                TextPreview(text: hit.item.body.trimmingCharacters(in: .whitespacesAndNewlines))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if !blocks.isEmpty {
                    Divider()
                    codeBlockList
                }
            }
        case .item(let hit):
            projectPreview(project(hit.item.project) ?? KnowledgeProject(id: hit.item.project))
        case .project(let project, _):
            projectPreview(project)
        case .capture(let capture):
            VStack(alignment: .leading, spacing: 8) {
                Text(capture.title).font(.headline)
                Text(KnowledgeFolder.notePath(project: capture.project, title: capture.title, date: .now))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Divider()
                TextPreview(text: capture.body)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
        case .newProject(let project):
            VStack(alignment: .leading, spacing: 8) {
                Label(project.name, systemImage: "folder.badge.plus").font(.headline)
                Text("\(project.id)/README.md")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                Divider()
                Text("⏎ creates the project. Then `?@\(project.id)` and `!… @\(project.id)` put notes and to-dos into it, and it is offered in the editor and to $note and $todo. Its README can hold a summary, a symbol, a colour and the folders it belongs to; Settings → Projects edits them.")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .padding(.top, 16)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        case nil:
            Color.clear
        }
    }

    private func header(_ item: KnowledgeItem) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.title).font(.headline).lineLimit(2)
            HStack(spacing: 6) {
                Text(item.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                if !item.tags.isEmpty {
                    Text(item.tags.map { "#\($0)" }.joined(separator: " ")).font(.caption)
                }
                Spacer(minLength: 0)
                Text(item.updated.formatted(.relative(presentation: .named))).font(.caption)
            }
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// ⌘1–9 paste these.
    private var codeBlockList: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(blocks.prefix(9).enumerated()), id: \.offset) { index, block in
                HStack(spacing: 8) {
                    Text("⌘\(index + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(PaletteRow.firstLine(of: block.code))
                        .font(.caption.monospaced())
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if !block.language.isEmpty {
                        Text(block.language).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func projectPreview(_ project: KnowledgeProject) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(project.name)
            } icon: {
                Image(systemName: project.displaySymbol).foregroundStyle(project.tintColor)
            }
            .font(.headline)
            if let summary = project.summary {
                Text(summary).foregroundStyle(.secondary)
            }
            if !project.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Divider()
                TextPreview(text: project.about.trimmingCharacters(in: .whitespacesAndNewlines))
            } else {
                Spacer(minLength: 0)
            }
        }
        .padding(.top, 16)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// A question over the list: delete this, save that anyway.
struct KnowledgeConfirmView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
