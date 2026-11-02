import SwiftUI
import CortexCore

/// The knowledge browser: the projects on the left; the selected project's
/// notes, to-dos or skills in the middle with a search field and + above
/// them; and the selected item on the right with its title as the heading,
/// project, status, due day and tags as chips, and one text area that
/// switches between the Markdown and a preview of it.
struct KnowledgeBrowserView: View {
    @Bindable var model: KnowledgeBrowserModel
    @State private var showsDone = false
    @State private var deleting: KnowledgeItem?
    @State private var addingTitle: String?
    @State private var mode = Mode.edit

    enum Mode: Hashable {
        case edit, preview
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 300)
        } content: {
            list
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        } detail: {
            if model.selectedPath != nil, model.editor.path == model.selectedPath {
                KnowledgeBrowserDetail(model: model, editor: model.editor, mode: $mode)
            } else if let error = model.editor.error {
                ContentUnavailableView("Cannot open it", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ContentUnavailableView("Nothing selected", systemImage: "doc.text")
            }
        }
        .frame(minWidth: 900, minHeight: 520)
        .task(id: LoadKey(projectID: model.projectID, revision: model.service.revision)) {
            await model.load()
        }
        .onChange(of: model.service.revision) { model.editor.folderChanged() }
        .alert("“\(model.editor.fields.title)” changed on disk", isPresented: Binding(get: { model.editor.hasConflict }, set: { model.editor.hasConflict = $0 })) {
            Button("Keep Editing", role: .cancel) {}
            Button("Overwrite") { Task { await model.editor.overwrite() } }
            Button("Reload", role: .destructive) { model.editor.revert() }
        } message: {
            Text("An editor, an agent or the other Mac changed the file since it was opened here. Overwrite it with these edits, or reload it and drop them?")
        }
        .confirmationDialog(
            "Move “\(deleting?.title ?? "")” to the Trash?",
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
            presenting: deleting
        ) { item in
            Button("Move to Trash", role: .destructive) { Task { await model.delete(item.path) } }
        } message: { item in
            Text(item.kind == .skill ? "The skill's folder goes with it. The history keeps it too." : "The history keeps it too.")
        }
    }

    private struct LoadKey: Hashable {
        var projectID: String?
        var revision: Int
    }

    // MARK: - Projects

    private var sidebar: some View {
        List(selection: Binding(get: { model.projectID }, set: { id in Task { await model.selectProject(id) } })) {
            ForEach(model.projects) { project in
                Label(project.name, systemImage: project.displaySymbol)
                    .listItemTint(project.tintColor)
                    .badge(model.service.counts[project.id] ?? 0)
                    .help(project.summary ?? "")
                    .tag(project.id)
            }
        }
    }

    // MARK: - Items

    private var list: some View {
        VStack(spacing: 0) {
            Picker("Kind", selection: Binding(get: { model.kind }, set: { kind in Task { await model.selectKind(kind) } })) {
                ForEach(KnowledgeBrowserModel.kinds, id: \.self) { kind in
                    Text(kind.pluralTitle).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 10)
            .padding(.top, 8)
            HStack(spacing: 6) {
                searchField
                Button {
                    addingTitle = ""
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("n")
                .disabled(model.kind == .skill || model.projectID == nil)
                .help(model.kind == .skill
                    ? "Skills are made by agents or in the palette"
                    : "New \(model.kind.title.lowercased()) in \(model.project?.name ?? "this project") (⌘N)")
                .popover(isPresented: Binding(get: { addingTitle != nil }, set: { if !$0 { addingTitle = nil } }), arrowEdge: .bottom) {
                    newItemForm
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            Divider()
            items
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search", text: $model.filter, prompt: Text("Search \(model.project?.name ?? "")"))
                .textFieldStyle(.plain)
            if !model.filter.isEmpty {
                Button {
                    model.filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear the search")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 7))
    }

    @ViewBuilder
    private var items: some View {
        let shown = model.filtered
        if model.listed.isEmpty, model.loadedProjectID == model.projectID {
            ContentUnavailableView(
                "No \(model.kind.pluralTitle.lowercased())", systemImage: Self.symbol(for: model.kind),
                description: Text(model.project.map { "\($0.name) has none yet." } ?? "Pick a project on the left."))
                .frame(maxHeight: .infinity)
        } else if shown.isEmpty, !model.filter.isEmpty {
            ContentUnavailableView.search(text: model.filter)
                .frame(maxHeight: .infinity)
        } else {
            List(selection: Binding(get: { model.selectedPath }, set: { path in Task { await model.select(path) } })) {
                if model.kind == .todo {
                    let open = shown.filter { $0.status != .done }
                    let done = shown.filter { $0.status == .done }
                    Section {
                        ForEach(open) { row($0) }
                    } header: {
                        Text("Open (\(open.count))")
                    }
                    if !done.isEmpty {
                        // A plain list draws no disclosure arrow for
                        // `Section(isExpanded:)`, so the header is the button.
                        Section {
                            if showsDone || !model.filter.isEmpty {
                                ForEach(done) { row($0) }
                            }
                        } header: {
                            Button {
                                withAnimation { showsDone.toggle() }
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "chevron.right")
                                        .rotationEffect(.degrees(showsDone || !model.filter.isEmpty ? 90 : 0))
                                    Text("Done (\(done.count))")
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } else {
                    ForEach(shown) { row($0) }
                }
            }
            .onDeleteCommand {
                deleting = model.selected
            }
        }
    }

    private func row(_ item: KnowledgeItem) -> some View {
        KnowledgeBrowserRow(item: item, setDone: { isDone in Task { await model.setDone(item.path, isDone) } })
            .tag(item.path)
            .contextMenu { contextMenu(item) }
    }

    @ViewBuilder
    private func contextMenu(_ item: KnowledgeItem) -> some View {
        if item.kind == .todo {
            Button(item.status == .done ? "Mark as Open" : "Mark as Done") {
                Task { await model.setDone(item.path, item.status != .done) }
            }
        }
        if item.kind == .note || item.kind == .todo {
            Menu("Move to") {
                ForEach(model.projects.filter { $0.id != item.project }) { project in
                    Button {
                        Task { await model.move(item.path, to: project.id) }
                    } label: {
                        Label(project.name, systemImage: project.displaySymbol)
                    }
                }
            }
        }
        Divider()
        Button("Open in \(KnowledgeService.editorName)") {
            Task {
                if item.path == model.selectedPath {
                    await model.openSelected()
                } else {
                    model.service.open(item.path)
                }
            }
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([model.service.folder.url(for: item.path)])
        }
        Button("Copy Text") {
            Paster.write(text: item.body.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { deleting = item }
    }

    private var newItemForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("New \(model.kind.title.lowercased()) in \(model.project?.name ?? "")")
                .font(.headline)
            TextField("Title", text: Binding(get: { addingTitle ?? "" }, set: { addingTitle = $0 }), prompt: Text(model.kind == .todo ? "What to do" : "Title"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 260)
                .onSubmit(createItem)
            HStack {
                Spacer()
                Button("Cancel") { addingTitle = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: createItem)
                    .keyboardShortcut(.defaultAction)
                    .disabled(addingTitle?.trimmingCharacters(in: .whitespaces).isEmpty ?? true)
            }
        }
        .padding(14)
    }

    private func createItem() {
        guard let title = addingTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty else { return }
        addingTitle = nil
        mode = .edit
        Task { await model.create(model.kind, title: title) }
    }

    static func symbol(for kind: KnowledgeKind) -> String {
        switch kind {
        case .note: "doc.text"
        case .todo: "checklist"
        case .skill: "wand.and.sparkles"
        case .project: "folder"
        }
    }
}

/// A list row: a to-do's checkbox, the title, a second line (a to-do's due
/// day and checklist, a skill's description, a note's first line), and a
/// note's date or a to-do's due day as a pill.
private struct KnowledgeBrowserRow: View {
    let item: KnowledgeItem
    let setDone: (Bool) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if item.kind == .todo {
                Button {
                    setDone(item.status != .done)
                } label: {
                    Image(systemName: item.status == .done ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(item.status == .done ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                }
                .buttonStyle(.plain)
                .help(item.status == .done ? "Reopen" : "Mark as done")
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .strikethrough(item.status == .done, color: .secondary)
                if let subtitle = KnowledgeBrowserView.subtitle(item) {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            if let pill = KnowledgeBrowserView.pill(item) {
                Text(pill.text)
                    .font(.caption)
                    .foregroundStyle(pill.isUrgent ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(pill.isUrgent ? AnyShapeStyle(.orange) : AnyShapeStyle(.quaternary), in: Capsule())
                    .fixedSize()
            }
        }
        .padding(.vertical, 3)
        .opacity(item.status == .done ? 0.6 : 1)
    }
}

extension KnowledgeBrowserView {
    /// A to-do's checklist, tags or first line; a skill's description; a
    /// note's tags or first line.
    static func subtitle(_ item: KnowledgeItem) -> String? {
        let firstLine = PaletteRow.firstLine(of: item.body)
        let tags = item.tags.map { "#\($0)" }.joined(separator: " ")
        switch item.kind {
        case .todo:
            var parts: [String] = []
            let checklist = TodoChecklist(body: item.body)
            if !checklist.isEmpty { parts.append("\(checklist.doneCount) of \(checklist.items.count) done") }
            if !tags.isEmpty { parts.append(tags) }
            if !parts.isEmpty { return parts.joined(separator: " · ") }
            // With a checklist, the first line is likely one of its items.
            return checklist.isEmpty && !firstLine.isEmpty ? firstLine : nil
        case .skill:
            return item.summary
        default:
            if !firstLine.isEmpty { return firstLine }
            return tags.isEmpty ? nil : tags
        }
    }

    /// A note's last change ("3 days ago"), an open to-do's due day
    /// (urgent from today on), a done to-do's day.
    static func pill(_ item: KnowledgeItem, now: Date = .now) -> (text: String, isUrgent: Bool)? {
        switch item.kind {
        case .note:
            return (item.updated.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)), false)
        case .todo where item.status == .done:
            let done = item.frontMatter.date("done") ?? item.updated
            return (done.formatted(.dateTime.month(.abbreviated).day()), false)
        case .todo:
            guard let due = item.due else { return nil }
            let day = String(due.prefix(10))
            let today = FrontMatter.formatDay(now)
            guard let date = FrontMatter.parseDate(day) else { return (due, false) }
            var style = Date.FormatStyle(timeZone: TimeZone(identifier: "UTC")!).month(.abbreviated).day()
            if day.prefix(4) != today.prefix(4) { style = style.year() }
            let text = day == today ? "Today" : date.formatted(style)
            return (text, day <= today)
        default:
            return nil
        }
    }
}

/// The selected item: its title as the heading; project, status, due day
/// and tags as chips; one text area for the Markdown or its preview; and
/// Revert and Save below it.
struct KnowledgeBrowserDetail: View {
    @Bindable var model: KnowledgeBrowserModel
    @Bindable var editor: NoteEditorModel
    @Binding var mode: KnowledgeBrowserView.Mode
    @State private var showsInfo = false
    @State private var choosingDue = false

    /// Front matter keys shown in their own rows or fields.
    static let shownKeys: Set<String> = ["title", "name", "tags", "status", "due", "done", "created", "updated"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            editorBar
            Divider()
            text
            Divider()
            footer
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(editor.kind == .skill ? "Name" : "Title", text: $editor.fields.title, prompt: Text(editor.kind == .skill ? "skill-name" : "Title"))
                .textFieldStyle(.plain)
                .font(.title.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            if let summaryLabel = editor.summaryLabel {
                TextField(summaryLabel, text: $editor.fields.summary, prompt: Text(summaryLabel), axis: .vertical)
                    .textFieldStyle(.plain)
                    .foregroundStyle(.secondary)
                    .lineLimit(1...3)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                ChipLayout(spacing: 6) {
                    projectChip
                    if editor.isTodo {
                        statusChip
                        dueChip
                    }
                    ForEach(model.tags, id: \.self) { tag in
                        tagChip(tag)
                    }
                    newTagField
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let item = model.selected {
                    Button {
                        showsInfo.toggle()
                    } label: {
                        Text("Updated \(item.updated.formatted(.relative(presentation: .named)))")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                    .help("Path, dates and other front matter")
                    .popover(isPresented: $showsInfo, arrowEdge: .bottom) {
                        info(item)
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private var projectChip: some View {
        let project = model.projects.first { $0.id == editor.fields.project } ?? KnowledgeProject(id: editor.fields.project)
        if editor.canMove {
            Menu {
                ForEach(model.projects) { other in
                    Button {
                        Task { await model.move(to: other.id) }
                    } label: {
                        Label(other.name, systemImage: other.displaySymbol)
                    }
                    .disabled(other.id == project.id)
                }
            } label: {
                HStack(spacing: 3) {
                    TintedTag(project: project)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(editor.isGone)
            .help("Moves it to another project at once, with any other edits")
        } else {
            TintedTag(project: project)
                .help("A skill stays in the project its folder is in")
        }
    }

    private var statusChip: some View {
        Button {
            editor.fields.isDone.toggle()
        } label: {
            Label(editor.fields.isDone ? "Done" : "Open", systemImage: editor.fields.isDone ? "checkmark.circle.fill" : "circle")
                .chip()
        }
        .buttonStyle(.plain)
        .help(editor.fields.isDone ? "Reopen it" : "Mark it as done")
    }

    /// "Due today" (orange from today on), a calendar in a popover to
    /// change it; dashed when there is none.
    private var dueChip: some View {
        let due = editor.fields.due.flatMap { $0.isEmpty ? nil : $0 }
        let isUrgent = due.map { String($0.prefix(10)) <= FrontMatter.formatDay(.now) } ?? false
        return Button {
            if due == nil { editor.fields.due = FrontMatter.formatDay(.now) }
            choosingDue = true
        } label: {
            Label(due.map(TodoRowView.dueText) ?? "Due day", systemImage: "calendar")
                .foregroundStyle(due == nil ? AnyShapeStyle(.secondary) : isUrgent && !editor.fields.isDone ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
                .chip(dashed: due == nil)
        }
        .buttonStyle(.plain)
        .help(due == nil ? "Give it a due day" : "Change the due day")
        .popover(isPresented: $choosingDue, arrowEdge: .bottom) {
            VStack(spacing: 8) {
                DatePicker("Due", selection: Binding(get: { editor.dueDate ?? .now }, set: { editor.dueDate = $0 }), displayedComponents: .date)
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .environment(\.timeZone, TimeZone(identifier: "UTC")!)
                Button("Remove Due Day") {
                    editor.fields.due = nil
                    choosingDue = false
                }
                .disabled(editor.fields.due == nil)
            }
            .padding(12)
        }
    }

    private func tagChip(_ tag: String) -> some View {
        HStack(spacing: 4) {
            Text("#" + tag)
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

    private func info(_ item: KnowledgeItem) -> some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
            GridRow {
                label("Path")
                Text(item.path)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
            }
            ForEach(Array(Self.metadataRows(item, projectName: model.projectName(item.project), showsProject: false).enumerated()), id: \.offset) { _, row in
                GridRow {
                    label(row.label)
                    Text(row.value)
                        .textSelection(.enabled)
                }
            }
        }
        .font(.callout)
        .frame(maxWidth: 420, alignment: .leading)
        .padding(14)
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    // MARK: - Text

    private var editorBar: some View {
        HStack(spacing: 12) {
            Picker("Show", selection: $mode) {
                Text("Edit").tag(KnowledgeBrowserView.Mode.edit)
                Text("Preview").tag(KnowledgeBrowserView.Mode.preview)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            if editor.isTodo, !checklist.isEmpty {
                Text("\(checklist.doneCount) of \(checklist.items.count) done")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await model.openSelected() }
            } label: {
                Label("Open in \(KnowledgeService.editorName)", systemImage: "arrow.up.forward.app")
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(editor.isGone)
            .help("Saves, then opens the file in \(KnowledgeService.editorName) (⌘O)")
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var checklist: TodoChecklist {
        TodoChecklist(body: editor.fields.body)
    }

    @ViewBuilder
    private var text: some View {
        switch mode {
        case .edit:
            TextEditor(text: $editor.fields.body)
                .font(.body.monospaced())
                .scrollContentBackground(.hidden)
                .padding(.horizontal, 15)
                .padding(.vertical, 10)
        case .preview:
            let body = editor.fields.body
            let blocks = MarkdownBlock.parse(body)
            ScrollView {
                if blocks.isEmpty {
                    Text("Nothing written yet.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(20)
                } else {
                    MarkdownView(
                        blocks: blocks, resolveFile: model.linkedFile,
                        checklistIndices: MarkdownBlock.checklistIndices(of: blocks, body: body),
                        toggleChecklistItem: { index in
                            editor.fields.body = TodoChecklist.toggling(itemAt: index, in: editor.fields.body)
                        })
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                }
            }
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let error = editor.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(2)
            } else if editor.isGone {
                Label("The file was deleted meanwhile.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if model.isDirty {
                Text("Edited. Showing another item saves too.")
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Revert") {
                model.newTag = ""
                editor.revert()
            }
            .disabled(!model.isDirty)
            Button("Save") { Task { await model.save() } }
                .keyboardShortcut("s")
                .disabled(!model.isDirty || editor.isGone)
        }
        .font(.callout)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// Project (unless a chip shows it), status and due day (to-dos),
    /// dates, then every other front matter key as written. Title, tags and
    /// a skill's description are fields of their own.
    static func metadataRows(_ item: KnowledgeItem, projectName: String, showsProject: Bool = true) -> [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = showsProject ? [("Project", projectName)] : []
        if item.kind == .todo {
            if item.status == .done {
                let done = item.frontMatter.date("done").map { " " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
                rows.append(("Status", "Done" + done))
            } else {
                rows.append(("Status", "Open"))
            }
            if let due = item.due { rows.append(("Due", TodoRowView.dueText(due))) }
            let checklist = TodoChecklist(body: item.body)
            if !checklist.isEmpty { rows.append(("Checklist", "\(checklist.doneCount) of \(checklist.items.count) done")) }
        }
        if let created = item.created { rows.append(("Created", created.formatted(date: .abbreviated, time: .shortened))) }
        rows.append(("Updated", item.updated.formatted(date: .abbreviated, time: .shortened)))
        var hidden = shownKeys
        if item.kind == .skill { hidden.insert("description") }
        for entry in item.frontMatter.entries where !hidden.contains(entry.key) {
            let value = switch entry.value {
            case .text(let text): text
            case .list(let items): items.joined(separator: ", ")
            case .raw(let text): text
            case .null: "—"
            }
            rows.append((entry.key, value))
        }
        return rows
    }
}

extension KnowledgeKind {
    /// "Note", "To-Do", "Skill": the + button.
    var title: String {
        switch self {
        case .note: "Note"
        case .todo: "To-Do"
        case .skill: "Skill"
        case .project: "Project"
        }
    }
}
