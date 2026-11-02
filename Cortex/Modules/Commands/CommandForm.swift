import AppKit
import CortexCore

/// Where a `$` form's suggestions come from (docs/modules/COMMANDS.md, "Suggestions").
struct CommandSuggestionSources {
    /// The pasteboard's text; nil when it holds none or is sensitive.
    var pasteboardText: @MainActor () -> String?
    /// Recent text clips without sensitive ones: the Clipboard module's,
    /// none without it.
    var recentTexts: @MainActor (_ limit: Int) async -> [RecentClipText]

    /// No suggestions at all.
    static let none = CommandSuggestionSources(pasteboardText: { nil }, recentTexts: { _ in [] })
}

/// A `$` command's form (docs/modules/COMMANDS.md, "The form"): its argument, its
/// host, its options, the suggestions for the argument and what it resolves to
/// (what ⏎ would do). The argument starts empty: context is only ever a suggestion,
/// which ↓ puts into the field. The host starts at This Mac when a form is made,
/// whatever the last run used, and follows the query each time the list opens
/// it (the scope fills it in). Option values are remembered when the
/// form runs, not while typing. Kept by the scope while the palette is open, so Esc and ⏎ again find
/// the values as they were.
@MainActor
@Observable
final class CommandForm {
    enum Field: Hashable {
        case argument
        /// Where it runs (a command that runs on hosts).
        case host
        /// An option, by its ID.
        case option(String)
    }

    let command: any Command
    /// What was typed into the argument field and the highlighted suggestion.
    private(set) var field: SuggestingFieldState
    private(set) var options: ActionOptionValues
    /// Where it runs: This Mac, or a host picked in the Host field. Not an
    /// option, so it is not remembered.
    private(set) var machine = Machine.local
    /// The aliases of `~/.ssh/config`, read whenever the form opens.
    private(set) var hosts: [String] = []
    /// Everything suggested for the argument; `shownSuggestions` are those
    /// that match what was typed.
    private(set) var suggestions: [CommandSuggestion] = []
    /// A `.choice` argument's choices, once loaded.
    private(set) var choices: [ActionOption.Choice]?
    /// What the command resolved to on the fields' values.
    private(set) var resolution: CommandResolution?
    /// The command is being resolved, for the pane's loading state.
    private(set) var isLoadingPreview = false
    /// Resolves the value shown again while it asks for that (`$mem`).
    let refresh = CommandRefresh()
    /// The field with the keyboard; the view follows it.
    var focus: Field?
    /// ⏎ found the required argument empty.
    private(set) var isMarked = false

    @ObservationIgnored var previewDelay: Duration
    @ObservationIgnored let actions: any ActionsAPI
    @ObservationIgnored private let sources: CommandSuggestionSources
    @ObservationIgnored private let hostsSource: @Sendable () -> [String]
    @ObservationIgnored private var previewTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// How many recent clips are looked through for `.clips(matching:)`.
    static let historyLimit = 50

    init(
        command: any Command, actions: any ActionsAPI, sources: CommandSuggestionSources,
        hosts: @escaping @Sendable () -> [String] = SSHHosts.configured, previewDelay: Duration = .milliseconds(150)
    ) {
        self.command = command
        self.actions = actions
        self.sources = sources
        hostsSource = hosts
        self.previewDelay = previewDelay
        field = SuggestingFieldState()
        options = actions.options(for: command)
        focus = fields.first
    }

    /// The argument, as it is where the command runs.
    var argument: CommandArgument? { command.argument(on: machine) }

    /// The argument first, then the host, then one per option, in ⇥ order.
    var fields: [Field] {
        (argument == nil ? [] : [.argument]) + (command.runsOnHosts ? [.host] : []) + command.options.map { .option($0.id) }
    }

    // MARK: - The host

    /// The Host field as a choice: This Mac first, then the aliases. Its
    /// values are the aliases, and "" for This Mac.
    var hostOption: ActionOption {
        ActionOption(
            id: "host", title: "Host",
            kind: .choice([ActionOption.Choice("", title: Machine.local.title)] + hosts.map { ActionOption.Choice($0, title: $0) }),
            defaultValue: "")
    }

    /// The Host field's value: the alias, "" for This Mac.
    var hostValue: String { machine.alias ?? "" }

    /// Picks where it runs, as a click or ←→ do (the alias, "" for This Mac).
    func setHost(_ value: String) {
        guard command.runsOnHosts, value.isEmpty || hosts.contains(value) else { return }
        let machine: Machine = value.isEmpty ? .local : .ssh(value)
        guard machine != self.machine else { return }
        let before = argument
        self.machine = machine
        if argument != before {
            // The argument is another one on a host (a path, not a volume):
            // its choices and suggestions do not carry over.
            loadTask?.cancel()
            loadTask = nil
            choices = nil
            suggestions = []
            load()
        }
        valuesChanged()
    }

    /// Fills in the host as if picked: `$mem @pi` and ⇥. An alias that is
    /// not there is left out.
    func fill(host alias: String) {
        hosts = hostsSource()
        setHost(alias)
    }

    // MARK: - The argument

    /// What the argument field shows: the highlighted suggestion or what
    /// was typed. Setting it is typing.
    var text: String {
        get {
            field.highlighted.flatMap { shownSuggestions.indices.contains($0) ? shownSuggestions[$0].value : nil }
                ?? field.typed
        }
        set {
            field.type(newValue)
            isMarked = false
            valuesChanged()
        }
    }

    /// The suggestions that match what was typed.
    var shownSuggestions: [CommandSuggestion] {
        CommandSuggestion.filter(suggestions, by: field.typed)
    }

    /// The command's input from the argument field, or why there is none
    /// yet.
    var value: Result<ActionInput, CommandArgument.Problem> {
        guard let argument else { return .success(.none) }
        return argument.input(from: text, choices: choices)
    }

    /// What is wrong with the argument, in red under the fields. The
    /// preview's own error shows in the preview.
    var problem: String? {
        if case .failure(.invalid(let message)) = value { return message }
        return nil
    }

    /// The command did not resolve on what the fields hold (not a port
    /// number): ⏎ beeps.
    private var resolutionFailed: Bool {
        if case .failure = currentResolution?.result { return true }
        return false
    }

    /// The resolution, if it is for what the fields hold now.
    var currentResolution: CommandResolution? {
        guard case .success(let input) = value, let resolution, resolution.isFor(command, input: input, options: options, machine: machine)
        else { return nil }
        return resolution
    }

    /// What ⏎ and ⌥⏎ do on what the fields hold: the outcome's own words once
    /// the command resolved, "Run" before that or when it failed.
    var hints: [PaletteHint] {
        if let outcome = currentResolution?.outcome {
            return CommandsScope.hints(for: outcome, of: command)
        }
        return [PaletteHint(.primary, "Run"), PaletteHint(.option, "Run and copy")]
    }

    /// Fills in the argument as if typed: `$port 3000` and ⇥.
    func fill(_ typed: String) {
        text = typed
    }

    /// A file dropped onto the palette fills an argument that takes paths, as typed:
    /// `~/` for the home folder, quoted where the shell would need it.
    func drop(_ urls: [URL]) -> Bool {
        guard argument?.takesPaths == true, !urls.isEmpty else { return false }
        text = urls.map { Self.typedPath($0) }.joined(separator: " ")
        focus = .argument
        return true
    }

    static func typedPath(_ url: URL, home: URL = URL.homeDirectory) -> String {
        let path = url.path(percentEncoded: false)
        var homePath = home.path(percentEncoded: false)
        if !homePath.hasSuffix("/") { homePath += "/" }
        let typed = path.hasPrefix(homePath) ? "~/" + path.dropFirst(homePath.count) : path
        let isPlain = typed.allSatisfy { !$0.isWhitespace && !"'\"\\$`".contains($0) }
        return isPlain ? typed : ShellCommand.quote(typed)
    }

    // MARK: - Options

    func setOption(_ option: ActionOption, to value: String) {
        guard options[option] != value else { return }
        options[option] = value
        valuesChanged()
    }

    // MARK: - Keys

    /// ⇥ and ⇧⇥.
    func focusNext(_ forward: Bool = true) {
        let fields = fields
        guard !fields.isEmpty else { return }
        let index = focus.flatMap(fields.firstIndex(of:)) ?? (forward ? -1 : fields.count)
        focus = fields[(index + (forward ? 1 : -1) + fields.count) % fields.count]
    }

    /// ↑↓ into and out of the suggestions while the argument has focus, ←→
    /// through a choice option's values. false: the field gets the key.
    func move(_ step: PaletteStep) -> Bool {
        switch (step, focus) {
        case (.vertical(let delta), .argument):
            let before = text
            guard field.move(by: delta, count: shownSuggestions.count) else { return false }
            if text != before { valuesChanged() }
            return true
        case (.sideways(let delta), .host):
            guard case .choice(let choices) = hostOption.kind else { return false }
            let index = choices.firstIndex { $0.value == hostValue } ?? 0
            setHost(choices[min(max(index + delta, 0), choices.count - 1)].value)
            return true
        case (.sideways(let delta), .option(let id)):
            guard let option = command.options.first(where: { $0.id == id }),
                  case .choice(let choices) = option.kind, !choices.isEmpty else { return false }
            let index = choices.firstIndex { $0.value == options[option] } ?? 0
            setOption(option, to: choices[min(max(index + delta, 0), choices.count - 1)].value)
            return true
        default:
            return false
        }
    }

    /// A click on a suggestion: into the field, as ↓ would.
    func pick(_ index: Int) {
        guard shownSuggestions.indices.contains(index) else { return }
        field.pick(index)
        focus = .argument
        valuesChanged()
    }

    /// Whether ⇧⏎ breaks a line (in a prompt) instead of running.
    var breaksLines: Bool {
        focus == .argument && argument?.kind == .prompt
    }

    /// ⏎: the input to run on and the resolution to carry out, when every
    /// required field is valid and the command did not fail to resolve. An
    /// empty required argument is marked instead.
    func submit() -> (input: ActionInput, resolution: CommandResolution?)? {
        switch value {
        case .failure(.missing):
            isMarked = true
            focus = .argument
            return nil
        case .failure(.invalid):
            return nil
        case .success(let input):
            guard command.accepts(input), !resolutionFailed else { return nil }
            return (input, currentResolution)
        }
    }

    /// What was filled in, for the progress card (`$port 3000`).
    var summaryArgument: String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    // MARK: - Loading

    /// Reads the hosts, and loads the suggestions and choices once: the
    /// pasteboard is read at most once per form.
    func load() {
        if command.runsOnHosts {
            hosts = hostsSource()
            if let alias = machine.alias, !hosts.contains(alias) { machine = .local }
        }
        guard loadTask == nil else {
            // Shown again: its value carries on being refreshed.
            if !refresh.isRunning { followRefresh() }
            return
        }
        updatePreview()
        guard let argument else { return }
        loadTask = Task {
            if case .choice(let source) = argument.kind {
                let choices = await source.load()
                self.choices = choices
                suggestions = CommandSuggestion.choices(choices)
            } else {
                switch argument.suggestions {
                case .none, .choices:
                    break
                case .clips(let pattern):
                    let pasteboard = sources.pasteboardText()
                    let history = await sources.recentTexts(Self.historyLimit)
                    suggestions = CommandSuggestion.clips(
                        pasteboard: pasteboard, history: history, matching: pattern, for: argument.kind)
                case .clipboardText:
                    suggestions = CommandSuggestion.clipboardText(sources.pasteboardText())
                }
            }
            field.clamp(to: shownSuggestions.count)
            updatePreview()
        }
    }

    /// Waits for the suggestions (for tests).
    func loaded() async {
        await loadTask?.value
    }

    /// Waits for the resolution (for tests).
    func previewLoaded() async {
        await previewTask?.value
    }

    /// The palette hid: nothing more is looked up.
    func cancel() {
        loadTask?.cancel()
        previewTask?.cancel()
        refresh.stop()
        isLoadingPreview = false
    }

    /// The form went back to the list: the value is not refreshed while it
    /// is not shown. Showing it again (`load`) starts that again.
    func pause() {
        refresh.stop()
    }

    // MARK: - Preview

    private func valuesChanged() {
        field.clamp(to: shownSuggestions.count)
        updatePreview()
    }

    /// The command is resolved after a pause whenever a field changes (at
    /// once when it takes nothing).
    private func updatePreview() {
        previewTask?.cancel()
        isLoadingPreview = false
        guard case .success(let input) = value, command.accepts(input) else {
            refresh.stop()
            resolution = nil
            return
        }
        if currentResolution != nil {
            // Still the value shown: it carries on being refreshed (again,
            // when the form is shown again).
            if !refresh.isRunning { followRefresh() }
            return
        }
        refresh.stop()
        // While typing, the previous result stays until the new one is there.
        let (actions, command, options, machine) = (actions, command, options, machine)
        let delay = input == .none ? .zero : previewDelay
        isLoadingPreview = true
        previewTask = Task {
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            let result = await actions.resolve(command, input: input, options: options, machine: machine)
            guard !Task.isCancelled else { return }
            resolution = result
            isLoadingPreview = false
            followRefresh()
        }
    }

    /// Resolves the value again every so often, when it asks for that.
    private func followRefresh() {
        guard let resolution = currentResolution else { return }
        refresh.follow(resolution, of: command, using: actions) { [weak self] in self?.resolution = $0 }
    }
}
