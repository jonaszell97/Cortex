import AppKit
import SwiftUI
import CortexCore

/// `$` in the palette (docs/modules/COMMANDS.md, "Reading the query" and "The
/// scope"). The text after `$` is a command's name and its argument: `$port
/// 3000`. Only an exact name makes the rest an argument; otherwise the whole text
/// searches names, titles and keywords. A command never runs on the clipboard or
/// a selection. A word `@pi` after the name of a command that runs on hosts
/// picks the host (`$mem @pi`); it has to be an alias of `~/.ssh/config`.
///
/// The named command is resolved on the typed argument after a pause (at once
/// when it takes none): the pane shows its outcome, whether a value, something
/// to open, what ends, the plan of a job or what it hands over to. One that
/// still needs its argument shows what it takes. ⏎ carries out the outcome that
/// is shown (a value is pasted, ⌥⏎ only copies it; ⌥⏎ on something that opens
/// copies its link or path), and the hints say what that is ("Paste", "Open in
/// VS Code", "Kill…", "Start"). A command that did not resolve, one with a
/// notice ("Nothing is listening on port 3000") and ⌥⏎ where the hints show
/// none beep, also before the outcome has arrived: ⌥⏎ waits for it. A value that asks for it is resolved again while it is shown
/// (`CommandRefresh`). One that still needs its argument opens its form
/// (`CommandForm`), as ⇥ does for any command with fields. ⌘E on a typed command
/// with a settings file opens that file (`SettingsFileCommand`).
@MainActor
@Observable
final class CommandsScope: PaletteScope {
    let list = ResultList<any Command, String>(id: { $0.id })
    private(set) var query = CommandQuery("", names: [])
    /// What the selected command resolved to on what was typed, or why not.
    private(set) var resolution: CommandResolution?
    /// The machine the typed `@host` names, this Mac without one. Not for
    /// the commands that do not run on hosts; see `machine(for:)`.
    private(set) var machine = Machine.local
    /// Why the typed `@host` is no machine: not in `~/.ssh/config`, or more
    /// than one. The pane shows it as the preview's error.
    private(set) var hostProblem: QuickActionError?
    /// The command is being resolved (`$mem` reads `vm_stat` and `ps`,
    /// over SSH it connects first), for the pane's loading state.
    private(set) var isLoadingPreview = false
    /// The query as last searched, for the empty state.
    private(set) var searchText = ""

    /// How long typing has to pause before the argument is resolved, so
    /// that `$port 3000` is looked up once rather than for 3, 30, 300 and 3000.
    @ObservationIgnored var previewDelay: Duration = .milliseconds(150)
    /// Resolves the value shown again while it asks for that (`$mem`).
    let refresh = CommandRefresh()
    @ObservationIgnored private let commands: @MainActor () -> [any Command]
    @ObservationIgnored let actions: @MainActor () -> (any ActionsAPI)?
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost
    @ObservationIgnored private let sources: CommandSuggestionSources
    /// The aliases of `~/.ssh/config`, looked up whenever a host is typed.
    @ObservationIgnored private let hosts: @Sendable () -> [String]
    /// Opens a settings file's `vscode://` link.
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    /// A ⌥⏎ that is waiting for the pane to resolve (`runWhenResolved`).
    @ObservationIgnored private var runTask: Task<Void, Never>?
    /// The forms opened since the palette was shown, by command ID: their
    /// values stay until it hides.
    @ObservationIgnored private(set) var forms: [String: CommandForm] = [:]
    /// The resolution is the error of the typed `@host`, not a result.
    @ObservationIgnored private var resolutionIsHostProblem = false
    /// nil while nothing is loaded (the palette is hidden).
    @ObservationIgnored private var loadedQuery: String?

    init(
        commands: @escaping @MainActor () -> [any Command],
        actions: @escaping @MainActor () -> (any ActionsAPI)?,
        palette: @escaping @MainActor () -> any PaletteHost,
        sources: CommandSuggestionSources = .none,
        hosts: @escaping @Sendable () -> [String] = SSHHosts.configured,
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    ) {
        self.commands = commands
        self.actions = actions
        self.palette = palette
        self.sources = sources
        self.hosts = hosts
        self.openURL = openURL
        list.didSelect = { [weak self] _ in
            self?.updatePreview()
        }
    }

    /// The user's command files changed: list them again if they are showing.
    func commandsDidChange() {
        if let loadedQuery { search(loadedQuery) }
    }

    func select(_ id: String?) {
        list.select(id)
    }

    /// Whether `command` is the one the query names, so that the typed
    /// argument is its input.
    func isNamed(_ command: any Command) -> Bool {
        query.isNamed && SnippetSearch.fold(command.name) == SnippetSearch.fold(query.word)
    }

    /// What `command` runs on: the typed argument for the named command,
    /// nothing for the others.
    func input(for command: any Command) -> ActionInput {
        isNamed(command) ? command.input(typed: query.argument) : .none
    }

    /// Where `command` runs: the typed `@host` for the named command, this
    /// Mac for the others. A `@host` that is not valid is `hostProblem`.
    func machine(for command: any Command) -> Machine {
        isNamed(command) ? machine : .local
    }

    /// The error of the typed `@host`, for the named command.
    private func hostProblem(for command: any Command) -> QuickActionError? {
        isNamed(command) ? hostProblem : nil
    }

    /// `$port 3000`, or `$disk /mnt/usb @pi`, for the progress card.
    static func summary(of command: any Command, argument: String?, machine: Machine = .local) -> String {
        CommandsModule.prefix + command.name + (argument.map { " \($0)" } ?? "") + (machine.alias.map { " @\($0)" } ?? "")
    }

    /// The command as typed, for the pane's header: `$port 3000 @pi`, with
    /// the argument and hosts as typed (`CommandRowView.title`), without the
    /// dimmed example.
    func typed(_ command: any Command) -> String {
        CommandRowView.title(
            for: command, typedArgument: isNamed(command) ? query.argument : nil, typedHosts: isNamed(command) ? query.hosts : []).text
    }

    /// `title` for the pane's loading state: "Memory Usage on pi".
    func loadingTitle(for command: any Command) -> String {
        machine(for: command).describing(command.title)
    }

    /// What the pane says is loading: "Memory Usage on pi", while `command`
    /// is resolved on what is typed and the pane has no resolution for that
    /// yet. A resolution of an earlier input is still shown, dimmed.
    func loading(for command: any Command) -> String? {
        guard isLoadingPreview else { return nil }
        if let resolution, resolution.commandID == command.id, resolution.input == input(for: command),
           resolution.machine == machine(for: command) {
            return nil
        }
        return loadingTitle(for: command)
    }

    /// Waits for the resolution of the typed argument (for tests).
    func previewLoaded() async {
        await previewTask?.value
    }

    /// Waits for a ⌥⏎ that waited for the resolution (for tests).
    func runLoaded() async {
        await runTask?.value
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        searchText = text
        loadedQuery = text
        let commands = commands()
        query = CommandQuery(
            text, names: Set(commands.map { SnippetSearch.fold($0.name) }),
            hostNames: Set(commands.filter(\.runsOnHosts).map { SnippetSearch.fold($0.name) }))
        resolveHost()
        let ranked = CommandCatalog.rank(commands, for: query, usage: actions()?.usage ?? [:])
        // Typing the argument keeps the selection.
        list.replace(with: ranked, query: query.isNamed ? "\u{0}" + SnippetSearch.fold(query.word) : text)
        updatePreview()
    }

    /// Checks the typed `@host` against `~/.ssh/config`: one of its aliases,
    /// and only one.
    private func resolveHost() {
        machine = .local
        hostProblem = nil
        guard query.isNamed, !query.hosts.isEmpty else { return }
        do {
            machine = try Machine.named(by: query.hosts, in: hosts())
        } catch {
            hostProblem = error as? QuickActionError ?? QuickActionError(error.localizedDescription)
        }
    }

    func didLeave() {
        previewTask?.cancel()
        runTask?.cancel()
        refresh.stop()
        isLoadingPreview = false
    }

    func clear() {
        for form in forms.values { form.cancel() }
        forms = [:]
        list.clear()
        previewTask?.cancel()
        runTask?.cancel()
        refresh.stop()
        isLoadingPreview = false
        resolution = nil
        query = CommandQuery("", names: [])
        machine = .local
        hostProblem = nil
        resolutionIsHostProblem = false
        searchText = ""
        loadedQuery = nil
    }

    var body: AnyView { AnyView(CommandsView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let command = switch target {
        case .selected: list.selected
        case .position(let index): list.item(at: index)
        }
        if let command { choose(command, copyOnly: activation.isCopy) }
        return true
    }

    /// ⏎ and ⌥⏎ say what the selected command's outcome does; until it is
    /// resolved on what is typed, or when it failed, they say "Run".
    var activationHints: [PaletteHint] {
        if let command = list.selected, let outcome = shownOutcome(of: command) {
            return Self.hints(for: outcome, of: command) + [.positions("Run")]
        }
        return [PaletteHint(.primary, "Run and paste"), PaletteHint(.option, "Run and copy"), .positions("Run")]
    }

    /// ⏎, and ⌥⏎ where it does something.
    static func hints(for outcome: CommandOutcome, of command: any Command) -> [PaletteHint] {
        let keys = outcome.keys(of: command)
        return [PaletteHint(.primary, keys.primary)] + (keys.option.map { [PaletteHint(.option, $0)] } ?? [])
    }

    /// What the selected command resolved to on what is typed now: nil while
    /// that is still being looked up, when it failed, or when the command
    /// needs its form first.
    func shownOutcome(of command: any Command) -> CommandOutcome? {
        let input = input(for: command)
        guard command.accepts(input), hostProblem(for: command) == nil, let resolution,
              resolution.commandID == command.id, resolution.input == input, resolution.machine == machine(for: command)
        else { return nil }
        return resolution.outcome
    }

    /// ⇥ opens the selected command's form, with what was typed after its
    /// name filled in. ⌘E opens the settings file of the command typed.
    var keys: [PaletteKey] {
        guard let command = list.selected else { return [] }
        var keys: [PaletteKey] = []
        if command.argument != nil || command.runsOnHosts || !command.options.isEmpty {
            let hint = command.argument != nil ? "Fill in" : command.options.isEmpty ? "Host" : "Options"
            keys.append(PaletteKey(.tab, hint: hint) { [unowned self] in
                openForm(for: command)
                return true
            })
        }
        if isNamed(command), let key = settingsKey(for: command) { keys.append(key) }
        return keys
    }

    /// ⌘E: "Edit projects.toml", for a command with a settings file.
    private func settingsKey(for command: any Command) -> PaletteKey? {
        guard let command = command as? any SettingsFileCommand else { return nil }
        return PaletteKey(Self.settingsKey, hint: "Edit \(command.settingsFile.lastPathComponent)") { [unowned self] in
            editSettings(of: command)
            return true
        }
    }

    static let settingsKey = KeyCombo.command("e")

    /// Closes the palette and opens the command's settings file in VS Code,
    /// written with its examples first when there is none; beeps when it
    /// cannot be written.
    func editSettings(of command: any SettingsFileCommand) {
        guard let link = try? command.settingsLink() else {
            Beep.play()
            return
        }
        palette().close()
        openURL(link)
    }

    // MARK: - Running

    /// ⏎ on a command: runs it on what was typed if it takes that (or
    /// nothing), otherwise opens its form.
    func choose(_ command: any Command, copyOnly: Bool = false) {
        if command.accepts(input(for: command)) {
            run(command, copyOnly: copyOnly)
        } else {
            openForm(for: command)
        }
    }

    /// ⏎ and ⇧⏎ carry out what the command resolved to and paste a text or
    /// image value, ⌥⏎ only copies it. Beeps when it does not take what was
    /// typed and when it did not resolve on this input (the pane says why).
    func run(_ command: any Command, copyOnly: Bool = false) {
        let input = input(for: command)
        let machine = machine(for: command)
        let resolution = resolution.flatMap { $0.commandID == command.id && $0.input == input && $0.machine == machine ? $0 : nil }
        guard command.accepts(input), hostProblem(for: command) == nil else {
            Beep.play()
            return
        }
        if case .failure = resolution?.result {
            Beep.play()
            return
        }
        // ⌥⏎ before the pane has resolved: a copy would resolve and carry out
        // the outcome, so it waits to see whether there is a second step.
        if copyOnly, resolution == nil, isLoadingPreview, let resolving = previewTask {
            runWhenResolved({ await resolving.value }) { [unowned self] in run(command, copyOnly: true) }
            return
        }
        // ⌥⏎ has no hint, so no meaning, where the outcome has no second step.
        if copyOnly, let outcome = resolution?.outcome, outcome.keys(of: command).option == nil {
            Beep.play()
            return
        }
        deliver(command, input: input, machine: machine, resolution: resolution, argument: isNamed(command) ? query.argument : nil, copyOnly: copyOnly)
    }

    /// The form's ⏎: runs on what it holds and remembers its options, or
    /// beeps (an empty required field is marked).
    func run(_ form: CommandForm, copyOnly: Bool = false) {
        guard let actions = actions(), let (input, resolution) = form.submit() else {
            Beep.play()
            return
        }
        if copyOnly, resolution == nil, form.isLoadingPreview {
            runWhenResolved({ await form.previewLoaded() }) { [unowned self] in run(form, copyOnly: true) }
            return
        }
        if copyOnly, let outcome = resolution?.outcome, outcome.keys(of: form.command).option == nil {
            Beep.play()
            return
        }
        actions.setOptions(form.options, for: form.command)
        deliver(form.command, input: input, machine: form.machine, resolution: resolution, argument: form.summaryArgument, copyOnly: copyOnly)
    }

    /// Runs again once the resolution has arrived, unless typing or leaving
    /// came first.
    private func runWhenResolved(_ resolved: @escaping @MainActor () async -> Void, then run: @escaping @MainActor () -> Void) {
        runTask?.cancel()
        runTask = Task {
            await resolved()
            guard !Task.isCancelled else { return }
            run()
        }
    }

    private func deliver(
        _ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, argument: String?, copyOnly: Bool
    ) {
        guard let actions = actions() else {
            Beep.play()
            return
        }
        let summary = Self.summary(of: command, argument: argument, machine: machine)
        palette().closeAndDeliver(copyOnly ? .copyOnly : .paste(.plainText)) { target in
            await actions.run(
                command, input: input, machine: machine, resolution: resolution, delivery: copyOnly ? .copy : .paste(target), summary: summary)
        }
    }

    // MARK: - The form

    /// The command's form over the list, as it was left if it was open
    /// before; what was typed after the command's name fills its argument and
    /// its host (This Mac without one).
    func openForm(for command: any Command) {
        guard let actions = actions() else { return }
        let form = forms[command.id] ?? CommandForm(
            command: command, actions: actions, sources: sources, hosts: hosts, previewDelay: previewDelay)
        forms[command.id] = form
        // The form resolves for itself from here on.
        refresh.stop()
        form.refresh.interval = refresh.interval
        if isNamed(command), let argument = query.argument { form.fill(argument) }
        // The host follows the query, even for a form kept from before.
        form.fill(host: machine(for: command).alias ?? "")
        form.focus = form.fields.first
        form.load()
        palette().present(overlay(for: form))
    }

    private func overlay(for form: CommandForm) -> PaletteOverlay {
        var keys: [PaletteKey] = []
        if form.fields.count > 1 {
            keys.append(PaletteKey(.tab, hint: "Next field") { form.focusNext(); return true })
            keys.append(PaletteKey(.shiftTab) { form.focusNext(false); return true })
        }
        if let key = settingsKey(for: form.command) { keys.append(key) }
        var dropFiles: (@MainActor ([URL]) -> Bool)?
        if form.argument?.takesPaths == true {
            dropFiles = { form.drop($0) }
        }
        return PaletteOverlay(
            body: AnyView(CommandFormView(form: form)),
            activationHints: [PaletteHint(.primary, "Run"), PaletteHint(.option, "Run and copy")],
            currentHints: { form.hints },
            keys: keys,
            activate: { [unowned self] activation in
                if activation == .shift, form.breaksLines {
                    NSApp.sendAction(#selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), to: nil, from: nil)
                } else {
                    run(form, copyOnly: activation.isCopy)
                }
            },
            escape: .dismiss,
            move: { form.move($0) },
            dropFiles: dropFiles,
            dismissed: { [unowned self] in
                // Back on the list: the form stops, the list's value carries on.
                runTask?.cancel()
                form.pause()
                followRefresh()
            })
    }

    // MARK: - Resolving

    private func updatePreview() {
        // A lookup for what was typed before is no longer wanted, nor a ⌥⏎ that waited for it.
        previewTask?.cancel()
        runTask?.cancel()
        isLoadingPreview = false
        guard let command = list.selected, let actions = actions() else {
            refresh.stop()
            resolution = nil
            return
        }
        let input = input(for: command)
        let machine = machine(for: command)
        guard command.accepts(input) else {
            refresh.stop()
            resolution = nil
            return
        }
        if let problem = hostProblem(for: command) {
            refresh.stop()
            resolution = CommandResolution(
                commandID: command.id, input: input, options: actions.options(for: command), result: .failure(problem))
            resolutionIsHostProblem = true
            return
        }
        // The same resolution carries on, and so does its refresh.
        if let resolution, resolution.commandID == command.id, resolution.input == input, resolution.machine == machine, !resolutionIsHostProblem { return }
        // Another command, text or host: the value shown is no longer wanted.
        refresh.stop()
        // While the argument is typed, the previous result stays until the
        // new one is there; one from another machine does not.
        if resolution?.commandID != command.id || resolution?.machine != machine || resolutionIsHostProblem { resolution = nil }
        resolutionIsHostProblem = false
        // A command that takes nothing is shown at once.
        let delay = input == .none ? .zero : previewDelay
        isLoadingPreview = true
        previewTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await actions.resolve(command, input: input, options: nil, machine: machine)
            guard !Task.isCancelled else { return }
            resolution = result
            isLoadingPreview = false
            followRefresh(using: actions)
        }
    }

    /// Resolves the selected command's value again every so often, when it
    /// asks for that.
    private func followRefresh(using actions: (any ActionsAPI)? = nil) {
        guard let command = list.selected, let resolution, shownOutcome(of: command) != nil, let actions = actions ?? self.actions()
        else { return }
        refresh.follow(resolution, of: command, using: actions) { [weak self] in self?.resolution = $0 }
    }
}
