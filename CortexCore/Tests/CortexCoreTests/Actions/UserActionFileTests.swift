import Foundation
import Testing
@testable import CortexCore

/// An action file written from its keys (the MCP server's `create_action`).
@Suite struct UserActionFileTests {
    let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "CortexTests-actionfile-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    @Test func writesTheKeysInTheFormatsOrder() throws {
        let file = try UserActionFile(
            values: [
                "keywords": .strings(["repo"]), "url": .string("https://github.com/{argument}"), "trigger": .string("gh"),
                "name": .string("GitHub \"Repository\""), "confirm": .bool(false),
            ],
            directory: directory)
        #expect(file.file.lastPathComponent == "gh.toml")
        #expect(file.contents == """
            name = "GitHub \\"Repository\\""
            trigger = "gh"
            url = "https://github.com/{argument}"
            confirm = false
            keywords = ["repo"]

            """)
        try file.write()
        let contents = UserActionLibrary.load(from: directory)
        #expect(contents.problems.isEmpty)
        #expect(contents.commands.map(\.name) == ["gh"])
        #expect(contents.commands.first?.title == "GitHub \"Repository\"")
    }

    @Test func anActionIsNamedAfterItsTitleAndNeverOverwrites() throws {
        let values: [String: UserActionFile.Value] = [
            "name": .string("Shrink video"), "accepts": .strings(["files"]), "extensions": .strings(["mov"]),
            "command": .string("ffmpeg -i {input} -vf scale=-2:720 {output}"), "output_extension": .string("mp4"),
        ]
        let first = try UserActionFile(values: values, directory: directory)
        #expect(first.file.lastPathComponent == "shrink-video.toml")
        try first.write()
        let second = try UserActionFile(values: values, directory: directory)
        #expect(second.file.lastPathComponent == "shrink-video-2.toml")
        #expect(try UserActionFile(values: values, fileName: "small.toml", directory: directory).file.lastPathComponent == "small.toml")
        #expect(UserActionLibrary.load(from: directory).actions.first?.definition.resolvedOutput(for: .files) == .files)
    }

    @Test func refusesWhatWouldNotLoad() throws {
        #expect(throws: QuickActionError("Unknown key “shell”")) {
            try UserActionFile(values: ["name": .string("X"), "shell": .string("zsh")], directory: directory)
        }
        #expect(throws: QuickActionError("“url” or “command” is missing")) {
            try UserActionFile(values: ["name": .string("X"), "trigger": .string("x")], directory: directory)
        }
        #expect(throws: QuickActionError("“port” is the name of a built-in command")) {
            try UserActionFile(values: ["name": .string("X"), "trigger": .string("port"), "command": .string("lsof")], directory: directory)
        }
        try UserActionFile(values: ["name": .string("Up"), "trigger": .string("up"), "command": .string("make up")], directory: directory).write()
        #expect(throws: QuickActionError("“UP” is already the trigger of up.toml")) {
            try UserActionFile(values: ["name": .string("Up"), "trigger": .string("UP"), "command": .string("make")], directory: directory)
        }
    }
}
