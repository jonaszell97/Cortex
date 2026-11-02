import Foundation
import Testing
@testable import CortexCore

/// `$code`: `projects.toml`, the scanned folders and picking a project.
@Suite struct CodeCommandTests {
    let home = URL(filePath: "/Users/me")

    // MARK: - TOML tables

    @Test func tablesAreReadInOrder() throws {
        let document = try TOML.parseTables("""
            scan = ["~/a"]

            [api] # a comment
            path = "~/api"
            ["my pi"]
            host = "pi"
            """)
        #expect(document.keys == ["scan": .array([.string("~/a")])])
        #expect(document.tables.map(\.name) == ["api", "my pi"])
        #expect(document.tables[0].keys == ["path": .string("~/api")])
        #expect(document.tables[1].line == 5)
    }

    @Test func badTables() {
        #expect(throws: TOML.ParseError(line: 3, message: "[a] is there twice")) { try TOML.parseTables("[a]\nx = 1\n[a]") }
        #expect(throws: TOML.ParseError.self) { try TOML.parseTables("[[a]]") }
        #expect(throws: TOML.ParseError.self) { try TOML.parseTables("[a.b]") }
        #expect(throws: TOML.ParseError.self) { try TOML.parseTables("[a") }
        #expect(throws: TOML.ParseError(line: 1, message: "Tables ([section]) are not supported; put every key at the top")) {
            try TOML.parse("[a]")
        }
    }

    // MARK: - projects.toml

    func parse(_ text: String) throws -> (projects: [FolderShortcut], scan: [String]) {
        let contents = try FolderShortcuts.parse(text, format: CodeProjects.format, home: home)
        return (contents.shortcuts, contents.scan)
    }

    @Test func projectsOfTheFile() throws {
        let (projects, scan) = try parse("""
            scan = ["~/Code", "/Volumes/Work"]

            [api]
            path = "~/Developer/myapp/myapp-api"

            [pi]
            host = "raspberrypi"
            path = "/home/pi/home assistant"
            """)
        #expect(scan == ["~/Code", "/Volumes/Work"])
        #expect(projects == [
            FolderShortcut(name: "api", location: .local("/Users/me/Developer/myapp/myapp-api")),
            FolderShortcut(name: "pi", location: .ssh(host: "raspberrypi", path: "/home/pi/home assistant")),
        ])
        #expect(try parse("").scan == FolderShortcuts.defaultScan)
        #expect(try parse("scan = []").scan.isEmpty)
    }

    @Test func fileProblems() {
        func problem(_ text: String) -> String? {
            do {
                _ = try parse(text)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(problem("[a]\nhost = \"pi\"") == "[a] (line 1): path is missing")
        #expect(problem("[a]\nhost = \"pi\"\npath = \"~/x\"") == "[a] (line 1): a path on pi starts with /")
        #expect(problem("[a]\npath = \"x\"") == "[a] (line 1): the path starts with / or ~/")
        #expect(problem("[a]\npath = \"/x\"\nport = 22") == "[a] (line 1): port is text in quotes")
        #expect(problem("[a]\npath = \"/x\"\nuser = \"me\"") == "[a] (line 1): unknown key “user”: a project has a path and, over SSH, a host")
        #expect(problem("scan = \"~/x\"") == "scan is a list of folders: scan = [\"~/Developer\"]")
        #expect(problem("path = \"/x\"") == "unknown key “path”: only scan comes before the projects")
    }

    @Test func aBrokenFileSaysWhereInItsMessage() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cortex-code-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "projects.toml")
        try "scan = []\n[a]\npath = 3".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: QuickActionError("projects.toml: [a] (line 2): path is text in quotes")) { try CodeProjects.load(file: file, home: home) }
        try "[a\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: QuickActionError.self) { try CodeProjects.load(file: file, home: home) }
        // No file: only the scanned folders, here none.
        #expect(try CodeProjects.load(file: folder.appending(path: "missing.toml"), home: folder).isEmpty)
    }

    // MARK: - Scanning

    @Test func scannedFoldersAreProjectsAndTheFileWins() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appending(path: "cortex-code-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        for folder in ["Developer/zeta", "Developer/Alpha", "Developer/api", "Developer/.hidden", "Other/zeta"] {
            try fileManager.createDirectory(at: root.appending(path: folder), withIntermediateDirectories: true)
        }
        try Data().write(to: root.appending(path: "Developer/notes.txt"))
        let file = root.appending(path: "projects.toml")
        try """
            scan = ["~/Developer", "~/Other", "~/Missing"]
            [API]
            host = "devbox"
            path = "/srv/api"
            """.write(to: file, atomically: true, encoding: .utf8)

        let projects = try CodeProjects.load(file: file, home: root)
        #expect(projects.map(\.name) == ["API", "Alpha", "zeta"], "the file's API hides the folder api, the first zeta wins")
        guard case .local(let zeta) = projects[2].location else {
            Issue.record("expected a local project")
            return
        }
        #expect(zeta.hasSuffix("/Developer/zeta"), "no trailing slash")
        let resolved = { (url: URL) in url.resolvingSymlinksInPath().path(percentEncoded: false).trimmingCharacters(in: ["/"]) }
        #expect(resolved(URL(filePath: zeta)) == resolved(root.appending(path: "Developer/zeta")))
    }

    // MARK: - Links

    @Test func links() {
        let local = FolderShortcut(name: "x", location: .local("/Users/me/Developer/My App"))
        #expect(local.vscodeURL.absoluteString == "vscode://file/Users/me/Developer/My%20App?windowId=_blank", "a new window, or the one that has it")
        #expect(local.displayLocation(home: home) == "~/Developer/My App")
        let remote = FolderShortcut(name: "pi", location: .ssh(host: "raspberrypi", path: "/home/pi/x"))
        #expect(remote.vscodeURL.absoluteString == "vscode://vscode-remote/ssh-remote+raspberrypi/home/pi/x?windowId=_blank")
        #expect(FolderShortcut(name: "z", location: .local("/Users/me/.zshrc"), isFile: true).vscodeURL.absoluteString == "vscode://file/Users/me/.zshrc",
                "a file goes to the window that has its folder")
        #expect(remote.displayLocation(home: home) == "raspberrypi:/home/pi/x")
        #expect(FolderShortcut(name: "w", location: .local("/opt/w.code-workspace")).displayLocation(home: home) == "/opt/w.code-workspace")
    }

    // MARK: - The command

    let command = CodeCommand {
        [
            FolderShortcut(name: "cortex", location: .local("/Users/me/Developer/Cortex")),
            FolderShortcut(name: "myapp-api", location: .local("/Users/me/Developer/myapp-api")),
            FolderShortcut(name: "myapp-ios", location: .local("/Users/me/Developer/myapp-ios")),
            FolderShortcut(name: "pi", location: .ssh(host: "raspberrypi", path: "/home/pi")),
        ]
    }

    @Test func itsArgumentIsAChoiceOfTheProjects() async throws {
        #expect(command.usage == "code cortex")
        let argument = try #require(command.argument)
        #expect(argument.isRequired, "⌘E opens projects.toml, not the command alone")
        #expect(!command.accepts(.none))
        #expect(argument.suggestions == .choices)
        guard case .choice(let choices) = argument.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(await choices.load().map(\.title) == ["cortex", "myapp-api", "myapp-ios", "pi"])
    }

    @Test func picksTheProject() async throws {
        #expect(try await command.resolve(.text("Cortex"))
            == .open(.url(URL(string: "vscode://file/Users/me/Developer/Cortex?windowId=_blank")!)))
        #expect(try await command.resolve(.text("pi"))
            == .open(.url(URL(string: "vscode://vscode-remote/ssh-remote+raspberrypi/home/pi?windowId=_blank")!)))
        #expect(try command.target("myapp-i").name == "myapp-ios", "the only name starting with it")
        #expect(try command.target("cor").name == "cortex")
    }

    @Test func saysWhyThereIsNone() {
        #expect(throws: QuickActionError("“my” could be myapp-api, myapp-ios: type more of the name")) {
            try command.target("my")
        }
        #expect(throws: QuickActionError("No project is called “nope”. Projects: cortex, myapp-api, myapp-ios, pi")) {
            try command.target("nope")
        }
        let broken = CodeCommand { throw QuickActionError("projects.toml: [a] (line 2): path is missing") }
        #expect(throws: QuickActionError("projects.toml: [a] (line 2): path is missing")) { try broken.target("a") }
        #expect(throws: QuickActionError.self) { try CodeCommand { [] }.target("a") }
    }

    @Test func itsSettingsFileIsProjectsToml() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cortex-code-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cortex/projects.toml")
        let code = CodeCommand(projects: { [] }, settingsFile: file, home: home)
        let link = try #require(URL(string: "vscode://file" + file.path(percentEncoded: false)), "a single file: no new window")
        #expect(try code.settingsLink() == link)
        #expect(try String(contentsOf: file, encoding: .utf8) == CodeProjects.starter, "written with its folder when missing")
        #expect(try parse(CodeProjects.starter) == ([], FolderShortcuts.defaultScan), "all comments")
        try "[a]\npath = \"/a\"\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(try code.settingsLink() == link)
        #expect(try String(contentsOf: file, encoding: .utf8) == "[a]\npath = \"/a\"\n", "left as it is")
        #expect(CodeProjects.defaultFile(environment: ["XDG_CONFIG_HOME": "/c"]).path(percentEncoded: false) == "/c/cortex/projects.toml")
    }

    // MARK: - Paths

    let withFiles = CodeCommand(
        projects: { [] }, home: URL(filePath: "/Users/me"),
        fileExists: { ["/tmp/x.txt", "/Users/me/My Notes.md", "/Users/me/Developer/Cortex", "/Users/me/w.code-workspace"].contains($0) },
        isDirectory: { $0 == "/Users/me/Developer/Cortex" })

    @Test func aPathOpensThatFileOrFolder() async throws {
        #expect(try await withFiles.resolve(.text("/tmp/x.txt")) == .open(.url(URL(string: "vscode://file/tmp/x.txt")!)))
        #expect(try withFiles.target("~/My Notes.md").vscodeURL.absoluteString == "vscode://file/Users/me/My%20Notes.md", "as copied")
        #expect(try withFiles.target("'~/My Notes.md'").vscodeURL.absoluteString == "vscode://file/Users/me/My%20Notes.md", "as dropped")
        #expect(try withFiles.target("~/Developer/Cortex").vscodeURL.absoluteString == "vscode://file/Users/me/Developer/Cortex?windowId=_blank", "a folder: a new window")
        #expect(try withFiles.target("~/w.code-workspace").vscodeURL.absoluteString == "vscode://file/Users/me/w.code-workspace?windowId=_blank", "a workspace too")
        #expect(throws: QuickActionError("No file or folder at /nope.txt")) { try withFiles.target("/nope.txt") }
        #expect(throws: QuickActionError("Opens one file or folder at a time")) { try withFiles.target("/tmp/x.txt ~/Developer/Cortex") }
    }

    @Test func theFormTakesAPathToo() throws {
        let argument = try #require(withFiles.argument)
        #expect(argument.takesPaths, "a dropped file fills it")
        #expect(!(try #require(DiskSpaceCommand { [] }.argument)).takesPaths)
        let choices = [ActionOption.Choice("cortex", title: "cortex")]
        let exists: (String) -> Bool = { $0 == "/Users/me/My Notes.md" }
        func input(_ text: String) -> Result<ActionInput, CommandArgument.Problem> {
            argument.input(from: text, choices: choices, home: home, fileExists: exists)
        }
        #expect(input("~/My Notes.md") == .success(.text("~/My Notes.md")))
        #expect(input("'~/My Notes.md'") == .success(.text("'~/My Notes.md'")))
        #expect(input("cor") == .success(.text("cortex")))
        #expect(input("/nope") == .failure(.invalid("Project: no file or folder at /nope")))
        #expect(input("nope") == .failure(.invalid("Project: “nope” is not in the list")))
        #expect(argument.input(from: "~/My Notes.md", choices: nil, home: home, fileExists: exists) == .success(.text("~/My Notes.md")),
                "no need to wait for the list")
    }

    @Test func startsLikeAPath() {
        for text in ["/a", "~/a", "'/a b'", "\"~/a b\""] { #expect(ActionInput.startsLikePath(text), "\(text)") }
        for text in ["a", "~a", "'a'", "", "~"] { #expect(!ActionInput.startsLikePath(text), "\(text)") }
    }

    @Test func choicesMatchAUniquePrefix() {
        let choices = [ActionOption.Choice("/", title: "Macintosh HD"), ActionOption.Choice("/Volumes/M", title: "Media")]
        #expect(CommandChoices.match("mac", in: choices)?.title == "Macintosh HD")
        #expect(CommandChoices.match("m", in: choices) == nil, "two start with it")
        #expect(CommandChoices.match("", in: choices) == nil)
        #expect(CommandChoices.match("/", in: choices)?.title == "Macintosh HD", "the value still matches exactly")
    }
}
