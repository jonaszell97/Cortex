#if os(macOS)
import Foundation

/// `$term cortex`: opens a new terminal window in a folder by a short name
/// (`TerminalFolders`: `terminal.toml` and the folders in `~/Developer`),
/// matched like `$code`'s projects. A path instead (absolute or `~/`, quoted
/// or as copied) opens there, or in the folder of a file: `$term ~/Downloads`.
/// `$term` alone opens one in the home folder. The app is Terminal unless
/// `terminal.toml` names another; it is handed the folder like a folder
/// dropped on its icon, so whether it opens a window or a tab is the app's
/// (Terminal opens a window). A folder on a host (`host` in `terminal.toml`)
/// opens an SSH session there instead: the app is handed a small `.command`
/// script that runs `ssh` and changes into the folder. ⌘E opens
/// `terminal.toml`.
public struct TermCommand: SettingsFileCommand {
    public let id = "command.term"
    public let name = "term"
    public let title = "Open in Terminal"
    public let summary = "Opens a new terminal window in a folder by its short name, on this Mac or over SSH (terminal.toml and ~/Developer), or by its path. Alone, in your home folder."
    public let symbol = "terminal"
    public let keywords = ["terminal", "term", "shell", "console", "cd", "folder", "project", "iterm", "ghostty", "ssh", "remote"]
    /// The app and folders, read when the form opens and on every run.
    let folders: @Sendable () throws -> TerminalFolders.Contents
    public let settingsFile: URL
    public var settingsStarter: String { TerminalFolders.starter }
    let home: URL
    let fileExists: @Sendable (String) -> Bool
    let isDirectory: @Sendable (String) -> Bool
    /// Where the script for a folder on a host is written.
    let scriptDirectory: URL

    public init(
        folders: @escaping @Sendable () throws -> TerminalFolders.Contents = { try TerminalFolders.load() },
        settingsFile: URL = TerminalFolders.defaultFile(),
        home: URL = URL.homeDirectory,
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        isDirectory: @escaping @Sendable (String) -> Bool = { FolderShortcuts.isDirectory($0) },
        scriptDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "cortex-term", directoryHint: .isDirectory)
    ) {
        self.folders = folders
        self.settingsFile = settingsFile
        self.home = home
        self.fileExists = fileExists
        self.isDirectory = isDirectory
        self.scriptDirectory = scriptDirectory
    }

    /// The form lists the folders and takes a path too. Optional: without
    /// it the window opens in the home folder.
    public var argument: CommandArgument? {
        let folders = folders
        return CommandArgument(
            title: "Folder", placeholder: "cortex",
            kind: .choice(CommandChoices(id: "terminal-folders", allowsPaths: true) { FolderShortcuts.choices((try? folders().folders) ?? []) }),
            isRequired: false, suggestions: .choices)
    }

    /// Finding the folder only reads; the terminal opens on ⏎.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let contents = try folders()
        let app = try TerminalFolders.application(named: contents.app, home: home, fileExists: fileExists)
        let text = invocation.input.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return .open(.openWith(home, app: app)) }
        switch try destination(text, in: contents.folders) {
        case .folder(let folder):
            return .open(.openWith(folder, app: app))
        case .ssh(let host, let path):
            return .open(.openWith(try sshScript(host: host, path: path), app: app))
        }
    }

    /// Where the terminal opens.
    enum Destination: Equatable {
        case folder(URL)
        case ssh(host: String, path: String)
    }

    /// The folder `text` names or the folder at its path (the folder of a
    /// file at its path), on this Mac or on a host.
    func destination(_ text: String, in folders: [FolderShortcut]) throws -> Destination {
        let target = try FolderShortcuts.target(
            text, in: { folders }, noun: "folder",
            none: "No folders: add them to \(settingsFile.path(percentEncoded: false)), or put folders in ~/Developer",
            home: home, fileExists: fileExists, isDirectory: isDirectory)
        switch target.location {
        case .ssh(let host, let path):
            return .ssh(host: host, path: path)
        case .local(let path):
            guard fileExists(path) else { throw QuickActionError("“\(target.name)” is \(target.displayLocation(home: home)), which is not there") }
            let url = URL(filePath: path, directoryHint: .isDirectory)
            return .folder(isDirectory(path) ? url : url.deletingLastPathComponent())
        }
    }

    /// A `.command` file that connects to `host` and starts the login shell
    /// in `path`; a terminal app opens it in a new window, like a folder.
    /// It is named for the host and folder, so a repeated run rewrites it.
    func sshScript(host: String, path: String) throws -> URL {
        guard !host.hasPrefix("-") else { throw QuickActionError("“\(host)” is not a host") }
        let remote = "cd \(ShellCommand.quote(path)) && exec \"$SHELL\" -l"
        let source = "#!/bin/zsh\nexec ssh -t -- \(ShellCommand.quote(host)) \(ShellCommand.quote(remote))\n"
        let name = "ssh \(host) \(path)".replacingOccurrences(of: "/", with: "_")
        let file = scriptDirectory.appending(path: name + ".command", directoryHint: .notDirectory)
        do {
            try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
            try source.write(to: file, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path(percentEncoded: false))
        } catch {
            throw QuickActionError("Could not prepare the SSH session: \(error.localizedDescription)")
        }
        return file
    }
}
#endif
