import SwiftUI
import CortexCore

/// The `;` scope: the snippet list and the selected snippet's text.
struct SnippetsView: View {
    let scope: SnippetsScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: PaletteEmptyState(
                    title: scope.query.isEmpty ? "No snippets yet" : "No matching snippets",
                    systemImage: "text.quote",
                    description: scope.query.isEmpty
                        ? "Press ⌘N to write one, or import them from Raycast in Settings."
                        : "Search looks at names, keywords, tags and text."),
                onActivate: { scope.choose($0) }
            ) { snippet, shortcutNumber, isSelected in
                SnippetRowView(snippet: snippet, shortcutNumber: shortcutNumber, isSelected: isSelected)
            }
        } preview: {
            SnippetPreviewView(snippet: scope.list.selected)
        }
    }
}

struct SnippetRowView: View {
    let snippet: Snippet
    let shortcutNumber: Int?
    let isSelected: Bool

    var body: some View {
        PaletteRow(
            symbol: snippet.template.fillIns.isEmpty ? "text.quote" : "list.bullet.rectangle",
            title: snippet.name,
            subtitle: PaletteRow.firstLine(of: snippet.body),
            badge: snippet.keyword,
            shortcutNumber: shortcutNumber,
            isSelected: isSelected)
    }
}

/// The selected snippet's body as written, placeholders included.
struct SnippetPreviewView: View {
    let snippet: Snippet?

    var body: some View {
        if let snippet {
            VStack(alignment: .leading, spacing: 0) {
                TextPreview(text: snippet.body)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer(snippet)
            }
        } else {
            Color.clear
        }
    }

    private func footer(_ snippet: Snippet) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            let fillIns = snippet.template.fillIns
            if !fillIns.isEmpty {
                Text("Asks for: " + fillIns.map(\.name).joined(separator: ", "))
            }
            if !snippet.tags.isEmpty {
                Text(snippet.tags.map { "#\($0)" }.joined(separator: " "))
            }
            Text(snippet.usageCount == 1 ? "Used once" : "Used \(snippet.usageCount) times")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

/// Asks for a snippet's named fill-ins before pasting it.
struct FillInFormView: View {
    let form: FillInForm
    @FocusState private var focused: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(form.snippet.name, systemImage: "list.bullet.rectangle")
                .font(.title3.bold())
            Form {
                ForEach(form.fields) { field in
                    TextField(field.name, text: binding(for: field.name), prompt: Text(field.defaultValue ?? ""))
                        .focused($focused, equals: field.name)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = form.fields.first?.name }
    }

    private func binding(for name: String) -> Binding<String> {
        Binding(get: { form.values[name] ?? "" }, set: { form.values[name] = $0 })
    }
}
