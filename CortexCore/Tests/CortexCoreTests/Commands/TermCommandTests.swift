import Foundation
import Testing
@testable import CortexCore

/// `$term`: `terminal.toml`, its app and opening a terminal in a folder.
@Suite struct TermCommandTests {
    let home = URL(filePath: "/Users/me")

    // MARK: - terminal.toml

    @Test func foldersAndAppOfTheFile() throws {
        let contents = try FolderShortcuts.parse("""
            app = "Ghostty"
            scan = []

            [dl]
            path = "~/Downloads"
            """, format: TerminalFolders.format, home: home)
        #expect(contents.shortcuts == [FolderShortcut(name: "dl", location: .local("/Users/me/Downloads"))])
        #expect(contents.scan.isEmpty)
        #expect(contents.settings == ["app": .string("Ghostty")])
        let starter = try FolderShortcuts.parse(TerminalFolders.starter, format: TerminalFolders.format, home: home)
        #expect(starter == FolderShortcuts.Contents(shortcuts: [], scan: FolderShortcuts.defaultScan, settings: [:]), "all comments")
    }

    @Test func fileProblems() {
        func problem(_ text: String) -> String? {
            do {
                _ = try FolderShortcuts.parse(text, format: TerminalFolders.format, home: home)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(problem("[pi]\nhost = \"pi\"\npath = \"x\"") == "[pi] (line 1): a path on pi starts with /")
        #expect(problem("[pi]\nhost = \"pi\"\npath = \"/x\"") == nil, "a folder on a host")
        #expect(problem("[pi]\nshell = \"pi\"\npath = \"/x\"") == "[pi] (line 1): unknown key “shell”: a folder has a path and, over SSH, a host")
        #expect(problem("shell = \"zsh\"") == "unknown key “shell”: only scan and app come before the folders")
        #expect(problem("[a]\npath = \"x\"") == "[a] (line 1): the path starts with / or ~/")
    }

    @Test func loadsTheAppAndTheScannedFolders() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "cortex-term-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root.appending(path: "Developer/cortex"), withIntermediateDirectories: true)
        let file = root.appending(path: "terminal.toml")
        let standard = try TerminalFolders.load(file: file, home: root)
        #expect(standard.app == "Terminal", "no file: Terminal")
        #expect(standard.folders.map(\.name) == ["cortex"], "and the folders in ~/Developer")
        try "app = \"iTerm\"\nscan = []\n[tmp]\npath = \"/tmp\"\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try TerminalFolders.load(file: file, home: root) == TerminalFolders.Contents(
            app: "iTerm", folders: [FolderShortcut(name: "tmp", location: .local("/tmp"))]))
        try "app = 3\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: QuickActionError("terminal.toml: app is the name of an app in quotes: app = \"Terminal\"")) {
            try TerminalFolders.load(file: file, home: root)
        }
        #expect(TerminalFolders.defaultFile(environment: ["XDG_CONFIG_HOME": "/c"]).path(percentEncoded: false) == "/c/cortex/terminal.toml")
    }

    @Test func findsTheAppByNameOrPath() throws {
        let apps: Set<String> = ["/System/Applications/Utilities/Terminal.app", "/Applications/Ghostty.app", "/Users/me/Applications/Ghostty.app", "/opt/X.app"]
        let find = { (name: String) in try TerminalFolders.application(named: name, home: home, fileExists: { apps.contains($0) }).path(percentEncoded: false) }
        #expect(try find("Terminal").hasPrefix("/System/Applications/Utilities/Terminal.app"))
        #expect(try find("Ghostty.app").hasPrefix("/Users/me/Applications/Ghostty.app"), "~/Applications first")
        #expect(try find("/opt/X.app").hasPrefix("/opt/X.app"))
        #expect(throws: QuickActionError("No app called “Warp” in Applications: set app in terminal.toml to its name or path")) { try find("Warp") }
        #expect(throws: QuickActionError("There is no app at ~/Y.app")) { try find("~/Y.app") }
    }

    // MARK: - The command

    static let terminal = URL(filePath: "/System/Applications/Utilities/Terminal.app", directoryHint: .isDirectory)
    static let existing: Set<String> = [
        "/System/Applications/Utilities/Terminal.app", "/Users/me/Developer/Cortex", "/Users/me/Downloads",
        "/Users/me/My Notes.md", "/tmp",
    ]

    func command(app: String = "Terminal", folders: [FolderShortcut] = [
        FolderShortcut(name: "cortex", location: .local("/Users/me/Developer/Cortex")),
        FolderShortcut(name: "dl", location: .local("/Users/me/Downloads")),
        FolderShortcut(name: "gone", location: .local("/Users/me/Gone")),
    ]) -> TermCommand {
        TermCommand(
            folders: { TerminalFolders.Contents(app: app, folders: folders) },
            home: home,
            fileExists: { Self.existing.contains($0) },
            isDirectory: { ["/Users/me/Developer/Cortex", "/Users/me/Downloads", "/tmp"].contains($0) })
    }

    func opened(_ text: String?) async throws -> URL {
        let outcome = try await command().resolve(text.map { .text($0) } ?? .none)
        guard case .open(.openWith(let folder, let app)) = outcome else { throw QuickActionError("not opened: \(outcome)") }
        #expect(app == Self.terminal)
        return folder
    }

    @Test func itsArgumentIsAnOptionalChoiceOfTheFolders() async throws {
        let term = command()
        #expect(term.usage == "term cortex")
        let argument = try #require(term.argument)
        #expect(!argument.isRequired, "alone it opens the home folder")
        #expect(term.accepts(.none))
        #expect(argument.takesPaths)
        guard case .choice(let choices) = argument.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(await choices.load().map(\.title) == ["cortex", "dl", "gone"])
    }

    @Test func opensAFolderByNameOrPath() async throws {
        #expect(try await opened(nil) == home, "alone: a new window in the home folder")
        #expect(try await opened("  ") == home)
        #expect(try await opened("Cortex").path(percentEncoded: false).hasPrefix("/Users/me/Developer/Cortex"))
        #expect(try await opened("d").path(percentEncoded: false).hasPrefix("/Users/me/Downloads"), "the only name starting with it")
        #expect(try await opened("/tmp").path(percentEncoded: false).hasPrefix("/tmp"))
        #expect(try await opened("~/My Notes.md").path(percentEncoded: false) == "/Users/me/", "a file: its folder")
    }

    @Test func saysWhyItCannot() async throws {
        let term = command()
        #expect(throws: QuickActionError("“gone” is ~/Gone, which is not there")) { try term.destination("gone", in: try term.folders().folders) }
        #expect(throws: QuickActionError("No folder is called “nope”. Folders: cortex, dl, gone")) { try term.destination("nope", in: try term.folders().folders) }
        #expect(throws: QuickActionError("No file or folder at /nope")) { try term.destination("/nope", in: []) }
        await #expect(throws: QuickActionError("No app called “Warp” in Applications: set app in terminal.toml to its name or path")) {
            try await command(app: "Warp").resolve(.none)
        }
    }

    @Test func opensASessionOnAHost() async throws {
        let scripts = FileManager.default.temporaryDirectory.appending(path: "cortex-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: scripts) }
        let term = TermCommand(
            folders: { TerminalFolders.Contents(folders: [
                FolderShortcut(name: "pi", location: .ssh(host: "me@raspberrypi", path: "/home/pi/it's here")),
                FolderShortcut(name: "bad", location: .ssh(host: "-oProxyCommand=x", path: "/x")),
            ]) },
            home: home,
            fileExists: { Self.existing.contains($0) },
            isDirectory: { _ in true },
            scriptDirectory: scripts)
        #expect(try term.destination("pi", in: try term.folders().folders) == .ssh(host: "me@raspberrypi", path: "/home/pi/it's here"))
        let outcome = try await term.resolve(.text("pi"))
        guard case .open(.openWith(let script, let app)) = outcome else { throw QuickActionError("not opened: \(outcome)") }
        #expect(app == Self.terminal)
        #expect(script.pathExtension == "command")
        #expect(script.deletingLastPathComponent().lastPathComponent == scripts.lastPathComponent)
        #expect(try String(contentsOf: script, encoding: .utf8) == #"""
            #!/bin/zsh
            exec ssh -t -- 'me@raspberrypi' 'cd '\''/home/pi/it'\''\'\'''\''s here'\'' && exec "$SHELL" -l'

            """#)
        let permissions = try FileManager.default.attributesOfItem(atPath: script.path(percentEncoded: false))[.posixPermissions] as? Int
        #expect(permissions == 0o755, "a terminal runs it")
        await #expect(throws: QuickActionError("“-oProxyCommand=x” is not a host")) {
            try await term.resolve(.text("bad"))
        }
    }

    @Test func itsSettingsFileIsTerminalToml() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cortex-term-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cortex/terminal.toml")
        let term = TermCommand(folders: { throw QuickActionError("not read") }, settingsFile: file)
        #expect(try term.settingsLink() == URL(string: "vscode://file" + file.path(percentEncoded: false)))
        #expect(try String(contentsOf: file, encoding: .utf8) == TerminalFolders.starter)
    }
}
