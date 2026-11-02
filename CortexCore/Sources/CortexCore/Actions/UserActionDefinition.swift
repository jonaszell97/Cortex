import Foundation

/// A quick action or command defined by a TOML file in
/// `~/.config/cortex/actions/`. One format for `>` actions on the clipboard
/// or files and for `$` commands named by a trigger word:
///
/// ```toml
/// name = "Shrink video to 720p"
/// accepts = ["files"]                  # text, image, files, none
/// extensions = ["mov", "mp4"]          # optional: only these files
/// command = "ffmpeg -i {input} -vf scale=-2:720 {output}"
/// output_extension = "mp4"             # optional: {output}'s extension (default: the input's)
/// output_suffix = "-720p"              # optional: added to the input's name
/// output = "files"                     # optional: files, text or none
/// symbol = "film"                      # optional: SF Symbol
/// keywords = ["video", "small"]        # optional: more search words
/// ```
///
/// ```toml
/// name = "GitHub Repository"
/// trigger = "gh"                          # typed after $: $gh owner/repo
/// url = "https://github.com/{argument}"   # opens it; or a shell command:
/// # command = "~/bin/deploy.sh {argument}"
/// example = "owner/repo"                  # optional: shown as $gh owner/repo
/// argument = "required"                   # optional: required, optional or none
/// confirm = true                          # optional: ask before running
/// matches = "^[0-9]+$"                    # optional: suggested from clips like this
/// ```
///
/// `accepts` without `trigger` is a `>` action (`UserAction`) on what the
/// palette finds or is handed. `trigger` without `accepts` is a `$` command
/// (`UserCommand`) on what is typed after the trigger; `argument` then says
/// whether that is required (default if `{argument}` is used), optional or
/// none. Both: it is both, and `>` offers it for clipboard text only if it
/// `matches`.
///
/// Placeholders: `{argument}` (also `$1`) is text, percent-encoded in a
/// URL; `{input}` is the file (or a file holding the text or image),
/// `{inputs}` all files at once, `{output}` where to write the result. In a
/// command they are filled through environment variables (`ShellCommand`),
/// bare or inside double quotes; inside single quotes they are a problem.
/// Text also arrives on standard input.
public struct UserActionDefinition: Sendable, Equatable {
    public enum Target: Sendable, Equatable {
        /// Opened with the default app, after filling in `{argument}`.
        case url(String)
        /// Run with `/bin/zsh -c`.
        case shell(String)
    }

    public enum Output: String, Sendable, CaseIterable {
        /// The `{output}` files.
        case files
        /// Standard output, pasted.
        case text
        /// Standard output (or "done") as a notification.
        case none
    }

    public enum Argument: String, Sendable, CaseIterable {
        case required, optional, none

        var accepts: Set<ActionInput.Kind> {
            switch self {
            case .required: [.text]
            case .optional: [.text, .none]
            case .none: [.none]
            }
        }
    }

    public var name: String
    public var target: Target
    /// What it takes: `accepts`, or for a file with only a trigger what
    /// `argument` says.
    public var accepts: Set<ActionInput.Kind>
    /// `accepts` was given: it runs on what the palette finds or is handed,
    /// not only on what is typed.
    public var takesContext: Bool
    /// Lowercased, without dots; empty means any file.
    public var extensions: Set<String>
    public var output: Output?
    public var outputExtension: String?
    public var outputSuffix: String?
    public var trigger: String?
    public var example: String?
    public var confirm: Bool
    /// A regular expression clipboard text has to match for `>` to offer a
    /// file with a trigger on it, and that `$` suggests clips by.
    public var matches: String?
    public var symbol: String?
    public var keywords: [String]

    public init(
        name: String, target: Target, accepts: Set<ActionInput.Kind>, takesContext: Bool = true,
        extensions: Set<String> = [], output: Output? = nil, outputExtension: String? = nil, outputSuffix: String? = nil,
        trigger: String? = nil, example: String? = nil, confirm: Bool = false, matches: String? = nil,
        symbol: String? = nil, keywords: [String] = []
    ) {
        self.name = name
        self.target = target
        self.accepts = accepts
        self.takesContext = takesContext
        self.extensions = extensions
        self.output = output
        self.outputExtension = outputExtension
        self.outputSuffix = outputSuffix
        self.trigger = trigger
        self.example = example
        self.confirm = confirm
        self.matches = matches
        self.symbol = symbol
        self.keywords = keywords
    }

    static let knownKeys: Set<String> = [
        "name", "accepts", "extensions", "command", "url", "output", "output_extension", "output_suffix",
        "trigger", "example", "argument", "confirm", "matches", "symbol", "keywords",
    ]

    /// What the result is, given the input it runs on. Without `output`: the
    /// `{output}` file if the command mentions it, standard output for text
    /// input, and otherwise a notification. A file with only a trigger shows
    /// its standard output in a notification.
    public func resolvedOutput(for input: ActionInput.Kind) -> Output {
        if let output { return output }
        guard case .shell(let command) = target, takesContext else { return .none }
        if command.contains("{output}") { return .files }
        return input == .text ? .text : .none
    }

    // MARK: - Parsing

    /// Errors name the problem in words for the settings window.
    public static func parse(_ text: String) throws -> UserActionDefinition {
        try parse(TOMLTable(text))
    }

    static func parse(_ table: TOMLTable) throws -> UserActionDefinition {
        try table.rejectUnknown(knownKeys)
        guard let name = try table.string("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw QuickActionError("“name” is missing")
        }

        let trigger = try parseTrigger(table)
        let target = try parseTarget(table, hasTrigger: trigger != nil)
        let template = switch target {
        case .url(let url): url
        case .shell(let command): command
        }
        let usesArgument = template.contains("{argument}")

        let accepts: Set<ActionInput.Kind>
        let takesContext: Bool
        switch (try table.strings("accepts"), try parseArgument(table)) {
        case (let names, _?) where !names.isEmpty:
            throw QuickActionError("Give either “accepts” or “argument”, not both")
        case (let names, nil) where !names.isEmpty:
            accepts = try Set(names.map { name in
                guard let kind = ActionInput.Kind(rawValue: name) else {
                    throw QuickActionError("“accepts” has “\(name)”; use text, image, files or none")
                }
                return kind
            })
            takesContext = true
        case (_, let argument?):
            if argument == .none, usesArgument {
                throw QuickActionError("“argument” is none, but {argument} is used")
            }
            accepts = argument.accepts
            takesContext = false
        case (_, nil):
            guard trigger != nil else {
                throw QuickActionError("“accepts” is missing (any of: text, image, files, none)")
            }
            accepts = (usesArgument ? Argument.required : .none).accepts
            takesContext = false
        }
        if usesArgument, !accepts.contains(.text) {
            throw QuickActionError("{argument} is text, but “accepts” has no text")
        }

        let output = try table.string("output").map { value in
            guard let output = Output(rawValue: value) else {
                throw QuickActionError("“output” is “\(value)”; use files, text or none")
            }
            return output
        }
        switch target {
        case .url:
            if output != nil { throw QuickActionError("“output” is only for commands; a URL is opened") }
            if let placeholder = ["{input}", "{inputs}", "{output}"].first(where: template.contains) {
                throw QuickActionError("\(placeholder) is for commands; a URL gets {argument}")
            }
            if !accepts.isSubset(of: [.text, .none]) {
                throw QuickActionError("A URL gets text: “accepts” can only have text and none")
            }
        case .shell(let command):
            if !takesContext, let placeholder = ["{input}", "{inputs}", "{output}"].first(where: command.contains) {
                throw QuickActionError("\(placeholder) needs “accepts”; with only a trigger the command gets {argument}")
            }
            if output == .files, !command.contains("{output}") {
                throw QuickActionError("“output” is files, but the command never writes to {output}")
            }
            if let quoted = ShellCommand.placeholders(in: command).first(where: { $0.quoting == .single }) {
                throw QuickActionError("{\(quoted.name)} is inside single quotes, where the shell cannot fill it in; use double quotes")
            }
        }

        let example = try table.string("example")?.trimmingCharacters(in: .whitespaces)
        if example != nil, trigger == nil {
            throw QuickActionError("“example” shows how to type the trigger; there is no “trigger”")
        }
        let matches = try table.string("matches")
        if let matches {
            guard (try? Regex(matches)) != nil else {
                throw QuickActionError("“matches” is not a regular expression")
            }
        }
        let extensions = try table.strings("extensions").map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }

        return UserActionDefinition(
            name: name, target: target, accepts: accepts, takesContext: takesContext, extensions: Set(extensions),
            output: output,
            outputExtension: try table.string("output_extension")?.trimmingCharacters(in: CharacterSet(charactersIn: ".")),
            outputSuffix: try table.string("output_suffix"),
            trigger: trigger, example: example, confirm: try table.bool("confirm") ?? false, matches: matches,
            symbol: try table.string("symbol"), keywords: try table.strings("keywords"))
    }

    private static func parseTrigger(_ table: TOMLTable) throws -> String? {
        guard var trigger = try table.string("trigger")?.trimmingCharacters(in: .whitespaces) else { return nil }
        // As typed in the palette, or with the `>` of an earlier version.
        if trigger.hasPrefix(">") || trigger.hasPrefix("$") { trigger.removeFirst() }
        guard !trigger.isEmpty, !trigger.contains(where: \.isWhitespace) else {
            throw QuickActionError("“trigger” must be one word, like “gh” for $gh")
        }
        return trigger
    }

    private static func parseTarget(_ table: TOMLTable, hasTrigger: Bool) throws -> Target {
        switch (try table.string("url"), try table.string("command")) {
        case (let url?, nil):
            _ = try UserAction.url(from: url, argument: "x")
            return .url(url)
        case (nil, let command?) where !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty:
            return .shell(command)
        case (_?, _?):
            throw QuickActionError("Give either “url” or “command”, not both")
        default:
            throw QuickActionError(hasTrigger ? "“url” or “command” is missing" : "“command” is missing")
        }
    }

    private static func parseArgument(_ table: TOMLTable) throws -> Argument? {
        try table.string("argument").map { value in
            guard let argument = Argument(rawValue: value) else {
                throw QuickActionError("“argument” is “\(value)”; use required, optional or none")
            }
            return argument
        }
    }
}

/// Typed access to the keys of an action file, with errors in words.
struct TOMLTable {
    let values: [String: TOML.Value]

    init(_ text: String) throws {
        do {
            values = try TOML.parse(text)
        } catch let error as TOML.ParseError {
            throw QuickActionError(error.description)
        }
    }

    var keys: [String] { values.keys.sorted() }

    func rejectUnknown(_ known: Set<String>) throws {
        if let unknown = keys.first(where: { !known.contains($0) }) {
            throw QuickActionError("Unknown key “\(unknown)”")
        }
    }

    func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil: return nil
        case .string(let value): return value
        default: throw QuickActionError("“\(key)” must be a string")
        }
    }

    func strings(_ key: String) throws -> [String] {
        switch values[key] {
        case nil: return []
        case .string(let value): return [value]
        case .array(let values):
            return try values.map {
                guard case .string(let value) = $0 else { throw QuickActionError("“\(key)” must be a list of strings") }
                return value
            }
        default: throw QuickActionError("“\(key)” must be a list of strings")
        }
    }

    func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil: return nil
        case .bool(let value): return value
        default: throw QuickActionError("“\(key)” must be true or false")
        }
    }
}
