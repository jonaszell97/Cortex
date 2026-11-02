import SwiftUI
import CortexCore

/// The projects, inbox first, and search over everything (the Mac's `?`).
struct ProjectsView: View {
    @Environment(KnowledgeStore.self) private var knowledge
    @Environment(MobileSyncService.self) private var sync
    @Environment(AppNavigator.self) private var navigator
    @State private var hits: [KnowledgeHit] = []

    /// In the navigator, so a `cortex://search` link can fill it.
    private var query: String { navigator.knowledgeQuery }

    var body: some View {
        @Bindable var navigator = navigator
        List {
            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                projects
            } else {
                results
            }
        }
        .navigationTitle("Knowledge")
        .navigationDestination(for: ProjectRoute.self) { ProjectView(projectID: $0.id) }
        .navigationDestination(for: ItemRoute.self) { ItemView(path: $0.path) }
        .toolbar {
            ToolbarItem(placement: .primaryAction) { NewItemMenu(offersProject: true) }
        }
        .searchable(text: $navigator.knowledgeQuery, isPresented: $navigator.isSearchingKnowledge, prompt: "Search, @project, #tag")
        .task(id: SearchKey(query: query, revision: knowledge.revision)) {
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return hits = [] }
            // While typing: wait for a pause.
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            hits = await knowledge.search(query)
        }
        .refreshable { await sync.syncNow() }
        .overlay {
            // The inbox is always there; empty means no items.
            if knowledge.itemCount == 0, query.isEmpty {
                ContentUnavailableView(
                    "No notes yet", systemImage: "books.vertical",
                    description: Text("They appear after the first sync with your Macs."))
            }
        }
    }

    private struct SearchKey: Equatable {
        var query: String
        var revision: Int
    }

    @ViewBuilder
    private var projects: some View {
        Section {
            ForEach(knowledge.projects) { project in
                NavigationLink(value: ProjectRoute(id: project.id)) {
                    ProjectRow(
                        project: project, count: knowledge.counts[project.id] ?? 0,
                        openTodos: knowledge.openTodoCounts[project.id] ?? 0)
                }
            }
        } footer: {
            Text(sync.footerLine ?? "")
        }
    }

    @ViewBuilder
    private var results: some View {
        if hits.isEmpty {
            ContentUnavailableView.search(text: query)
        } else {
            ForEach(hits) { hit in
                NavigationLink(value: ItemRoute(path: hit.item.path)) {
                    ItemRow(item: hit.item, detail: hit.snippet, project: knowledge.project(hit.item.project).name)
                }
                .itemActions(hit.item)
            }
        }
    }
}

/// Navigation values: both are strings, so each gets a type.
struct ProjectRoute: Hashable {
    var id: String
}

struct ItemRoute: Hashable {
    var path: String
}

private struct ProjectRow: View {
    let project: KnowledgeProject
    let count: Int
    let openTodos: Int

    var body: some View {
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(project.name)
                    if let summary = project.summary, !summary.isEmpty {
                        Text(summary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            } icon: {
                Image(systemName: project.displaySymbol)
                    .foregroundStyle(project.tintColor)
            }
            Spacer()
            if openTodos > 0 {
                Text("\(openTodos) open")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.tint.opacity(0.15), in: Capsule())
            }
            Text("\(count)")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}
