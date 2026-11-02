import Foundation

/// A `$` command from a TOML file with a `trigger` (`UserActionDefinition`):
/// `$gh owner/repo`. `argument` (or `accepts`, for a file that is also a `>`
/// action) says what it takes, `example` is the argument's placeholder and
/// `matches` what the form suggests from recent clips.
public struct UserCommand: Command {
    public let definition: UserActionDefinition
    /// The file it was read from.
    public let file: URL

    public init(definition: UserActionDefinition, file: URL) {
        self.definition = definition
        self.file = file
    }

    /// The same as the file's `>` action, so a file with both counts its
    /// uses once.
    public var id: String { "user." + file.deletingPathExtension().lastPathComponent }
    public var name: String { definition.trigger ?? "" }
    public var title: String { definition.name }
    public var keywords: [String] { definition.keywords }
    public var symbol: String { action.symbol }

    /// Text when it takes text, a path when it takes only files, none when
    /// it takes neither; required unless it also takes nothing.
    public var argument: CommandArgument? {
        let accepts = definition.accepts
        let kind: CommandArgument.Kind
        if accepts.contains(.text) {
            kind = .text
        } else if accepts.contains(.files) {
            kind = .path
        } else {
            return nil
        }
        return CommandArgument(
            title: "Argument", placeholder: definition.example ?? "…", kind: kind,
            isRequired: !accepts.contains(.none), suggestions: definition.matches.map { .clips(matching: $0) } ?? .none)
    }

    /// What `accepts` (or `argument`) and `extensions` allow.
    public func accepts(_ input: ActionInput) -> Bool {
        action.accepts(input)
    }

    /// A URL is opened (after asking, with `confirm = true`); a shell command
    /// is a job that shows the line it runs (or asks first, with `confirm =
    /// true`). Nothing runs here.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let input = invocation.input
        switch definition.target {
        case .url(let template):
            let url = try UserAction.url(from: template, argument: input.text ?? "")
            guard definition.confirm else { return .open(.url(url)) }
            return .act(ActionConfirmation(
                title: "Open \(definition.name)?", message: url.absoluteString, confirmTitle: "Open") { .open(url) })
        case .shell(let template):
            #if os(macOS)
            return shellOutcome(template, input: input)
            #else
            _ = template
            throw QuickActionError("Shell commands only run on the Mac")
            #endif
        }
    }

    /// The file as a `>` action: how it opens a URL, what it accepts.
    private var action: UserAction {
        UserAction(definition: definition, file: file)
    }

    #if os(macOS)
    /// The job that runs the command, or the question that asks first. For
    /// one that runs in the home folder the plan is the line as it is; for a
    /// file that is also a `>` action it still has its `{input}` in it.
    private func shellOutcome(_ template: String, input: ActionInput) -> CommandOutcome {
        let line = ShellCommand.display(template, ["argument": input.text ?? ""])
        let (action, takesContext) = (action, definition.takesContext)
        guard definition.confirm else {
            return .job(plan: line) { context in
                if takesContext { return try await action.run(input, context: context) }
                return try await runInHome(input)
            }
        }
        return .act(ActionConfirmation(
            title: "Run \(definition.name)?", message: line, confirmTitle: "Run"
        ) {
            if takesContext { return try await action.runConfirmed(input) }
            return try await runInHome(input)
        })
    }

    /// Runs once in the home folder with the typed text as `{argument}` and
    /// `$1`.
    private func runInHome(_ input: ActionInput) async throws -> ActionOutput {
        guard case .shell(let template) = definition.target else { return .done("Done") }
        let argument = input.text ?? ""
        let script = ShellCommand.script(template, ["argument": argument], arguments: argument.isEmpty ? [] : [argument])
        let result = try await ProcessRunner.run(
            URL(filePath: "/bin/zsh"), arguments: ["-c", script.source, "zsh"] + script.arguments,
            currentDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ToolLocator.environment.merging(script.environment) { $1 })
        guard result.status == 0 else {
            let detail = result.errorSummary()
            throw QuickActionError("\(definition.name) failed (exit \(result.status))" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        var text = result.outputText
        // Commands end their output with a line break; pasting it rarely helps.
        if text.hasSuffix("\n") { text.removeLast() }
        switch definition.resolvedOutput(for: input.kind) {
        case .text: return .text(text)
        case .none, .files: return .done(text.isEmpty ? "Done" : String(text.suffix(500)))
        }
    }
    #endif
}

