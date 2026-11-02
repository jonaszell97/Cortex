import SwiftUI
import CortexCore

/// The snippet editor: the searchable list in the sidebar, the selected
/// snippet on the right with its name as the title, keyword and tags as
/// chips, and one text area that switches between the text and a preview
/// of its placeholders.
struct SnippetEditorView: View {
    @Bindable var model: SnippetEditorModel
    @State private var deleting: Snippet?
    @State private var mode = Mode.edit
    @State private var inserter = SnippetTextInserter()
    @FocusState private var nameFocused: Bool

    enum Mode: Hashable {
        case edit, preview
    }

    var body: some View {
        NavigationSplitView {
            // The column width last: after it, removing the sidebar toggle
            // drops the width and leaves the sidebar at 140 points.
            sidebar
                .toolbar(removing: .sidebarToggle)
                .searchable(text: $model.filter, placement: .sidebar, prompt: "Search")
                .navigationSplitViewColumnWidth(min: 220, ideal: 270, max: 360)
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await model.load() }
        .onChange(of: model.service.revision) { Task { await model.load() } }
        .onChange(of: model.isNew) { _, isNew in
            guard isNew else { return }
            mode = .edit
            // The field appears in this update; focus it in the next.
            Task { nameFocused = true }
        }
        .confirmationDialog(
            "Delete “\(deleting?.name ?? "")”?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { snippet in
            Button("Delete", role: .destructive) {
                guard let id = snippet.id else { return }
                Task { await model.delete(id: id) }
            }
        } message: { _ in
            Text("This cannot be undone.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        // Tags must have the selection's unwrapped type (Int64): with
        // Int64? tags no row can be selected.
        List(selection: Binding<Int64?>(
            get: { model.selectedID },
            set: { id in Task { await model.select(id: id) } }
        )) {
            ForEach(model.filtered, id: \.id) { snippet in
                SnippetEditorRow(snippet: snippet)
                    .tag(snippet.id ?? -1)
                    .contextMenu { contextMenu(snippet) }
            }
        }
        .onDeleteCommand {
            deleting = model.snippets.first { $0.id == model.selectedID }
        }
        .overlay {
            if model.snippets.isEmpty {
                ContentUnavailableView(
                    "No snippets",
                    systemImage: "text.quote",
                    description: Text("Press ⌘N, or import Raycast snippets in Settings."))
            } else if model.filtered.isEmpty {
                ContentUnavailableView.search(text: model.filter)
            }
        }
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        if model.isDirty, await !model.save() { return }
                        model.newSnippet()
                        nameFocused = true
                    }
                } label: {
                    Label("New Snippet", systemImage: "plus")
                }
                .keyboardShortcut("n")
                .help("New snippet (⌘N)")
            }
        }
    }

    @ViewBuilder
    private func contextMenu(_ snippet: Snippet) -> some View {
        if let id = snippet.id {
            Button("Duplicate") { Task { await model.duplicate(id: id) } }
            Button("Copy") { Paster.write(text: snippet.body) }
            Divider()
            Button("Delete…", role: .destructive) { deleting = snippet }
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detail: some View {
        if let draft = model.draft {
            VStack(spacing: 0) {
                header(draft)
                Divider()
                editorBar
                Divider()
                editor
                Divider()
                footer
            }
        } else {
            ContentUnavailableView("No snippet selected", systemImage: "text.quote")
        }
    }

    private func header(_ draft: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Name", text: draftBinding(\.name), prompt: Text("Snippet name"))
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .focused($nameFocused)
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ChipLayout(spacing: 6) {
                    keywordChip
                    ForEach(draft.tags, id: \.self) { tag in
                        tagChip(tag)
                    }
                    newTagField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if draft.id != nil {
                    Text(Self.usage(of: draft))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    private var keywordChip: some View {
        HStack(spacing: 5) {
            Image(systemName: "keyboard")
                .foregroundStyle(.secondary)
            TextField("Keyword", text: Binding(
                get: { model.draft?.keyword ?? "" },
                set: { model.draft?.keyword = $0 }),
                      prompt: Text(";sig"))
                .textFieldStyle(.plain)
                .font(.callout.monospaced())
                .fixedSize()
                .frame(minWidth: 36, alignment: .leading)
        }
        .chip()
        .help("Keyword, optional: typing it in any app expands the snippet")
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text(tag)
                .lineLimit(1)
            Button {
                model.removeTag(tag)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.semibold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Remove tag")
        }
        .chip()
    }

    /// A comma or ⏎ turns what is typed into a chip.
    private var newTagField: some View {
        HStack(spacing: 4) {
            Image(systemName: "tag")
                .foregroundStyle(.secondary)
            TextField("Tag", text: $model.newTag, prompt: Text("Add tag"))
                .textFieldStyle(.plain)
                .fixedSize()
                .frame(minWidth: 56, alignment: .leading)
                .onSubmit { model.addNewTag() }
                .onChange(of: model.newTag) { _, text in
                    if text.contains(",") { model.addNewTag() }
                }
        }
        .chip(dashed: true)
    }

    /// "Used 12 times, last 3 days ago".
    static func usage(of snippet: Snippet) -> String {
        let count = switch snippet.usageCount {
        case 0: "Not used yet"
        case 1: "Used once"
        default: "Used \(snippet.usageCount) times"
        }
        guard let lastUsed = snippet.lastUsedAt else { return count }
        return "\(count), last \(lastUsed.formatted(.relative(presentation: .named)))"
    }

    private var editorBar: some View {
        HStack {
            Picker("Show", selection: $mode) {
                Text("Edit").tag(Mode.edit)
                Text("Preview").tag(Mode.preview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Spacer()
            Menu {
                ForEach(Self.placeholderHelp, id: \.0) { syntax, meaning in
                    Button {
                        inserter.insert(syntax)
                    } label: {
                        Text(syntax)
                        Text(meaning)
                    }
                }
            } label: {
                Label("Insert Placeholder", systemImage: "curlybraces")
            }
            .fixedSize()
            .disabled(mode == .preview)
            .help("Inserts a placeholder at the cursor")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var editor: some View {
        switch mode {
        case .edit:
            SnippetTextView(text: draftBinding(\.body), inserter: inserter)
        case .preview:
            ScrollView {
                Text(model.preview())
                    .font(.body.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 17)
                    .padding(.vertical, 10)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s")
                .disabled(!model.isDirty)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func draftBinding(_ keyPath: WritableKeyPath<Snippet, String>) -> Binding<String> {
        Binding(
            get: { model.draft?[keyPath: keyPath] ?? "" },
            set: { model.draft?[keyPath: keyPath] = $0 })
    }

    /// The Insert Placeholder menu: what is inserted, and what it becomes.
    static let placeholderHelp: [(String, String)] = [
        ("{clipboard}", "Text on the clipboard"),
        ("{clipboard offset=1}", "The text clip before it"),
        ("{clipboard|plans/.*\\.md}", "The clipboard, only if it matches the regex"),
        ("{cursor}", "Where the cursor goes after pasting"),
        ("{date}", "Today, in your locale"),
        ("{time}", "The time, in your locale"),
        ("{datetime}", "Date and time, in your locale"),
        ("{day}", "The weekday"),
        ("{date:yyyy-MM-dd}", "Now, custom format"),
        ("{date format=\"yyyy-MM-dd\" offset=\"+1d\"}", "Raycast form, with an offset (m h d w M y)"),
        ("{uuid}", "A new UUID"),
        ("{name}", "Asked for before pasting"),
        (" | uppercase", "Inside the braces; also lowercase, trim, percent-encode, json-stringify"),
    ]
}

/// A list row: the name, the text's first line, and the keyword as a pill.
private struct SnippetEditorRow: View {
    let snippet: Snippet

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snippet.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text(Self.firstLine(of: snippet.body))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let keyword = snippet.keyword {
                // Shortened rather than truncated by the layout, so a short
                // keyword never takes width from the name.
                Text(keyword.count > 14 ? keyword.prefix(13) + "…" : keyword)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .fixedSize()
            }
        }
        .padding(.vertical, 3)
    }

    static func firstLine(of body: String) -> String {
        body.split(whereSeparator: \.isNewline)
            .first { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    }
}
