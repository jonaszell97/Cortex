import Foundation

/// A `$` command (docs/modules/COMMANDS.md, "The command protocol"): it works
/// on what is typed after its name or filled into its form, never on the
/// clipboard or a selection. It does not run: it *resolves* to a
/// `CommandOutcome` that says what ⏎ does, and Quick Actions carries that out
/// (`CommandAction`): previews, confirmations, jobs, usage counts and
/// delivery are those of quick actions.
public protocol Command: Sendable {
    /// Stable across launches: usage counts and remembered options are stored
    /// under it ("command.port").
    var id: String { get }
    /// The word after `$`: "port". Lowercase, no whitespace, unique among
    /// all commands. The row shows it as `$port 3000` (with the argument's
    /// placeholder).
    var name: String { get }
    var title: String { get }
    /// One sentence for the pane and the form: "Ends what listens on a port."
    var summary: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    /// More words search finds it by.
    var keywords: [String] { get }
    /// The main input: what is typed after the name, or the form's first
    /// field. nil: the command takes none (`$mem`).
    var argument: CommandArgument? { get }
    /// The form's other fields, remembered per command; their values are in
    /// `CommandInvocation.options`.
    var options: [ActionOption] { get }
    /// Whether it runs on a host too: `@pi` after its name picks one
    /// (`$mem @pi`), and the form has a Host field. Only these commands
    /// get another `CommandInvocation.machine`.
    var runsOnHosts: Bool { get }
    /// What ⏎ is called in the hints bar where the outcome does not say it:
    /// "Open in VS Code" for a link `$code` opens, "Pick Colour" for a
    /// handoff. nil: the outcome's own ("Paste", "Open", "Start").
    var verb: String? { get }
    /// Sends its input to an online service (the AI commands): never run on
    /// sensitive input.
    var isRemote: Bool { get }
    /// The argument when it runs on `machine`, where it may be another
    /// (`$disk` takes a volume here and a path on a host). By default
    /// the same.
    func argument(on machine: Machine) -> CommandArgument?
    /// Whether it takes this input.
    func accepts(_ input: ActionInput) -> Bool
    /// Whether `>` may offer it on this context input. Never, unless the
    /// command says otherwise (a copied port number for `$port`).
    func matches(_ input: ActionInput) -> Bool
    /// What ⏎ will do on this invocation. Called while the command is
    /// selected, so it is cheap and changes nothing: looking things up is
    /// fine (`$port` asks `lsof`), anything slow or with an effect (a
    /// download, a request to an AI vendor, ending a process) belongs in the
    /// outcome's `perform` or `run`. Throws what is wrong with the input, or
    /// `QuickActionError.notice` when there is only nothing to do.
    func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome
}

public extension Command {
    var summary: String { "" }
    var keywords: [String] { [] }
    var argument: CommandArgument? { nil }
    var options: [ActionOption] { [] }
    var runsOnHosts: Bool { false }
    var verb: String? { nil }
    var isRemote: Bool { false }
    func argument(on machine: Machine) -> CommandArgument? { argument }

    /// Derived from the argument: text for one that is typed, files for a
    /// path, and nothing when it is optional or there is none. A number or
    /// a choice is taken as any text; one that is not valid is the resolve
    /// error.
    func accepts(_ input: ActionInput) -> Bool {
        guard let argument else { return input == .none }
        switch input {
        case .none:
            return !argument.isRequired
        case .text(let text):
            return argument.kind != .path && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .files(let urls):
            return argument.kind == .path && !urls.isEmpty
        case .image:
            return false
        }
    }

    /// Never offered in `>`, unless the command says otherwise (a copied
    /// port number for `$port`).
    func matches(_ input: ActionInput) -> Bool { false }

    /// How it is typed, for its row: "port 3000", or "mem" without an
    /// argument.
    var usage: String {
        guard let placeholder = argument?.placeholder, !placeholder.isEmpty else { return name }
        return "\(name) \(placeholder)"
    }

    /// `typed` (what follows the name, nil for nothing) as the command's
    /// input: a path for a `.path` argument (`ActionInput.typed`, so `~/`
    /// works), otherwise text.
    func input(typed: String?) -> ActionInput {
        guard let argument, let typed = typed?.trimmingCharacters(in: .whitespaces), !typed.isEmpty else { return .none }
        return argument.kind == .path ? .typed(typed) : .text(typed)
    }
}

/// A command's main input (docs/modules/COMMANDS.md, "The command protocol").
public struct CommandArgument: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// One line.
        case text
        /// Several lines; ⇧⏎ breaks a line in the form.
        case prompt
        /// A whole number in the range.
        case number(ClosedRange<Int>)
        /// An existing file or folder. Runs on `.files([url])`.
        case path
        /// One of these, looked up when the form opens (`$disk`: the
        /// mounted volumes), or a path when the choices allow one (`$code`).
        case choice(CommandChoices)
    }

    /// "Port".
    public var title: String
    /// "3000": in the row (`$port 3000`) and the empty field.
    public var placeholder: String
    public var kind: Kind
    public var isRequired: Bool
    /// Where the form may suggest values from
    /// (docs/modules/COMMANDS.md, "Suggestions").
    public var suggestions: CommandSuggestions

    public init(
        title: String, placeholder: String, kind: Kind = .text, isRequired: Bool = true,
        suggestions: CommandSuggestions = .none
    ) {
        self.title = title
        self.placeholder = placeholder
        self.kind = kind
        self.isRequired = isRequired
        self.suggestions = suggestions
    }

    /// Whether it takes a file or folder: a path, or a choice that also
    /// takes one. A file dropped onto the palette fills it in.
    public var takesPaths: Bool {
        switch kind {
        case .path: true
        case .choice(let choices): choices.allowsPaths
        default: false
        }
    }
}

/// The choices of a `.choice` argument, loaded when the form opens.
/// Equatable by `id`.
public struct CommandChoices: Sendable, Equatable {
    public let id: String
    /// An existing file or folder (absolute or `~/`) is taken too, as typed
    /// text: `$code ~/notes.md` as well as `$code cortex`.
    public let allowsPaths: Bool
    public let load: @Sendable () async -> [ActionOption.Choice]

    public init(id: String, allowsPaths: Bool = false, load: @escaping @Sendable () async -> [ActionOption.Choice]) {
        self.id = id
        self.allowsPaths = allowsPaths
        self.load = load
    }

    public static func == (lhs: CommandChoices, rhs: CommandChoices) -> Bool {
        lhs.id == rhs.id
    }

    /// The choice typed text means: by title, else by value, ignoring case
    /// (`$disk macintosh hd`), else the only title that starts with it
    /// (`$code wish` when one project's name starts with "wish").
    public static func match(_ text: String, in choices: [ActionOption.Choice]) -> ActionOption.Choice? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exact = choices.first(where: { $0.title.caseInsensitiveCompare(text) == .orderedSame })
            ?? choices.first(where: { $0.value.caseInsensitiveCompare(text) == .orderedSame }) {
            return exact
        }
        let started = startingWith(text, in: choices)
        return started.count == 1 ? started[0] : nil
    }

    /// The choices whose title starts with `text`, ignoring case and
    /// diacritics; none for no text.
    public static func startingWith(_ text: String, in choices: [ActionOption.Choice]) -> [ActionOption.Choice] {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }
        return choices.filter { $0.title.range(of: text, options: [.anchored, .caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The choice `text` names (`match`), or why there is none: several
    /// start with it, there are none at all (`none`), or none is called
    /// that (`$code nope`: "No project is called “nope”. Projects: …").
    public static func pick(_ text: String, in choices: [ActionOption.Choice], noun: String, none: String) throws -> ActionOption.Choice {
        let text = text.trimmingCharacters(in: .whitespaces)
        if let choice = match(text, in: choices) { return choice }
        let started = startingWith(text, in: choices)
        if started.count > 1 {
            throw QuickActionError("“\(text)” could be " + list(started.map(\.title)) + ": type more of the name")
        }
        guard !choices.isEmpty else { throw QuickActionError(none) }
        throw QuickActionError("No \(noun) is called “\(text)”. \(noun.capitalized)s: " + list(choices.map(\.title)))
    }

    /// "a, b, c" or "a, b, … and 12 more".
    private static func list(_ names: [String], limit: Int = 8) -> String {
        guard names.count > limit else { return names.joined(separator: ", ") }
        return names.prefix(limit).joined(separator: ", ") + " and \(names.count - limit) more"
    }
}

/// Where a form field may suggest values from (docs/modules/COMMANDS.md,
/// "Suggestions"). A suggestion is only ever a value put into the field; nothing
/// runs on one that was not picked.
public enum CommandSuggestions: Sendable, Equatable {
    case none
    /// The pasteboard, then the recent text clips, whose whole trimmed text
    /// matches this regular expression.
    case clips(matching: String)
    /// The pasteboard's text, as one entry.
    case clipboardText
    /// The argument's own choices.
    case choices
}
