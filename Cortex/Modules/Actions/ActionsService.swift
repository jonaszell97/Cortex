import AppKit
import CortexCore

/// One action running in the background, shown in the progress card, the
/// menu bar icon and the status menu.
@MainActor
@Observable
final class ActionJob: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    let inputSummary: String
    /// 0 to 1, or nil while unknown.
    var progress: Double?
    private(set) var isCancelled = false
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, symbol: String = "gearshape", inputSummary: String) {
        self.title = title
        self.symbol = symbol
        self.inputSummary = inputSummary
    }

    func cancel() {
        isCancelled = true
        task?.cancel()
    }

    /// All jobs together, for the menu bar ring: jobs without a known
    /// progress count as not started. Nil when none has reported any.
    static func overallProgress(_ jobs: [ActionJob]) -> Double? {
        guard jobs.contains(where: { $0.progress != nil }) else { return nil }
        return jobs.reduce(0) { $0 + min(max($1.progress ?? 0, 0), 1) } / Double(jobs.count)
    }
}

/// Owns the quick actions: the built-ins, the user's TOML actions (reloaded
/// when their folder changes), usage counts, remembered option values,
/// running jobs and delivering results.
@MainActor
@Observable
final class ActionsService {
    typealias Delivery = ActionDelivery

    let directory: URL
    private(set) var userActions: [UserAction] = []
    /// The files with a trigger: `$` commands (the Commands module lists them).
    private(set) var userCommands: [UserCommand] = []
    private(set) var problems: [UserActionLibrary.Problem] = []
    private(set) var jobs: [ActionJob] = []
    /// Opens the snippet editor, for `.snippet` results. Nil while snippets
    /// are unavailable (no database): then "Create Snippet" is not offered.
    @ObservationIgnored var editSnippet: ((SnippetEditRequest) -> Void)?
    /// Whether `editSnippet` works right now (Snippets may be switched off).
    @ObservationIgnored var canEditSnippets: () -> Bool = { true }
    /// Other modules' actions (`ActionContributing`), asked for on every listing.
    @ObservationIgnored var contributedActions: () -> [any QuickAction] = { [] }
    /// The commands a file's trigger must not clash with: the built-ins, and
    /// other modules' while they are on.
    @ObservationIgnored var reservedCommands: () -> [any Command] = { CommandCatalog.builtIns }
    /// Between `start()` and `stop()`: Quick Actions are switched on. Shortcuts
    /// and Services get an error otherwise.
    private(set) var isRunning = false
    /// Asks before a `.confirm` result goes ahead: an alert by default.
    @ObservationIgnored var confirm: (ActionConfirmation) async -> Bool = { await ActionsService.showAlert(for: $0) }
    /// Asks what to call a command "Save as Command" saves: an alert with a
    /// text field by default. Nil when cancelled.
    @ObservationIgnored var askCommandName: (CommandNameRequest) async -> String? = { await ActionsService.showNameAlert(for: $0) }

    @ObservationIgnored let notifier: Notifier
    @ObservationIgnored private let pasting: PasteService
    /// Opens a `.open` result: the default browser or app for the URL.
    @ObservationIgnored private let openURL: @MainActor (URL) -> Void
    @ObservationIgnored private let playSound: @MainActor (URL) -> Void
    /// A file or folder, then the app to open it with.
    @ObservationIgnored private let openWithApp: @MainActor (URL, URL) -> Void
    /// The built-in commands too, as quick actions (`CommandAction`): `>`
    /// offers one on context meant for it (Kill Process on Port on a copied
    /// port number).
    @ObservationIgnored private let builtIns = ActionCatalog.builtIns + CommandCatalog.builtIns.map { CommandAction($0) }
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private(set) var usage: [String: ActionUsage]
    /// Option values by action ID, then option ID.
    @ObservationIgnored private var optionValues: [String: [String: String]]
    @ObservationIgnored private var watcher: DirectoryWatcher?
    @ObservationIgnored private let log = Log.logger("actions")

    private static let usageKey = "quickActionUsage"
    private static let optionsKey = "quickActionOptions"
    /// Text this long (UTF-8 bytes) is not previewed while moving through the list.
    static let previewLimit = 500_000
    /// Longer text is previewed off the main thread (`previewAsync`), so a
    /// slow transform never stalls the palette.
    static let syncPreviewLimit = 20_000
    /// A text result this long (UTF-8 bytes) is not kept as a preview; ⏎
    /// runs the action again, off the main thread.
    static let previewOutputLimit = 10 * 1024 * 1024

    init(
        directory: URL = UserActionLibrary.defaultDirectory(),
        defaults: UserDefaults = .standard,
        pasting: PasteService = PasteService(),
        notifier: Notifier = Notifier(),
        openURL: @escaping @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) },
        playSound: @escaping @MainActor (URL) -> Void = { SoundPlayer.shared.play($0) },
        openWithApp: @escaping @MainActor (URL, URL) -> Void = { url, app in
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        }
    ) {
        self.directory = directory
        self.defaults = defaults
        self.pasting = pasting
        self.notifier = notifier
        self.openURL = openURL
        self.playSound = playSound
        self.openWithApp = openWithApp
        usage = defaults.data(forKey: Self.usageKey)
            .flatMap { try? JSONDecoder().decode([String: ActionUsage].self, from: $0) } ?? [:]
        optionValues = defaults.data(forKey: Self.optionsKey)
            .flatMap { try? JSONDecoder().decode([String: [String: String]].self, from: $0) } ?? [:]
    }

    /// Creates the actions folder if needed, loads it and watches it.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            log.error("Cannot create \(self.directory.path, privacy: .public): \(error, privacy: .public)")
        }
        reload()
        watcher = DirectoryWatcher(url: directory) { [weak self] in self?.reload() }
    }

    /// Stops watching the folder and cancels the running jobs.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        watcher = nil
        for job in jobs { job.cancel() }
    }

    /// Whether the actions folder is watched (for tests).
    var isWatching: Bool { watcher != nil }

    func reload() {
        let contents = UserActionLibrary.load(from: directory, reserved: reservedCommands())
        userActions = contents.actions
        userCommands = contents.commands
        problems = contents.problems
        log.info("Loaded \(contents.actions.count) user actions, \(contents.commands.count) commands, \(contents.problems.count) with problems")
    }

    var allActions: [any QuickAction] {
        let builtIns = editSnippet == nil || !canEditSnippets() ? builtIns.filter { $0.id != TextAction.createSnippetID } : builtIns
        return builtIns + contributedActions() + userActions
    }

    /// What Shortcuts offers: every action that is not a command (commands
    /// take what is typed; a copied port number is no input for Shortcuts),
    /// except "Save as Command", which asks for a name.
    var shortcutActions: [any QuickAction] {
        allActions.filter { !($0 is CommandAction) && $0.id != TextAction.saveCommandID }
    }

    /// What `>` lists for `query` on the listing's input.
    func list(query: String, for listing: ActionListing) -> [any QuickAction] {
        ActionCatalog.list(allActions, query: query, for: listing, usage: usage)
    }

    /// What `>` lists on this context input.
    func rank(for input: ActionInput, query: String) -> [any QuickAction] {
        list(query: query, for: .context(input))
    }

    // MARK: - Options

    /// The values last set for the action's options; options never set have
    /// their default.
    func options(for action: any QuickAction) -> ActionOptionValues {
        ActionOptionValues(optionValues[action.id] ?? [:])
    }

    /// The values last set for the command's options, which are stored
    /// under its ID like an action's.
    func options(for command: any Command) -> ActionOptionValues {
        ActionOptionValues(optionValues[command.id] ?? [:])
    }

    /// Remembers the values for the next run, from the palette or Shortcuts.
    func setOptions(_ values: ActionOptionValues, for action: any QuickAction) {
        setOptions(values, id: action.id, known: action.options)
    }

    func setOptions(_ values: ActionOptionValues, for command: any Command) {
        setOptions(values, id: command.id, known: command.options)
    }

    private func setOptions(_ values: ActionOptionValues, id: String, known options: [ActionOption]) {
        let known = Set(options.map(\.id))
        optionValues[id] = values.values.filter { known.contains($0.key) }
        if let data = try? JSONEncoder().encode(optionValues) {
            defaults.set(data, forKey: Self.optionsKey)
        }
    }

    // MARK: - Preview

    /// The result of a text action with the given option values (by default
    /// the remembered ones), computed right here, or nil for other actions
    /// and for text too long to transform on the main thread
    /// (`syncPreviewLimit`; use `previewAsync`).
    func preview(_ action: any QuickAction, input: ActionInput, options: ActionOptionValues? = nil) -> ActionPreview? {
        guard let textAction = action as? TextAction else { return nil }
        if let text = input.text, text.utf8.count > Self.syncPreviewLimit { return nil }
        let options = options ?? self.options(for: action)
        let result: Result<ActionOutput, QuickActionError>
        do {
            result = .success(try textAction.perform(input, options: options))
        } catch let error as QuickActionError {
            result = .failure(error)
        } catch {
            result = .failure(QuickActionError(error.localizedDescription))
        }
        return Self.isPreviewable(result) ? ActionPreview(actionID: action.id, input: input, options: options, result: result) : nil
    }

    /// The result of any instant action, which may take a moment (`$port`
    /// runs `lsof`, a long text is transformed), or nil if it does not take
    /// the input. The action runs off the main thread.
    /// `machine` is where a command that runs on hosts runs.
    func previewAsync(
        _ action: any QuickAction, input: ActionInput, options: ActionOptionValues? = nil, machine: Machine = .local
    ) async -> ActionPreview? {
        guard action.isInstant, action.accepts(input) else { return nil }
        if let text = input.text, text.utf8.count > Self.previewLimit { return nil }
        let options = options ?? self.options(for: action)
        let result = await execute(action, input: input, options: options, machine: machine, progress: { _ in })
        return Self.isPreviewable(result)
            ? ActionPreview(actionID: action.id, input: input, options: options, machine: machine, result: result) : nil
    }

    /// False for a text result too long to keep around and show.
    private static func isPreviewable(_ result: Result<ActionOutput, QuickActionError>) -> Bool {
        guard case .success(let output) = result, let text = output.text else { return true }
        return text.utf8.count <= previewOutputLimit
    }

    // MARK: - Running

    /// Runs an action with its remembered options. Instant actions deliver
    /// at once; everything else runs as a job and reports through a
    /// notification. Text and image results
    /// are new clips in the history (sensitive if the input was, or if the
    /// action makes secrets). Returns
    /// false when a paste was wanted but Accessibility is missing (the result
    /// was copied). A remote action does not run on sensitive input.
    /// `summary` describes the input in the progress card (by default the
    /// input's summary): what was typed, for a command ("$deploy staging").
    /// `machine` is where a command that runs on hosts runs; a preview is
    /// only used when it was made on the same one.
    @discardableResult
    func run(
        _ action: any QuickAction,
        input: ActionInput,
        machine: Machine = .local,
        isSensitive: Bool = false,
        preview: ActionPreview? = nil,
        delivery: Delivery,
        summary: String? = nil
    ) async -> Bool {
        // The palette does not list them for sensitive input; this is for
        // every other way in.
        if action.isRemote, isSensitive {
            log.info("\(action.id, privacy: .public) not run on sensitive input")
            notifier.post(title: "\(action.title) not run", body: "The input is marked sensitive, so it is not sent anywhere.")
            return true
        }
        markUsed(action.id)
        let options = options(for: action)
        let sensitiveResult = isSensitive || action.hasSensitiveResult
        if action.isInstant {
            let result: Result<ActionOutput, QuickActionError>
            if let preview, preview.actionID == action.id, preview.input == input,
               preview.options == options, preview.machine == machine {
                result = preview.result
            } else {
                result = await execute(action, input: input, options: options, machine: machine, progress: { _ in })
            }
            return await deliver(result, of: action, sensitive: sensitiveResult, delivery: delivery, startedAt: .now)
        }
        startJob(action, input: input, options: options, machine: machine, sensitive: sensitiveResult, delivery: delivery, summary: summary)
        return true
    }

    // MARK: - Commands

    /// What `command` resolves to on the input (the remembered options by
    /// default), or nil if it does not take the input. Resolving is cheap and
    /// changes nothing; it runs off the main thread, as a quick action does.
    func resolve(
        _ command: any Command, input: ActionInput, options: ActionOptionValues? = nil, machine: Machine = .local
    ) async -> CommandResolution? {
        guard command.accepts(input) else { return nil }
        let options = options ?? self.options(for: command)
        let result: Result<CommandOutcome, QuickActionError>
        do {
            result = .success(try await command.resolve(CommandInvocation(input: input, options: options, machine: machine)))
        } catch let error as QuickActionError {
            result = .failure(error)
        } catch is CancellationError {
            result = .failure(QuickActionError("Cancelled"))
        } catch {
            result = .failure(QuickActionError(error.localizedDescription))
        }
        return CommandResolution(commandID: command.id, input: input, options: options, machine: machine, result: result)
    }

    /// Carries a command out like `run` does an action, with the outcome the
    /// palette showed if `resolution` is for the same input, options and
    /// machine; otherwise it resolves again, and a command that cannot
    /// resolve is a failed run (a notice, a plain notification). A job starts
    /// in the background, everything else is delivered at once; a copy
    /// (⌥⏎) of something that opens copies its link or path.
    @discardableResult
    func run(
        _ command: any Command,
        input: ActionInput,
        machine: Machine = .local,
        isSensitive: Bool = false,
        resolution: CommandResolution? = nil,
        delivery: Delivery,
        summary: String? = nil
    ) async -> Bool {
        if command.isRemote, isSensitive {
            // Refused like any remote action, before anything is resolved.
            return await run(
                CommandAction(command), input: input, machine: machine, isSensitive: true, delivery: delivery, summary: summary)
        }
        let options = options(for: command)
        let current = if let resolution, resolution.isFor(command, input: input, options: options, machine: machine) {
            resolution
        } else {
            await self.resolve(command, input: input, options: options, machine: machine)
        }
        guard let current else {
            return await fail(command, QuickActionError("\(command.title) does not take this input"), delivery: delivery)
        }
        switch current.result {
        case .failure(let error):
            return await fail(command, error, delivery: delivery)
        case .success(.open(let target)) where delivery == .copy:
            // ⌥⏎ copies the link or path (a clip like any other) instead of
            // opening it.
            markUsed(command.id)
            return await deliver(.success(.text(target.copyText)), of: CommandAction(command), sensitive: false, delivery: delivery, startedAt: .now)
        case .success(let outcome):
            return await run(
                CommandAction(command, outcome: outcome), input: input, machine: machine, isSensitive: isSensitive,
                delivery: delivery, summary: summary)
        }
    }

    /// A command that could not resolve: counted as used and reported like
    /// any failed action. A notice ("Nothing is listening on port 3000") is
    /// an ordinary notification with its sentence, not a failure.
    private func fail(_ command: any Command, _ error: QuickActionError, delivery: Delivery) async -> Bool {
        markUsed(command.id)
        let result: Result<ActionOutput, QuickActionError> = error.isNotice ? .success(.done(error.message)) : .failure(error)
        return await deliver(result, of: CommandAction(command), sensitive: false, delivery: delivery, startedAt: .now)
    }

    /// `summary` describes the input in the progress card; by default the
    /// input's summary.
    private func startJob(
        _ action: any QuickAction, input: ActionInput, options: ActionOptionValues, machine: Machine = .local, sensitive: Bool,
        delivery: Delivery, summary: String? = nil
    ) {
        let job = ActionJob(title: action.title, symbol: action.symbol, inputSummary: summary ?? input.summary)
        jobs.append(job)
        let started = Date.now
        log.info("Started \(action.id, privacy: .public)")
        job.task = Task {
            let result = await execute(action, input: input, options: options, machine: machine) { fraction in
                Task { @MainActor in job.progress = fraction }
            }
            jobs.removeAll { $0.id == job.id }
            if case .failure = result, Task.isCancelled {
                log.info("Cancelled \(action.id, privacy: .public)")
                return
            }
            await deliver(result, of: action, sensitive: sensitive, delivery: delivery, startedAt: started)
        }
    }

    private func execute(
        _ action: any QuickAction, input: ActionInput, options: ActionOptionValues, machine: Machine = .local,
        progress: @escaping @Sendable (Double?) -> Void
    ) async -> Result<ActionOutput, QuickActionError> {
        let fallback = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        do {
            let context = try ActionContext.make(fallbackOutputDirectory: fallback, options: options, machine: machine, progress: progress)
            defer { context.removeTemporaryDirectory() }
            // `run` is nonisolated, so it runs off the main actor (long text,
            // PDFKit) and sees this task's cancellation.
            return .success(try await action.run(input, context: context))
        } catch let error as QuickActionError {
            return .failure(error)
        } catch is CancellationError {
            return .failure(QuickActionError("Cancelled"))
        } catch {
            return .failure(QuickActionError(error.localizedDescription))
        }
    }

    /// Text and images are pasted into the target app, unless the result
    /// took long enough that the user may have moved on: then they are only
    /// copied, with a notification.
    @discardableResult
    private func deliver(
        _ result: Result<ActionOutput, QuickActionError>,
        of action: any QuickAction,
        sensitive: Bool,
        delivery: Delivery,
        startedAt: Date
    ) async -> Bool {
        let output: ActionOutput
        switch result {
        case .failure(let error):
            log.error("\(action.id, privacy: .public) failed: \(error.message, privacy: .public)")
            notifier.post(title: "\(action.title) failed", body: error.message)
            return true
        case .success(let value):
            output = value
        }

        let content: PasteContent
        switch output {
        case .done(let message):
            notifier.post(title: action.title, body: message)
            return true
        case .files(let urls):
            notifier.post(
                title: action.title,
                body: urls.count == 1 ? "Created \(urls[0].lastPathComponent)" : "Created \(urls.count) files",
                revealing: urls)
            return true
        case .snippet(let body):
            openSnippetEditor(body: body)
            return true
        case .saveCommand(let command):
            guard let file = await nameCommand(command) else {
                log.info("\(action.id, privacy: .public) not named")
                return true
            }
            return await deliver(.success(.confirm(file.confirmation)), of: action, sensitive: sensitive, delivery: delivery, startedAt: startedAt)
        case .confirm(let confirmation):
            guard await confirm(confirmation) else {
                log.info("\(action.id, privacy: .public) not confirmed")
                return true
            }
            // Like any background action: a progress card if it takes a
            // while, cancellable, a notification at the end.
            startJob(
                ConfirmedStep(of: action, confirmation: confirmation), input: .none, options: ActionOptionValues(),
                sensitive: sensitive, delivery: delivery,
                summary: confirmation.title.hasSuffix("?") ? String(confirmation.title.dropLast()) : confirmation.title)
            return true
        case .open(let url):
            openURL(url)
            return true
        case .reveal(let url):
            showInFinder(url)
            return true
        case .openWith(let url, let app):
            open(url, with: app)
            return true
        case .play(let url):
            playSound(url)
            return true
        case .handled:
            return true
        case .text(let text):
            content = .text(text)
        case .report(let report):
            content = .text(report.text)
        case .image(let png):
            content = .image(png)
        }

        // Only results that are kept on the clipboard are clips.
        let record = Paster.Recording.record(sensitive: sensitive)
        let target: NSRunningApplication?
        let replacing: Bool
        switch delivery {
        case .copy:
            pasting.write(content, recording: record)
            return true
        case .paste(let app):
            (target, replacing) = (app, false)
        case .replaceSelection(let app):
            (target, replacing) = (app, true)
        }

        let stillThere = target == nil || NSWorkspace.shared.frontmostApplication == target
        guard Date.now.timeIntervalSince(startedAt) < 5, stillThere else {
            pasting.write(content, recording: record)
            notifier.post(title: action.title, body: "The result is on the clipboard.")
            return true
        }
        return await pasting.deliver(content, .paste(.plainText), recording: record, restoringPasteboard: replacing, into: target)
    }

    /// The confirming button is the default (⏎) and marked destructive; Esc
    /// cancels. Cortex is activated for the alert and hands activation back
    /// afterwards.
    private static func showAlert(for confirmation: ActionConfirmation) async -> Bool {
        let alert = NSAlert()
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle)
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = confirmation.isDestructive
        NSApp.activate()
        let confirmed = alert.runModal() == .alertFirstButtonReturn
        NSApp.yieldActivationIfNoWindows(besides: alert.window)
        return confirmed
    }

    /// Asks for the name of a command to save until it is one that can be
    /// saved (one word, not taken), or nil when cancelled.
    private func nameCommand(_ command: String) async -> CommandFile? {
        var request = CommandNameRequest(command: command)
        while let name = await askCommandName(request) {
            do {
                return try CommandFile(command: command, trigger: name, directory: directory, existing: reservedCommands() + userCommands)
            } catch {
                request.name = name
                request.problem = (error as? QuickActionError)?.message ?? error.localizedDescription
            }
        }
        return nil
    }

    /// An alert with a text field for the name, which shows what was wrong
    /// with the last one. Activates Cortex like `showAlert`.
    private static func showNameAlert(for request: CommandNameRequest) async -> String? {
        let alert = NSAlert()
        alert.messageText = "Name the Command"
        let excerpt = request.command.count > 300 ? request.command.prefix(299) + "…" : request.command
        let explanation = "Type $ and the name in the palette to run:\n\(excerpt)"
        alert.informativeText = request.problem.map { "\($0).\n\n\(explanation)" } ?? explanation
        if request.problem != nil { alert.alertStyle = .warning }
        let field = NSTextField(string: request.name)
        field.placeholderString = "deploy"
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 22)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        let response = alert.runModal()
        NSApp.yieldActivationIfNoWindows(besides: alert.window)
        return response == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// For `.snippet` results, from the palette and from Shortcuts.
    /// `ActionOutput.reveal`: a folder opens in a Finder window, anything
    /// else is selected in its folder.
    func showInFinder(_ url: URL) {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path(percentEncoded: false))
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    /// `ActionOutput.openWith`, from the palette and from Shortcuts.
    func open(_ url: URL, with app: URL) {
        openWithApp(url, app)
    }

    func openSnippetEditor(body: String) {
        guard let editSnippet, canEditSnippets() else {
            notifier.post(title: "Snippets are unavailable", body: "Snippets are switched off, or the database could not be opened.")
            return
        }
        editSnippet(.new(body: body))
    }

    private func markUsed(_ id: String) {
        var entry = usage[id] ?? ActionUsage()
        entry.count += 1
        entry.lastUsedAt = .now
        usage[id] = entry
        if let data = try? JSONEncoder().encode(usage) {
            defaults.set(data, forKey: Self.usageKey)
        }
    }

    /// The step an action asked to confirm, run as a job under the action's
    /// name.
    private struct ConfirmedStep: QuickAction {
        let id: String
        let title: String
        let symbol: String
        let perform: @Sendable () async throws -> ActionOutput

        init(of action: any QuickAction, confirmation: ActionConfirmation) {
            id = action.id
            title = action.title
            symbol = action.symbol
            perform = confirmation.perform
        }

        func accepts(_ input: ActionInput) -> Bool { true }
        func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput { try await perform() }
    }

    /// What "Save as Command" asks for a name with.
    struct CommandNameRequest: Equatable {
        /// The command to save.
        var command: String
        /// What the field starts with: the name last given, if it had a problem.
        var name = ""
        /// What was wrong with that name.
        var problem: String?
    }

    // MARK: - Tools

    /// The command-line tools the built-in file actions use.
    static let tools: [(name: String, package: String, usedFor: String)] = [
        ("ffmpeg", "ffmpeg", "video and audio"),
        ("magick", "imagemagick", "WebP"),
        ("sips", "", "images"),
        ("zip", "", "ZIP"),
    ]
}
