import AppIntents
import AppKit
import KeyboardShortcuts
import SwiftUI
import CortexCore

/// `>` in the palette: quick actions on the clipboard, the Finder selection,
/// a clip, dropped files or the selected text, the user's TOML actions, and
/// the jobs they run in the background. Also offered in the Services menu
/// and to Shortcuts through App Intents. Runs the `$` commands for the
/// Commands module (`ActionsAPI`).
@MainActor
final class ActionsModule: CortexModule, ActionsAPI, SyncContributing {
    /// The palette trigger.
    static let prefix = ">"

    static let manifest = ModuleManifest(
        id: "actions", name: "Quick Actions",
        summary: "Runs actions on the clipboard, selected text or files.",
        symbol: "bolt", trigger: .prefix(prefix), placeholder: "actions",
        permissions: [.accessibility, .finderAutomation], order: 30)

    let service: ActionsService
    private let scope: ActionsScope
    private let context: ModuleContext
    private var progressCard: ProgressCardController?
    private var servicesProvider: ServicesProvider?
    private var isObservingUserActions = false
    private var userFilesHandlers: [@MainActor () -> Void] = []
    /// App Intents take the service once per process.
    private static var isDependencyAdded = false

    init(context: ModuleContext) {
        self.context = context
        let service = ActionsService(
            defaults: context.defaults.store, pasting: context.pasting, notifier: context.notifier)
        self.service = service
        scope = ActionsScope(
            service: service,
            resolveInput: { [context] in Self.resolveInput(over: context.palette.previousApp) },
            palette: { [context] in context.palette })
        // "Create Snippet" and `.snippet` results, while Snippets is on.
        service.editSnippet = { [context] request in context.api(SnippetsAPI.self)?.editSnippet(request) }
        service.canEditSnippets = { [context] in context.api(SnippetsAPI.self) != nil }
        // The AI actions, while that module is on.
        service.contributedActions = { [context] in
            context.apis(ActionContributing.self).flatMap(\.contributedActions)
        }
        // A file's trigger must not be the name of an AI command either.
        service.reservedCommands = { [context] in
            CommandCatalog.builtIns + context.apis(CommandContributing.self).flatMap(\.contributedCommands)
        }
        // Shortcuts may run an intent while Quick Actions are off; it needs
        // the service to say so. Once per process: it cannot be removed.
        if !Self.isDependencyAdded {
            Self.isDependencyAdded = true
            AppDependencyManager.shared.add(dependency: service)
        }
    }

    var palette: (any PaletteScope)? { scope }

    var options: [ModuleOption] {
        [ModuleOption(id: "folder", title: "Folder", kind: .folder(service.directory))]
    }

    var settingsView: AnyView? {
        AnyView(ActionsSettingsView(actions: service))
    }

    /// Files dropped onto the palette or the menu bar icon: the actions on them.
    func acceptsDroppedFiles(_ urls: [URL]) -> Bool {
        showActions(on: ResolvedActionInput(input: .files(urls), source: .dropped))
        return true
    }

    /// Quick Actions, then one item per running job.
    func statusMenuItems() -> [StatusMenuItem] {
        let open = StatusMenuItem("Quick Actions", shortcut: .quickActions) { [weak self] in
            self?.showActions(on: nil)
        }
        return [open] + service.jobs.map(Self.statusMenuItem(for:))
    }

    var statusIcon: StatusIcon? {
        Self.statusIcon(for: service.jobs)
    }

    /// The job with its progress; choosing it cancels the job.
    static func statusMenuItem(for job: ActionJob) -> StatusMenuItem {
        let percent = job.progress.map { " – \(Int(($0 * 100).rounded())) %" } ?? "…"
        return StatusMenuItem(
            "\(job.title): \(job.inputSummary)\(percent)", image: "gearshape.arrow.triangle.2.circlepath",
            toolTip: "Choose to cancel"
        ) { job.cancel() }
    }

    /// A progress ring while actions run; it beats Clipboard's pause icon.
    static func statusIcon(for jobs: [ActionJob]) -> StatusIcon? {
        guard !jobs.isEmpty else { return nil }
        return StatusIcon(
            image: ProgressRing.image(progress: ActionJob.overallProgress(jobs)),
            accessibilityLabel: "Cortex (running \(jobs.count == 1 ? jobs[0].title : "\(jobs.count) actions"))",
            priority: 10)
    }

    func start() async {
        guard !service.isRunning else { return }
        service.start()
        observeUserActions()
        if progressCard == nil {
            progressCard = ProgressCardController(actions: service)
        }

        // Services menu ("Open in Cortex"). App Intents are set up in `init`.
        let provider = ServicesProvider { [unowned self] input in showActions(on: input) }
        servicesProvider = provider
        NSApp.servicesProvider = provider
        NSUpdateDynamicServices()
    }

    /// The intents stay registered (they cannot be removed) and say that
    /// Quick Actions are switched off.
    func stop() {
        service.stop()
        isObservingUserActions = false
        if let servicesProvider, NSApp.servicesProvider as? ServicesProvider === servicesProvider {
            NSApp.servicesProvider = nil
        }
        servicesProvider = nil
        scope.clear()
    }

    var hotkeys: [ModuleHotkey] {
        [
            ModuleHotkey(
                .quickActions, title: "Open quick actions:",
                help: "Over Finder they work on the selected files, elsewhere on the clipboard. In the palette, type > or press ⌘K on a clip. Files dropped on the menu bar icon open them too."
            ) { [context] in
                context.palette.toggle(Self.manifest.id)
            },
            ModuleHotkey(
                .actOnSelection, title: "Act on the selection:",
                help: "Works in any app: copies the selected text, opens the actions on it and replaces the selection with the result. ⌥⏎ copies the result instead. The clipboard and the history stay as they were. Needs Accessibility, like pasting."
            ) { [unowned self] in
                showActionsOnSelection()
            },
        ]
    }

    /// Opens `>` on the text selected in the frontmost app. The chosen
    /// action's result replaces the selection.
    func showActionsOnSelection() {
        let palette = context.palette
        if palette.isVisible {
            palette.close()
            return
        }
        context.accessibility.refresh()
        guard context.accessibility.isGranted else {
            context.requestAccessibility()
            return
        }
        guard let target = NSWorkspace.shared.frontmostApplication, target != .current else { return }
        let reader = SelectionReader(activity: context.pasteboard)
        Task {
            switch await reader.read() {
            case .success(let resolved):
                // Another app may have come to the front while waiting.
                guard NSWorkspace.shared.frontmostApplication == target, !palette.isVisible else { return }
                showActions(on: resolved)
            case .failure(let error):
                context.log.info("No selection: \(error.message, privacy: .public)")
                context.notifier.post(title: "Nothing to work on", body: error.message)
            }
        }
    }

    /// The user's action files show up in the open palette.
    private func observeUserActions() {
        isObservingUserActions = true
        withObservationTracking {
            _ = service.userActions
            _ = service.userCommands
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingUserActions else { return }
                self.scope.actionsDidChange()
                for handler in self.userFilesHandlers { handler() }
                self.observeUserActions()
            }
        }
    }

    /// Over Finder, the selected files; otherwise (or with nothing
    /// selected) what is on the clipboard.
    static func resolveInput(over app: NSRunningApplication?) -> ResolvedActionInput {
        var problem: String?
        if app?.bundleIdentifier == FinderSelection.bundleID {
            switch FinderSelection.read() {
            case .success(let urls) where !urls.isEmpty:
                return ResolvedActionInput(input: .files(urls), source: .finder)
            case .success:
                break
            case .failure(let error):
                problem = error.message
            }
        }
        return .pasteboard(problem: problem)
    }

    // MARK: - ActionsAPI

    func showActions(on input: ResolvedActionInput?) {
        // Before opening: `>` would read the Finder selection or the clipboard.
        if let input { scope.handIn(input) }
        context.palette.open(Self.manifest.id)
    }

    func resolve(_ command: any Command, input: ActionInput, options: ActionOptionValues?, machine: Machine) async -> CommandResolution? {
        await service.resolve(command, input: input, options: options, machine: machine)
    }

    func run(_ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, delivery: ActionDelivery, summary: String?) async -> Bool {
        await service.run(command, input: input, machine: machine, resolution: resolution, delivery: delivery, summary: summary)
    }

    func options(for command: any Command) -> ActionOptionValues {
        service.options(for: command)
    }

    func setOptions(_ values: ActionOptionValues, for command: any Command) {
        service.setOptions(values, for: command)
    }

    var usage: [String: ActionUsage] { service.usage }

    var userCommands: [UserCommand] { service.userCommands }

    func onUserFilesChanged(_ handler: @escaping @MainActor () -> Void) {
        userFilesHandlers.append(handler)
    }

    func commandPane(for command: any Command, typed: String?, resolution: CommandResolution?, loading: String?, refreshProblem: String?) -> AnyView {
        AnyView(CommandOutcomeView(command: command, typed: typed, resolution: resolution, loading: loading, refreshProblem: refreshProblem))
    }

    // MARK: - SyncContributing

    var syncContributions: [SyncContribution] {
        [Self.syncContribution(for: service)]
    }

    /// The user's action files. They have no rows in the database, so Sync
    /// watches the folder for changes.
    static func syncContribution(for service: ActionsService) -> SyncContribution {
        SyncContribution(
            collection: .action, title: "Your quick actions", toggleKey: "syncActions",
            makeHandler: { ActionFileSync(directory: service.directory) },
            watchedFolder: service.directory)
    }
}

extension KeyboardShortcuts.Name {
    /// Copies the selected text in the frontmost app and opens the quick
    /// actions on it; the result replaces the selection.
    @MainActor static let actOnSelection = Self("actOnSelection", default: .init(.s, modifiers: [.control, .option, .command]))

    /// Opens the palette's quick actions on the Finder selection (over
    /// Finder) or the clipboard.
    @MainActor static let quickActions = Self("quickActions", default: .init(.a, modifiers: [.control, .option, .command]))
}
