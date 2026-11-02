import Foundation
import Testing
@testable import CortexCore

/// "Save as Command": the selected text as a `$` command file.
@Suite struct CommandFileTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-commandfile-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    func load() -> UserActionLibrary.Contents {
        UserActionLibrary.load(from: directory)
    }

    @Test func theSelectionIsTheCommand() throws {
        #expect(try CommandFile.command(from: "  docker compose up -d\n") == "docker compose up -d")
        #expect(try CommandFile.command(from: "$ npm run build") == "npm run build", "a copied prompt")
        #expect(try CommandFile.command(from: "$ cd app\n$ make\n") == "cd app\nmake")
        #expect(try CommandFile.command(from: "echo $HOME") == "echo $HOME")
        #expect(try CommandFile.command(from: "$ cd app\nmake") == "$ cd app\nmake", "only when every line has the prompt")
        #expect(throws: QuickActionError("There is no command to save")) { try CommandFile.command(from: " \n ") }
        #expect(throws: QuickActionError.self, "the shell cannot fill it in") { try CommandFile.command(from: "jq '.{argument}'") }
    }

    @Test func savesAFileThatLoadsAsTheCommand() async throws {
        let file = try CommandFile(command: "docker compose up -d", trigger: " $up ", directory: directory, existing: CommandCatalog.builtIns)
        #expect(file.trigger == "up")
        #expect(file.file.lastPathComponent == "up.toml")
        #expect(file.contents == """
            name = "docker compose up -d"
            trigger = "up"
            command = "docker compose up -d"

            """)

        let confirmation = file.confirmation
        #expect(confirmation.title == "Save $up?")
        #expect(confirmation.confirmTitle == "Save")
        #expect(!confirmation.isDestructive)
        #expect(confirmation.message.contains("docker compose up -d"))
        #expect(!FileManager.default.fileExists(atPath: file.file.path), "nothing is written before it is confirmed")

        #expect(try await confirmation.perform() == .done("Saved up.toml. Type $up to run it."))
        let contents = load()
        #expect(contents.problems.isEmpty)
        let command = try #require(contents.commands.first)
        #expect(command.name == "up")
        #expect(command.title == "docker compose up -d")
        #expect(command.argument == nil, "it takes nothing")
        #expect(contents.actions.isEmpty, "only a $ command")
    }

    @Test func anArgumentIsWhatIsTyped() throws {
        let file = try CommandFile(command: "git checkout {argument}", trigger: "co", directory: directory, existing: [])
        #expect(file.definition.accepts == [.text])
        #expect(file.confirmation.message.hasPrefix("$co … runs:"))
    }

    @Test func severalLinesAndQuotesSurvive() throws {
        let commands = [
            "cd ~/app\nmake \"all\"\necho 'done'",
            "echo \"a\\tb\"",
            "printf 'x'\nprintf 'y'",
            "echo '''",
            "say \u{07}hi",
        ]
        for (index, command) in commands.enumerated() {
            let file = try CommandFile(command: command, trigger: "c\(index)", directory: directory, existing: [])
            #expect(file.definition.target == .shell(command), "\(file.contents)")
        }
        let file = try CommandFile(command: "cd ~/app\nmake", trigger: "app", directory: directory, existing: [])
        #expect(file.contents.contains("command = '''\ncd ~/app\nmake'''"))
        #expect(file.definition.name == "cd ~/app …")
    }

    @Test func theNameMustBeOneFreeWord() throws {
        #expect(throws: QuickActionError("Give it a name to type after $")) {
            try CommandFile(command: "ls", trigger: " $ ", directory: directory, existing: [])
        }
        #expect(throws: QuickActionError("The name must be one word, like “deploy” for $deploy")) {
            try CommandFile(command: "ls", trigger: "list files", directory: directory, existing: [])
        }
        #expect(throws: QuickActionError("“Kill” is the name of a built-in command")) {
            try CommandFile(command: "ls", trigger: "Kill", directory: directory, existing: CommandCatalog.builtIns)
        }

        let first = try CommandFile(command: "ls", trigger: "ls", directory: directory, existing: [])
        try first.write()
        let existing = load().commands
        #expect(throws: QuickActionError("“ls” is already the trigger of ls.toml")) {
            try CommandFile(command: "ls -la", trigger: "ls", directory: directory, existing: existing)
        }
    }

    @Test func aTakenFileNameGetsANumber() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("name = \"Other\"\ntrigger = \"other\"\ncommand = \"true\"\n".utf8)
            .write(to: directory.appending(path: "deploy.toml"))
        let file = try CommandFile(command: "./deploy.sh", trigger: "deploy", directory: directory, existing: load().commands)
        #expect(file.file.lastPathComponent == "deploy-2.toml")
        #expect(CommandFile.unusedFile(for: "../a/b", in: directory, fileManager: .default).lastPathComponent == "-a-b.toml")
    }

    @Test func neverWritesOverAFile() throws {
        let file = try CommandFile(command: "ls", trigger: "ls", directory: directory, existing: [])
        try file.write()
        #expect(throws: QuickActionError("ls.toml already exists")) { try file.write() }
    }

    @Test func theTitleIsTheFirstLine() {
        #expect(CommandFile.title(for: "ls   -la") == "ls -la")
        #expect(CommandFile.title(for: String(repeating: "a", count: 80)) == String(repeating: "a", count: 59) + "…")
    }

    @Test func theActionPreviewsTheCommand() throws {
        let save = try #require(TextAction.all.first { $0.id == TextAction.saveCommandID })
        #expect(try save.perform(.text("$ make test\n")) == .saveCommand("make test"))
        #expect(!save.accepts(.none))
    }
}
