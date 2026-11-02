import Foundation

/// What a command is asked to resolve (docs/modules/COMMANDS.md, "The command
/// protocol"): what was typed or filled in, the form's other fields, and where
/// it runs.
public struct CommandInvocation: Sendable, Equatable {
    /// The argument, as `Command.input(typed:)` makes it.
    public var input: ActionInput
    /// The values of the command's `options`.
    public var options: ActionOptionValues
    /// This Mac, or the host `@pi` named; only a command that `runsOnHosts`
    /// is given another.
    public var machine: Machine

    public init(input: ActionInput = .none, options: ActionOptionValues = ActionOptionValues(), machine: Machine = .local) {
        self.input = input
        self.options = options
        self.machine = machine
    }
}

/// The result of a command that has one to show: ⏎ pastes it and ⌥⏎ copies
/// it, exactly as shown.
public enum CommandValue: Sendable, Equatable {
    case text(String)
    /// Text that is a secret (`$token`): pasted and copied like text, but
    /// recorded as a sensitive clip.
    case secret(String)
    /// Text that the palette may draw as a view of its own (`$disk`).
    case report(ActionReport)
    /// PNG data.
    case image(Data)

    /// What is pasted or copied as text; nil for an image.
    public var text: String? {
        switch self {
        case .text(let text), .secret(let text): text
        case .report(let report): report.text
        case .image: nil
        }
    }

    public var isSecret: Bool {
        if case .secret = self { return true }
        return false
    }

    /// The same result as a quick action's output.
    public var output: ActionOutput {
        switch self {
        case .text(let text), .secret(let text): .text(text)
        case .report(let report): .report(report)
        case .image(let png): .image(png)
        }
    }
}

/// Something ⏎ opens or plays.
public enum OpenTarget: Sendable, Equatable {
    /// A web page or app link, with its default app (`$code`).
    case url(URL)
    /// A file or folder in Finder (`$open`): a folder opens in a window,
    /// anything else is selected in its folder.
    case reveal(URL)
    /// A file or folder with this app (`$term`).
    case openWith(URL, app: URL)
    /// A sound or movie file's sound (`$sound`).
    case play(URL)

    /// What ⌥⏎ copies instead of opening: the link, or the path.
    public var copyText: String {
        switch self {
        case .url(let url): url.absoluteString
        case .reveal(let url), .openWith(let url, _), .play(let url): url.path(percentEncoded: false)
        }
    }

    /// The hint for ⌥⏎: "Copy link", "Copy path".
    public var copyLabel: String {
        if case .url = self { return "Copy link" }
        return "Copy path"
    }

    /// The hint for ⏎ unless the command names it: "Open", "Show in Finder",
    /// "Open in Terminal", "Play".
    public var verb: String {
        switch self {
        case .url: "Open"
        case .reveal: "Show in Finder"
        case .openWith(_, let app): "Open in " + app.deletingPathExtension().lastPathComponent
        case .play: "Play"
        }
    }

    /// The same step as a quick action's output.
    public var output: ActionOutput {
        switch self {
        case .url(let url): .open(url)
        case .reveal(let url): .reveal(url)
        case .openWith(let url, let app): .openWith(url, app: app)
        case .play(let url): .play(url)
        }
    }
}

/// What ⏎ does for a command on what is typed (docs/modules/COMMANDS.md, "The
/// command protocol"). The outcome, not the command, decides the preview, the
/// hints, the confirmation, the progress and the delivery.
///
/// Resolving one is cheap and changes nothing: anything slow or with an effect
/// lives inside it, in `act`'s `perform`, `job`'s `run` or `handoff`'s `run`.
public enum CommandOutcome: Sendable, Equatable {
    /// A result to show, paste (⏎) or copy (⌥⏎). `refresh`: how often it is
    /// worth resolving again while it is selected (`$cpu`: 2 seconds).
    case value(CommandValue, refresh: Duration? = nil)
    /// Something to open or play on ⏎.
    case open(OpenTarget)
    /// Affects something (processes, containers): ⏎ asks first, then does it.
    case act(ActionConfirmation)
    /// Takes a while or contacts a service: ⏎ starts it in the background
    /// with a progress card, and its output is delivered as a quick action's
    /// is. `plan` says what it will do.
    case job(plan: String, run: @Sendable (ActionContext) async throws -> ActionOutput)
    /// Hands over to something that delivers the result itself (the
    /// eyedropper of `$color`): nothing to paste. `description` says what
    /// happens.
    case handoff(description: String, run: @Sendable () async throws -> Void)

    /// Which kind of outcome, for hints and layout.
    public enum Kind: String, Sendable, CaseIterable {
        case value, open, act, job, handoff
    }

    public var kind: Kind {
        switch self {
        case .value: .value
        case .open: .open
        case .act: .act
        case .job: .job
        case .handoff: .handoff
        }
    }

    /// What the hints bar says ⏎ and ⌥⏎ do for this outcome (the second is
    /// nil where ⌥⏎ does nothing):
    ///
    /// - a value is pasted (⏎) or copied (⌥⏎);
    /// - open: the command's `verb` or the target's ("Open in VS Code"), and
    ///   ⌥⏎ copies the link or path;
    /// - act: the confirming button and "…", as it asks first ("Kill…");
    /// - a job starts, and ⌥⏎ copies its text result;
    /// - a handoff is the command's `verb` ("Pick Colour").
    public func keys(of command: any Command) -> Keys {
        switch self {
        case .value: Keys("Paste", option: "Copy")
        case .open(let target): Keys(command.verb ?? target.verb, option: target.copyLabel)
        case .act(let confirmation): Keys(confirmation.confirmTitle + "…")
        case .job: Keys("Start", option: "Start and copy")
        case .handoff: Keys(command.verb ?? "Run")
        }
    }

    /// What ⏎ and ⌥⏎ are called in the hints bar.
    public struct Keys: Sendable, Equatable {
        public var primary: String
        /// nil: ⌥⏎ does nothing.
        public var option: String?

        public init(_ primary: String, option: String? = nil) {
            self.primary = primary
            self.option = option
        }
    }

    /// Equal when they say the same; the steps (`perform`, `run`) cannot be
    /// compared.
    public static func == (lhs: CommandOutcome, rhs: CommandOutcome) -> Bool {
        switch (lhs, rhs) {
        case (.value(let a, let aRefresh), .value(let b, let bRefresh)): a == b && aRefresh == bRefresh
        case (.open(let a), .open(let b)): a == b
        case (.act(let a), .act(let b)): a == b
        case (.job(let a, _), .job(let b, _)): a == b
        case (.handoff(let a, _), .handoff(let b, _)): a == b
        default: false
        }
    }
}
