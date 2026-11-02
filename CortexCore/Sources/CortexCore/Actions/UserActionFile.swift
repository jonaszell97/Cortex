import Foundation

/// A new action or command file written from its keys, as the MCP server's
/// `create_action` does: the keys in the order the format lists them,
/// checked by loading the text as the actions folder will, in a file of its
/// own that does not exist yet.
///
/// ```toml
/// name = "GitHub Repository"
/// trigger = "gh"
/// url = "https://github.com/{argument}"
/// ```
public struct UserActionFile: Sendable, Equatable {
    /// A key's value: the format only has strings, lists of them and
    /// booleans.
    public enum Value: Sendable, Equatable {
        case string(String)
        case strings([String])
        case bool(Bool)
    }

    /// Where it is saved; no file is there yet.
    public let file: URL
    /// The file's TOML.
    public let contents: String
    /// The file as it loads.
    public let definition: UserActionDefinition

    /// The order of the keys in the file; the same as in the format's
    /// documentation (`UserActionDefinition`).
    static let keyOrder = [
        "name", "trigger", "accepts", "argument", "extensions", "url", "command", "output", "output_extension",
        "output_suffix", "example", "confirm", "matches", "symbol", "keywords",
    ]

    /// Checks that the keys make a file that loads, and that its trigger
    /// names none of the `reserved` commands (the built-ins) or the files
    /// already in `directory`. The file is `<fileName>.toml`, else named
    /// after the trigger or the name, with a number added when that is
    /// taken. Errors say what is wrong, as the settings window does.
    public init(
        values: [String: Value], fileName: String? = nil, directory: URL, reserved: [any Command] = CommandCatalog.builtIns,
        fileManager: FileManager = .default
    ) throws {
        if let unknown = values.keys.sorted().first(where: { !UserActionDefinition.knownKeys.contains($0) }) {
            throw QuickActionError("Unknown key “\(unknown)”")
        }
        let contents = Self.contents(values)
        let definition = try UserActionDefinition.parse(contents)
        var stem = fileName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if stem.lowercased().hasSuffix(".toml") { stem.removeLast(".toml".count) }
        if stem.isEmpty { stem = definition.trigger ?? KnowledgeSlug.make(definition.name) }
        let file = CommandFile.unusedFile(for: stem, in: directory, fileManager: fileManager)
        if definition.trigger != nil {
            let existing = UserActionLibrary.load(from: directory, reserved: reserved, fileManager: fileManager).commands
            let new = UserCommand(definition: definition, file: file)
            if let problem = CommandCatalog.problems(in: reserved + existing + [new]).first(where: { $0.id == new.id }) {
                throw QuickActionError(problem.message)
            }
        }
        self.file = file
        self.contents = contents
        self.definition = definition
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

    static func contents(_ values: [String: Value]) -> String {
        keyOrder.compactMap { key in
            values[key].map { value in
                let text = switch value {
                case .string(let string): CommandFile.tomlString(string)
                case .strings(let strings): "[" + strings.map(CommandFile.tomlString).joined(separator: ", ") + "]"
                case .bool(let bool): bool ? "true" : "false"
                }
                return "\(key) = \(text)\n"
            }
        }.joined()
    }
}
