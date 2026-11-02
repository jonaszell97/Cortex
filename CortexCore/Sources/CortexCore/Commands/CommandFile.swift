import Foundation

/// A shell command saved as a `$` command file by "Save as Command": the
/// selected text is the `command`, the name the user gives it the
/// `trigger`, in a new file of the actions folder.
///
/// ```toml
/// name = "docker compose up -d"
/// trigger = "up"
/// command = "docker compose up -d"
/// ```
///
/// The `name` (the title below `$up` in the palette) is the command's first
/// line. Like any command file, it takes what is typed after the trigger
/// only if the command uses `{argument}`.
public struct CommandFile: Sendable, Equatable {
    /// What runs.
    public let command: String
    /// The word typed after `$`.
    public let trigger: String
    /// Where it is saved; no file is there yet.
    public let file: URL
    /// The file's TOML.
    public let contents: String
    /// The file as it loads: what it takes, its title.
    public let definition: UserActionDefinition

    /// Checks that `trigger` is one word that names none of the `existing`
    /// commands (the built-ins, the other files'), and picks a file in
    /// `directory` named after it that does not exist yet (`deploy.toml`,
    /// else `deploy-2.toml`). Errors say what is wrong with the name.
    public init(
        command: String, trigger: String, directory: URL, existing: [any Command], fileManager: FileManager = .default
    ) throws {
        var trigger = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        // As typed in the palette.
        if trigger.hasPrefix("$") { trigger.removeFirst() }
        guard !trigger.isEmpty else { throw QuickActionError("Give it a name to type after $") }
        guard !trigger.contains(where: \.isWhitespace) else {
            throw QuickActionError("The name must be one word, like “deploy” for $deploy")
        }
        let contents = Self.contents(command: command, trigger: trigger)
        let definition = try UserActionDefinition.parse(contents)
        let file = Self.unusedFile(for: trigger, in: directory, fileManager: fileManager)
        let new = UserCommand(definition: definition, file: file)
        if let problem = CommandCatalog.problems(in: existing + [new]).first(where: { $0.id == new.id }) {
            throw QuickActionError(problem.message)
        }
        self.command = command
        self.trigger = trigger
        self.file = file
        self.contents = contents
        self.definition = definition
    }

    /// The selected text as the command to save: trimmed, without the `$ `
    /// prompt of text copied from a terminal or a README. Throws when it
    /// would not load as a command file (a placeholder in single quotes,
    /// `{input}`, which needs a file).
    public static func command(from text: String) throws -> String {
        var command = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = command.split(separator: "\n", omittingEmptySubsequences: false)
        let prompted = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !prompted.isEmpty, prompted.allSatisfy({ $0.hasPrefix("$ ") }) {
            command = lines.map { $0.hasPrefix("$ ") ? String($0.dropFirst(2)) : String($0) }
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !command.isEmpty else { throw QuickActionError("There is no command to save") }
        _ = try UserActionDefinition.parse(contents(command: command, trigger: "x"))
        return command
    }

    /// Asks before writing the file; confirmed, it writes it and says how
    /// to run it.
    public var confirmation: ActionConfirmation {
        let usage = definition.accepts.contains(.text) ? "$\(trigger) …" : "$\(trigger)"
        let path = (file.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
        var message = "\(usage) runs:\n\n\(Self.excerpt(command))\n\nSaved as \(path)"
        if definition.accepts.contains(.text) {
            message += "\n\nWhat is typed after $\(trigger) fills in {argument}."
        }
        return ActionConfirmation(title: "Save $\(trigger)?", message: message, confirmTitle: "Save", isDestructive: false) {
            try write()
            return .done("Saved \(file.lastPathComponent). Type $\(trigger) to run it.")
        }
    }

    /// Writes the file, never over another one.
    public func write(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try Data(contents.utf8).write(to: file, options: .withoutOverwriting)
        } catch CocoaError.fileWriteFileExists {
            throw QuickActionError("\(file.lastPathComponent) already exists")
        }
    }

    // MARK: - The file

    static func contents(command: String, trigger: String) -> String {
        """
        name = \(tomlString(title(for: command)))
        trigger = \(tomlString(trigger))
        command = \(tomlString(command))

        """
    }

    /// The first line, with its spaces collapsed, at most 60 characters.
    static func title(for command: String) -> String {
        let lines = command.split(whereSeparator: \.isNewline)
        let first = (lines.first ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        if first.count > 60 { return first.prefix(59) + "…" }
        return lines.count > 1 ? first + " …" : first
    }

    /// The command for an alert: at most 500 characters.
    static func excerpt(_ command: String) -> String {
        command.count > 500 ? command.prefix(499) + "…" : command
    }

    /// Several lines as a literal `'''` string, which keeps them as they
    /// are; anything else as a basic string with escapes.
    static func tomlString(_ value: String) -> String {
        let isPlain = value.unicodeScalars.allSatisfy { $0 == "\n" || $0 == "\t" || !isControl($0) }
        if value.contains("\n"), isPlain, !value.contains("'''"), !value.hasSuffix("'") {
            return "'''\n" + value + "'''"
        }
        var result = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\t": result += "\\t"
            case "\r": result += "\\r"
            case _ where isControl(scalar): result += String(format: "\\u%04X", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }

    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    /// `<trigger>.toml`, or with a number when that is taken. Characters a
    /// file name cannot have become `-`.
    static func unusedFile(for trigger: String, in directory: URL, fileManager: FileManager) -> URL {
        var stem = String(trigger.map { "/:\\".contains($0) ? "-" : $0 })
        while stem.hasPrefix(".") { stem.removeFirst() }
        if stem.isEmpty { stem = "command" }
        var number = 1
        while true {
            let name = number == 1 ? "\(stem).toml" : "\(stem)-\(number).toml"
            let file = directory.appending(path: name, directoryHint: .notDirectory)
            if !fileManager.fileExists(atPath: file.path(percentEncoded: false)) { return file }
            number += 1
        }
    }
}
