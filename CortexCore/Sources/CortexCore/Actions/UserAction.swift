import Foundation

/// An action from a TOML file with `accepts` (`UserActionDefinition`). A
/// file with a `trigger` is also, or only, a `UserCommand`.
public struct UserAction: QuickAction {
    public let definition: UserActionDefinition
    /// The file it was read from.
    public let file: URL

    public init(definition: UserActionDefinition, file: URL) {
        self.definition = definition
        self.file = file
    }

    public var id: String { "user." + file.deletingPathExtension().lastPathComponent }
    public var title: String { definition.name }
    public var keywords: [String] { definition.keywords }

    public var symbol: String {
        if let symbol = definition.symbol { return symbol }
        if case .url = definition.target { return "link" }
        return "terminal"
    }

    /// Opening a URL is previewed (it is only built), and so is anything
    /// that asks first (the question is). Commands run when chosen.
    public var isInstant: Bool {
        if case .url = definition.target { return true }
        return definition.confirm
    }

    public func accepts(_ input: ActionInput) -> Bool {
        guard definition.accepts.contains(input.kind) else { return false }
        switch input {
        case .files(let urls):
            guard !urls.isEmpty else { return false }
            return definition.extensions.isEmpty || urls.allSatisfy { definition.extensions.contains($0.pathExtension.lowercased()) }
        case .text(let text):
            return !text.isEmpty
        case .image, .none:
            return true
        }
    }

    /// With `matches`, only text it matches; without, any input unless the
    /// file has a trigger too and the input is text (which would be any
    /// text: it waits for `$` instead).
    public func matches(_ input: ActionInput) -> Bool {
        if let pattern = definition.matches, let regex = try? Regex(pattern) {
            return input.text.map { (try? regex.firstMatch(in: $0)) != nil } ?? true
        }
        return definition.trigger == nil || input.kind != .text
    }

    public func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        switch definition.target {
        case .url(let template):
            let url = try Self.url(from: template, argument: input.text ?? "")
            guard definition.confirm else { return .open(url) }
            return .confirm(ActionConfirmation(
                title: "Open \(definition.name)?", message: url.absoluteString, confirmTitle: "Open") { .open(url) })
        case .shell:
            #if os(macOS)
            let runner = UserActionRunner(action: self, input: input, context: context)
            guard definition.confirm else { return try await runner.run() }
            return .confirm(ActionConfirmation(
                title: "Run \(definition.name)?", message: runner.command, confirmTitle: "Run") { try await runner.run() })
            #else
            throw QuickActionError("Shell actions only run on the Mac")
            #endif
        }
    }

    #if os(macOS)
    /// Runs the shell command now, without asking again: the step a
    /// confirmation guards. It makes its own scratch space, which the
    /// confirmation outlives.
    public func runConfirmed(_ input: ActionInput) async throws -> ActionOutput {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let context = try ActionContext.make(fallbackOutputDirectory: downloads)
        defer { context.removeTemporaryDirectory() }
        return try await UserActionRunner(action: self, input: input, context: context).run()
    }
    #endif

    /// Fills in the argument, percent-encoded so that it stays one part of
    /// the URL (a query value, or a path like `owner/repo`).
    static func url(from template: String, argument: String) throws -> URL {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))
        let encoded = argument.addingPercentEncoding(withAllowedCharacters: allowed) ?? argument
        let string = template.replacingOccurrences(of: "{argument}", with: encoded)
        guard let url = URL(string: string), url.scheme != nil else {
            throw QuickActionError("“\(string)” is not a URL")
        }
        return url
    }
}

#if os(macOS)
private struct UserActionRunner: Sendable {
    let action: UserAction
    let input: ActionInput
    let context: ActionContext

    var definition: UserActionDefinition { action.definition }

    var template: String {
        guard case .shell(let command) = definition.target else { return "" }
        return command
    }

    /// The command with the text as `{argument}`, as a confirmation shows it.
    var command: String {
        ShellCommand.display(template, ["argument": input.text ?? ""])
    }

    func run() async throws -> ActionOutput {
        let output = definition.resolvedOutput(for: input.kind)
        switch input {
        case .none:
            let result = try await shell([:], inputs: [], currentDirectory: nil, stdin: nil)
            return finish(output, texts: [result.outputText], files: [])
        case .text(let text):
            let file = context.temporaryDirectory.appending(path: "input.txt")
            try Data(text.utf8).write(to: file)
            return try await runOnFiles([file], outputDirectory: context.fallbackOutputDirectory, stdin: Data(text.utf8), output: output)
        case .image:
            let (files, directory) = try FileAction.materialize(input, context: context)
            return try await runOnFiles(files, outputDirectory: directory, stdin: nil, output: output)
        case .files(let urls):
            return try await runOnFiles(urls, outputDirectory: nil, stdin: nil, output: output)
        }
    }

    /// Once per file, or once for all with `{inputs}`.
    private func runOnFiles(_ files: [URL], outputDirectory: URL?, stdin: Data?, output: UserActionDefinition.Output) async throws -> ActionOutput {
        let batches = template.contains("{inputs}") ? [files] : files.map { [$0] }
        var texts: [String] = []
        var results: [URL] = []
        for (index, batch) in batches.enumerated() {
            try Task.checkCancellation()
            context.progress(Double(index) / Double(batches.count))
            let source = batch[0]
            let step = FileStep(
                sources: batch, source: source,
                outputDirectory: outputDirectory ?? source.deletingLastPathComponent(),
                temporaryDirectory: context.temporaryDirectory, progress: { _ in })
            var values = ["input": source.path]
            if output == .files {
                let pathExtension = definition.outputExtension ?? source.pathExtension
                results.append(try await step.produce(suffix: definition.outputSuffix ?? "", pathExtension: pathExtension) { scratch in
                    values["output"] = scratch.path
                    _ = try await shell(values, inputs: batch, currentDirectory: source.deletingLastPathComponent(), stdin: stdin)
                })
            } else {
                values["output"] = context.temporaryDirectory.appending(path: "output").path
                let result = try await shell(values, inputs: batch, currentDirectory: source.deletingLastPathComponent(), stdin: stdin)
                texts.append(result.outputText)
            }
        }
        context.progress(1)
        return finish(output, texts: texts, files: results)
    }

    private func finish(_ output: UserActionDefinition.Output, texts: [String], files: [URL]) -> ActionOutput {
        switch output {
        case .files:
            return .files(files)
        case .text:
            var text = texts.joined()
            // Commands end their output with a line break; pasting it rarely helps.
            if text.hasSuffix("\n") { text.removeLast() }
            return .text(text)
        case .none:
            return .done("\(definition.name): done")
        }
    }

    private func shell(_ values: [String: String], inputs: [URL], currentDirectory: URL?, stdin: Data?) async throws -> ProcessResult {
        var values = values
        values["argument"] = input.text ?? ""
        // The text is also `$1`.
        let script = ShellCommand.script(
            template, values, inputs: inputs.map(\.path), arguments: input.text.map { [$0] } ?? [])
        let result = try await ProcessRunner.run(
            URL(filePath: "/bin/zsh"), arguments: ["-c", script.source, "zsh"] + script.arguments, input: stdin,
            currentDirectory: currentDirectory ?? FileManager.default.homeDirectoryForCurrentUser,
            environment: ToolLocator.environment.merging(script.environment) { $1 })
        guard result.status == 0 else {
            let detail = result.errorSummary()
            throw QuickActionError("\(definition.name) failed (exit \(result.status))" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result
    }
}
#endif

/// The placeholders of a shell command. Their values never become part of
/// the shell source: `{input}` turns into `"${CORTEX_INPUT}"` with the path
/// in the environment, `{inputs}` into an array taken from the arguments. A
/// file name or text can then hold anything (quotes, `$(…)`, even
/// `{input}`) and stays one word.
public enum ShellCommand {
    public static let names = ["argument", "input", "inputs", "output"]

    /// What to run: `zsh -c source zsh arguments…`, with `environment` added.
    public struct Script: Sendable, Equatable {
        public var source: String
        public var environment: [String: String]
        public var arguments: [String]
    }

    public enum Quoting: Sendable, Equatable {
        case none, double, single
    }

    /// A placeholder in a command, and how the shell reads the place it is
    /// in. One the author quoted alone (`"{input}"`, `'{input}'`) counts as
    /// unquoted, its quotes included in `range`.
    public struct Placeholder: Sendable, Equatable {
        public var name: String
        public var range: Range<Int>
        public var quoting: Quoting
    }

    /// `it's` → `'it'\''s'`: safe in any position of a POSIX shell command.
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The environment variable for a placeholder: `CORTEX_INPUT`.
    public static func variable(_ name: String) -> String {
        "CORTEX_" + name.uppercased()
    }

    /// The command to run. `values` fills `{argument}`, `{input}` and
    /// `{output}`; `arguments` are `$1`…; `inputs` fill `{inputs}`.
    public static func script(
        _ template: String, _ values: [String: String], inputs: [String] = [], arguments: [String] = []
    ) -> Script {
        let characters = Array(template)
        let found = placeholders(in: characters)
        var source = fill(characters, found) { placeholder in
            let reference = placeholder.name == "inputs" ? "${cortex_inputs[@]}" : "${\(variable(placeholder.name))}"
            switch placeholder.quoting {
            case .none: return "\"\(reference)\""
            case .double: return reference
            case .single: return "{\(placeholder.name)}"
            }
        }
        var positional = arguments
        if found.contains(where: { $0.name == "inputs" }) {
            // The inputs follow the arguments; `$1`… stay what they were.
            let first = arguments.count + 1
            source = "cortex_inputs=(\"${@[\(first),-1]}\"); set -- \"${@[1,\(first - 1)]}\"\n" + source
            positional += inputs
        }
        let environment = Dictionary(uniqueKeysWithValues: values.map { (variable($0.key), $0.value) })
        return Script(source: source, environment: environment, arguments: positional)
    }

    /// The command as the palette and confirmations show it: the values
    /// quoted in place. For reading only; `script` is what runs.
    public static func display(_ template: String, _ values: [String: String], inputs: [String]? = nil) -> String {
        let characters = Array(template)
        return fill(characters, placeholders(in: characters)) { placeholder in
            let raw = placeholder.name == "inputs" ? inputs : values[placeholder.name].map { [$0] }
            guard let raw, placeholder.quoting != .single else { return "{\(placeholder.name)}" }
            return placeholder.quoting == .none ? raw.map(quote).joined(separator: " ") : raw.joined(separator: " ")
        }
    }

    public static func placeholders(in template: String) -> [Placeholder] {
        placeholders(in: Array(template))
    }

    /// Follows quotes, `$'…'`, backslashes, `$(…)` and comments well enough
    /// to tell where a placeholder sits. `${input}` is the shell's own
    /// variable and `\{input}` an escaped brace; neither is a placeholder.
    static func placeholders(in characters: [Character]) -> [Placeholder] {
        var found: [Placeholder] = []
        var quoting = Quoting.none
        var quoteStart = -1
        var ansi = false
        var substitutions: [(outer: Quoting, parens: Int)] = []
        var index = 0

        func name(at index: Int) -> String? {
            guard characters[index] == "{", index == 0 || characters[index - 1] != "$" else { return nil }
            return names.first { name in
                let end = index + name.count + 2
                return end <= characters.count && String(characters[index..<end]) == "{\(name)}"
            }
        }

        while index < characters.count {
            let character = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : nil
            if let name = name(at: index) {
                let end = index + name.count + 2
                let closing: Character? = quoting == .double ? "\"" : quoting == .single && !ansi ? "'" : nil
                if let closing, quoteStart == index - 1, end < characters.count, characters[end] == closing {
                    found.append(Placeholder(name: name, range: quoteStart..<end + 1, quoting: .none))
                    quoting = .none
                    index = end + 1
                } else {
                    found.append(Placeholder(name: name, range: index..<end, quoting: quoting))
                    index = end
                }
                continue
            }
            switch quoting {
            case .single:
                if ansi, character == "\\" {
                    index += 1
                } else if character == "'" {
                    quoting = .none
                    ansi = false
                }
            case .double:
                if character == "\\" {
                    index += 1
                } else if character == "\"" {
                    quoting = .none
                } else if character == "$", next == "(" {
                    substitutions.append((.double, 0))
                    quoting = .none
                    index += 1
                }
            case .none:
                switch character {
                case "\\":
                    index += 1
                case "'", "\"":
                    quoting = character == "'" ? .single : .double
                    quoteStart = index
                case "$" where next == "'":
                    quoting = .single
                    ansi = true
                    index += 1
                case "$" where next == "(":
                    substitutions.append((.none, 0))
                    index += 1
                case "(" where !substitutions.isEmpty:
                    substitutions[substitutions.count - 1].parens += 1
                case ")" where !substitutions.isEmpty:
                    if substitutions[substitutions.count - 1].parens == 0 {
                        quoting = substitutions.removeLast().outer
                    } else {
                        substitutions[substitutions.count - 1].parens -= 1
                    }
                case "#" where index == 0 || characters[index - 1].isWhitespace || ";&|(".contains(characters[index - 1]):
                    while index + 1 < characters.count, characters[index + 1] != "\n" { index += 1 }
                default:
                    break
                }
            }
            index += 1
        }
        return found
    }

    private static func fill(
        _ characters: [Character], _ placeholders: [Placeholder], _ replacement: (Placeholder) -> String
    ) -> String {
        var result = ""
        var position = 0
        for placeholder in placeholders {
            result += String(characters[position..<placeholder.range.lowerBound]) + replacement(placeholder)
            position = placeholder.range.upperBound
        }
        return result + String(characters[position...])
    }
}

/// Reads the action files from a directory.
public enum UserActionLibrary {
    public struct Problem: Sendable, Equatable, Identifiable {
        public var file: URL
        public var message: String
        public var id: URL { file }
    }

    public struct Contents: Sendable {
        /// The files with `accepts`.
        public var actions: [UserAction]
        /// The files with a `trigger` (a file with both is in both).
        public var commands: [UserCommand]
        public var problems: [Problem]
    }

    /// `$XDG_CONFIG_HOME/cortex/actions`, or `~/.config/cortex/actions`.
    public static func defaultDirectory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        let config = environment["XDG_CONFIG_HOME"].map { URL(filePath: $0, directoryHint: .isDirectory) }
            ?? URL.homeDirectory.appending(path: ".config", directoryHint: .isDirectory)
        return config.appending(path: "cortex/actions", directoryHint: .isDirectory)
    }

    /// Every `*.toml` file, sorted by name. A file that does not parse is
    /// reported and skipped; the others still load. So is a file whose
    /// trigger a command in `reserved` (the built-ins) or an earlier file
    /// already has as its name.
    public static func load(
        from directory: URL, reserved: [any Command] = CommandCatalog.builtIns, fileManager: FileManager = .default
    ) -> Contents {
        let files = ((try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "toml" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var contents = Contents(actions: [], commands: [], problems: [])
        for file in files {
            do {
                let definition = try UserActionDefinition.parse(try String(contentsOf: file, encoding: .utf8))
                if definition.trigger != nil {
                    let command = UserCommand(definition: definition, file: file)
                    let all: [any Command] = reserved + contents.commands + [command]
                    if let problem = CommandCatalog.problems(in: all).first(where: { $0.id == command.id }) {
                        throw QuickActionError(problem.message)
                    }
                    contents.commands.append(command)
                }
                if definition.takesContext {
                    contents.actions.append(UserAction(definition: definition, file: file))
                }
            } catch let error as QuickActionError {
                contents.problems.append(Problem(file: file, message: error.message))
            } catch {
                contents.problems.append(Problem(file: file, message: error.localizedDescription))
            }
        }
        return contents
    }
}
