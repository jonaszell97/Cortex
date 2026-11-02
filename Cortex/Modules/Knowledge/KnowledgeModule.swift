import KeyboardShortcuts
import SwiftUI
import CortexCore

/// `?` in the palette: notes, skills, to-dos and projects kept as Markdown
/// files in `~/.config/cortex/knowledge/` (docs/modules/KNOWLEDGE.md); `!`: the to-dos.
/// The files are the source of truth; the module indexes them in memory,
/// watches the folder, captures notes and to-dos from the palette and from
/// clips (Save as Note, Add as To-Do), shows them in a browser window and
/// edits them in another,
/// keeps a git history of the folder, links its skills into Claude Code's
/// skills folder and hands the folder to Sync. With AI on, `$note`, `$todo`
/// and `$tidy` file text through its vendor (`AIAPI`) and show the result
/// in the palette before writing it. The logic is in CortexCore
/// (`KnowledgeLibrary`, `KnowledgeFileSync`);
/// agents reach the same files through `cortex-mcp`, embedded next to the
/// app's executable (CortexCore's `CortexMCP`).
@MainActor
final class KnowledgeModule: CortexModule, ActionContributing, CommandContributing, SyncContributing {
    static let manifest = ModuleManifest(
        id: "knowledge", name: "Knowledge", summary: "Finds and captures notes, skills and to-dos kept as Markdown files.",
        symbol: "books.vertical", trigger: .prefix("?"), placeholder: "notes",
        subscopes: [PaletteSubscope(id: TodoScope.id, trigger: "!", placeholder: "todos")],
        permissions: [.accessibility], order: 27)

    let service: KnowledgeService
    private let scope: KnowledgeScope
    let todos: TodoScope
    let editor: NoteEditorWindowController
    let browser: KnowledgeBrowserWindowController
    let reviewer: KnowledgeReviewPresenter
    private let context: ModuleContext

    init(context: ModuleContext) {
        self.context = context
        let service = KnowledgeService(settings: KnowledgeSettings(defaults: context.defaults))
        self.service = service
        let editor = NoteEditorWindowController(service: service)
        self.editor = editor
        let browser = KnowledgeBrowserWindowController(service: service)
        self.browser = browser
        scope = KnowledgeScope(
            service: service, moduleID: context.id, palette: { [context] in context.palette },
            edit: { path in editor.show(path) }, browse: { path in browser.show(path) })
        todos = TodoScope(service: service, palette: { [context] in context.palette }) { path in
            editor.show(path)
        }
        reviewer = KnowledgeReviewPresenter(
            service: service, moduleID: context.id, palette: { [context] in context.palette },
            notifier: { [context] title, body in context.notifier.post(title: title, body: body) })
    }

    var palette: (any PaletteScope)? { scope }

    func palette(_ subscope: ModuleID) -> (any PaletteScope)? {
        subscope == TodoScope.id ? todos : nil
    }

    // MARK: - ActionContributing

    var contributedActions: [any QuickAction] {
        [KnowledgeCaptureAction(.note, folder: service.folder), KnowledgeCaptureAction(.todo, folder: service.folder)]
    }

    // MARK: - CommandContributing

    /// `$note`, `$todo` and `$tidy`, while AI is on, with its vendor and
    /// text model as they are set now.
    var contributedCommands: [any Command] {
        guard let ai = context.api(AIAPI.self) else { return [] }
        let (vendor, model, send, index) = (ai.vendor, ai.textModel, ai.send, service.index)
        return KnowledgeFilingCommand.Kind.allCases.map { kind in
            KnowledgeFilingCommand(kind: kind, vendor: vendor, model: model, index: index, send: send) { [weak self] content in
                self?.reviewer.present(content)
            }
        }
    }

    // MARK: - SyncContributing

    var syncContributions: [SyncContribution] {
        [Self.syncContribution(for: service)]
    }

    /// The whole folder, as files. They have no rows in the database, so
    /// Sync watches the folder; the module's own watcher indexes what
    /// arrives.
    static func syncContribution(for service: KnowledgeService) -> SyncContribution {
        SyncContribution(
            collection: .knowledge, title: "Notes, skills and to-dos", toggleKey: "syncKnowledge",
            makeHandler: { KnowledgeFileSync(root: service.folder.root, hashes: service.syncHashes) },
            watchedFolder: service.folder.root,
            didApplyRemoteChanges: { if service.isRunning { service.refresh() } })
    }

    var hotkeys: [ModuleHotkey] {
        [
            ModuleHotkey(
                .knowledgeCapture, title: "Search and capture notes:",
                help: "Opens the palette at ?. Type to search; when nothing matches, ⏎ saves what you typed as a note in the inbox."
            ) { [context] in
                context.palette.toggle(Self.manifest.id)
            },
        ]
    }

    var options: [ModuleOption] {
        let history = Binding(
            get: { [service] in service.settings.keepHistory },
            set: { [service] in
                service.settings.keepHistory = $0
                service.historySettingChanged()
            })
        let links = Binding(
            get: { [service] in service.settings.linkSkills },
            set: { [service] in
                service.settings.linkSkills = $0
                service.skillLinksSettingChanged()
            })
        return [
            ModuleOption(id: "folder", title: "Folder", kind: .folder(service.folder.root)),
            ModuleOption(
                id: "keepHistory", title: "Keep a git history",
                help: "Commits every change to a git repository in the folder, a minute after the last one. No remote, nothing leaves this Mac.",
                kind: .toggle(history)),
            ModuleOption(
                id: "linkSkills", title: "Link skills into ~/.claude/skills",
                help: "One symlink per skill, so Claude Code loads them as its own in every session. Only links into the knowledge folder are ever added or removed; switching this off removes them.",
                kind: .toggle(links)),
        ]
    }

    var settingsView: AnyView? {
        AnyView(KnowledgeSettingsView(service: service))
    }

    var settingsPanes: [SettingsPane] {
        [SettingsPane(id: "projects", title: "Projects", symbol: "folder", view: AnyView(ProjectsSettingsView(service: service)))]
    }

    func statusMenuItems() -> [StatusMenuItem] {
        [
            StatusMenuItem("Browse Knowledge…") { [browser] in browser.show() },
            StatusMenuItem("New To-Do…") { [context] in context.palette.open(TodoScope.id) },
            StatusMenuItem("Open Knowledge Folder") { [service] in service.revealFolder() },
        ]
    }

    func start() async {
        guard !service.isRunning else { return }
        service.onChange = { [scope, todos] in
            scope.knowledgeDidChange()
            todos.knowledgeDidChange()
        }
        await service.start()
    }

    func stop() {
        editor.close()
        browser.close()
        service.onChange = nil
        service.stop()
        scope.clear()
        todos.clear()
    }
}

extension KeyboardShortcuts.Name {
    /// Opens the palette at `?`. No default: off until recorded.
    @MainActor static let knowledgeCapture = Self("knowledgeCapture")
}
