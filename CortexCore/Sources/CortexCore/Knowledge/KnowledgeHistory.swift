#if os(macOS)
import Foundation

/// A git history of the knowledge folder (docs/modules/KNOWLEDGE.md, "Sync and
/// backups"): `git init` with a `.gitignore`, then a commit of everything after
/// changes, named after what changed. No remote; each Mac keeps its own. Uses
/// `/usr/bin/git`, which only works with the Command Line Tools installed.
public struct KnowledgeHistory: Sendable {
    public let folder: URL
    public let git: URL

    public static let gitignore = ".conflicts/\n.DS_Store\n"

    public init(folder: URL, git: URL = URL(filePath: "/usr/bin/git")) {
        self.folder = folder
        self.git = git
    }

    /// Whether git can run. `/usr/bin/git` is a stub without the Command
    /// Line Tools that offers to install them, so `xcode-select -p` is asked
    /// first: it fails quietly when there are none.
    public static func isGitAvailable() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/git") else { return false }
        let result = try? await ProcessRunner.run(URL(filePath: "/usr/bin/xcode-select"), arguments: ["-p"])
        return result?.status == 0
    }

    public var isRepository: Bool {
        FileManager.default.fileExists(atPath: folder.appending(path: ".git").path(percentEncoded: false))
    }

    /// `git init` and the `.gitignore`, unless the folder is a repository already.
    public func prepare() async throws {
        let ignore = folder.appending(path: ".gitignore")
        if !FileManager.default.fileExists(atPath: ignore.path(percentEncoded: false)) {
            try Data(Self.gitignore.utf8).write(to: ignore, options: .atomic)
        }
        guard !isRepository else { return }
        try await run(["init", "--quiet", "--initial-branch=main"])
    }

    /// Commits every change in the folder. Returns the message, or nil when
    /// there was nothing to commit.
    @discardableResult
    public func commitAll() async throws -> String? {
        try await run(["add", "--all"])
        let status = try await run(["status", "--porcelain=v1", "-z"])
        let changes = Self.changes(fromPorcelain: status.output)
        guard !changes.isEmpty else { return nil }
        let message = Self.message(for: changes)
        try await run([
            "-c", "user.name=Cortex", "-c", "user.email=cortex@localhost", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "--no-verify", "-m", message,
        ])
        return message
    }

    // MARK: - Messages

    public struct Change: Sendable, Equatable {
        public enum Kind: Sendable, Hashable {
            case add, edit, delete
            case rename(from: String)
        }

        public var kind: Kind
        public var path: String

        public init(_ kind: Kind, _ path: String) {
            self.kind = kind
            self.path = path
        }

        var line: String {
            switch kind {
            case .add: "Add \(path)"
            case .edit: "Edit \(path)"
            case .delete: "Delete \(path)"
            case .rename(let from): "Rename \(from) to \(path)"
            }
        }
    }

    /// The staged changes in `git status --porcelain=v1 -z` output.
    static func changes(fromPorcelain output: Data) -> [Change] {
        var fields = output.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }[...]
        var changes: [Change] = []
        while let field = fields.popFirst() {
            guard field.count > 3 else { continue }
            let staged = field.first!
            let path = String(field.dropFirst(3))
            switch staged {
            case "A": changes.append(Change(.add, path))
            case "M", "T": changes.append(Change(.edit, path))
            case "D": changes.append(Change(.delete, path))
            case "R", "C":
                let from = fields.popFirst() ?? path
                changes.append(Change(staged == "R" ? .rename(from: from) : .add, path))
            default: continue
            }
        }
        return changes
    }

    /// One change: "Edit server-config/notes/docker.md". Several: "Change 3
    /// files", then one line each.
    public static func message(for changes: [Change]) -> String {
        if changes.count == 1 { return changes[0].line }
        let kinds = Set(changes.map(\.kind))
        let verb = kinds == [.add] ? "Add" : kinds == [.delete] ? "Delete" : kinds == [.edit] ? "Edit" : "Change"
        return "\(verb) \(changes.count) files\n\n" + changes.map(\.line).joined(separator: "\n")
    }

    // MARK: - Running git

    @discardableResult
    private func run(_ arguments: [String]) async throws -> ProcessResult {
        var environment = ToolLocator.environment
        // Never ask for anything: there is no terminal.
        environment["GIT_TERMINAL_PROMPT"] = "0"
        let result = try await ProcessRunner.run(git, arguments: ["-C", folder.path(percentEncoded: false)] + arguments, environment: environment)
        guard result.status == 0 else {
            throw QuickActionError("git \(arguments.first ?? "") failed: \(result.errorSummary())")
        }
        return result
    }
}
#endif
