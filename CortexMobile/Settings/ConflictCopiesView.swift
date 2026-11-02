import SwiftUI
import CortexCore

/// What sync kept in `knowledge/.conflicts/`: the losing version of a
/// conflict and every file another device deleted. Read one, put it back
/// (the current file is kept there in turn), or throw it away.
struct ConflictCopiesView: View {
    @Environment(KnowledgeStore.self) private var knowledge
    @State private var copies: [KnowledgeConflictCopies.Copy] = []
    @State private var error: String?

    var body: some View {
        List {
            ForEach(copies) { copy in
                NavigationLink {
                    ConflictCopyView(copy: copy) { reload() }
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(copy.originalPath)
                            .lineLimit(2)
                        Text("Kept \(copy.kept.formatted(.relative(presentation: .named)))\(knowledge.folder.exists(copy.originalPath) ? "" : " · deleted")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", systemImage: "trash", role: .destructive) { delete(copy) }
                }
            }
        }
        .navigationTitle("Conflict Copies")
        .overlay {
            if copies.isEmpty {
                ContentUnavailableView(
                    "No conflict copies", systemImage: "doc.on.doc",
                    description: Text("When two devices change the same file, the older version is kept here. So is a file another device deleted."))
            }
        }
        .task(id: knowledge.revision) { reload() }
        .alert("Couldn't delete it", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private func reload() {
        copies = knowledge.conflictCopies.list()
    }

    private func delete(_ copy: KnowledgeConflictCopies.Copy) {
        do {
            try knowledge.conflictCopies.delete(copy)
        } catch {
            self.error = error.localizedDescription
        }
        reload()
    }
}

/// One kept version as text, with Restore.
private struct ConflictCopyView: View {
    let copy: KnowledgeConflictCopies.Copy
    let changed: () -> Void
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRestore = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            Group {
                if let image = UIImage(contentsOfFile: url.path(percentEncoded: false)) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else if let text = try? String(contentsOf: url, encoding: .utf8) {
                    Text(text)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                } else {
                    Text("This file can't be shown here.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle((copy.originalPath as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Restore") { confirmingRestore = true }
            }
        }
        .confirmationDialog("Restore this version?", isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button("Restore") {
                Task {
                    do {
                        try await knowledge.restore(copy)
                        changed()
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
            }
        } message: {
            Text(knowledge.folder.exists(copy.originalPath)
                ? "It replaces \(copy.originalPath) on all your devices. The version there now is kept here."
                : "It is put back at \(copy.originalPath) and syncs to your other devices.")
        }
        .alert("Couldn't restore it", isPresented: Binding { error != nil } set: { if !$0 { error = nil } }) {
            Button("OK") {}
        } message: {
            Text(error ?? "")
        }
    }

    private var url: URL { knowledge.conflictCopies.url(for: copy) }
}
