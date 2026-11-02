#if os(macOS)
import Foundation

/// `$code cortex`: opens a project in VS Code by a short name, on this Mac
/// or over SSH (`CodeProjects`: `projects.toml` and the folders in
/// `~/Developer`). The name is matched like a choice: exactly, ignoring
/// case, or the only name that starts with what is typed (`$code wish`).
/// A path instead (absolute or `~/`, quoted or as copied) opens that file
/// or folder: `$code ~/.zshrc`. It opens through a `vscode://` link, so the
/// `code` shell command is not needed, and the link is previewed before ⏎
/// opens it. A project gets a new window, or the window that has it already
/// (`FolderShortcut.vscodeURL`). ⌘E opens `projects.toml` itself.
public struct CodeCommand: SettingsFileCommand {
    public let id = "command.code"
    public let name = "code"
    public let title = "Open in VS Code"
    public let verb: String? = "Open in VS Code"
    public let summary = "Opens a project in VS Code by its short name, on this Mac or over SSH (projects.toml and ~/Developer), or a file or folder by its path."
    public let symbol = "chevron.left.forwardslash.chevron.right"
    public let keywords = ["vscode", "code", "editor", "project", "ssh", "remote", "open", "file"]
    /// The projects, read when the form opens and on every run.
    let projects: @Sendable () throws -> [FolderShortcut]
    public let settingsFile: URL
    public var settingsStarter: String { CodeProjects.starter }
    let home: URL
    let fileExists: @Sendable (String) -> Bool
    let isDirectory: @Sendable (String) -> Bool

    public init(
        projects: @escaping @Sendable () throws -> [FolderShortcut] = { try CodeProjects.load() },
        settingsFile: URL = CodeProjects.defaultFile(),
        home: URL = URL.homeDirectory,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: @escaping @Sendable (String) -> Bool = { FolderShortcuts.isDirectory($0) }
    ) {
        self.projects = projects
        self.settingsFile = settingsFile
        self.home = home
        self.fileExists = fileExists
        self.isDirectory = isDirectory
    }

    /// The form lists the projects and takes a path too; projects the file
    /// cannot give are left out there, and the preview says why.
    public var argument: CommandArgument? {
        let projects = projects
        return CommandArgument(
            title: "Project", placeholder: "cortex",
            kind: .choice(CommandChoices(id: "code-projects", allowsPaths: true) { FolderShortcuts.choices((try? projects()) ?? []) }),
            suggestions: .choices)
    }

    /// Finding the project only reads; VS Code opens on ⏎.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        guard let text = invocation.input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw QuickActionError("Needs a project or a path")
        }
        return .open(.url(try target(text).vscodeURL))
    }

    /// The project `text` names, or the file or folder at its path.
    func target(_ text: String) throws -> FolderShortcut {
        try FolderShortcuts.target(
            text, in: projects, noun: "project",
            none: "No projects: add them to \(settingsFile.path(percentEncoded: false)), or put folders in ~/Developer",
            home: home, fileExists: fileExists, isDirectory: isDirectory)
    }
}
#endif
