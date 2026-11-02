import Foundation
import Testing
@testable import CortexCore

/// The action files the module docs show, as test fixtures: they have to
/// load, and behave as the docs say.
@Suite struct DocsActionFileTests {
    /// The docs whose examples are tested.
    static let docs = ["docs/modules/ACTIONS.md", "docs/modules/COMMANDS.md"]

    /// Each `toml` block of `docs` that starts with
    /// `# ~/.config/cortex/actions/<name>.toml`, by file name.
    static func examples() throws -> [String: String] {
        let root = URL(filePath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let text = try docs.map { try String(contentsOf: root.appending(path: $0), encoding: .utf8) }.joined(separator: "\n")
        var examples: [String: String] = [:]
        for block in text.components(separatedBy: "```toml\n").dropFirst() {
            guard let body = block.components(separatedBy: "\n```").first,
                  let firstLine = body.split(separator: "\n").first,
                  firstLine.hasPrefix("# ~/.config/cortex/actions/")
            else { continue }
            examples[String(firstLine.split(separator: "/").last!)] = body
        }
        return examples
    }

    func definition(_ name: String) throws -> UserActionDefinition {
        let source = try #require(try Self.examples()[name], "\(name) is in the docs")
        return try UserActionDefinition.parse(source)
    }

    func action(_ name: String) throws -> UserAction {
        UserAction(definition: try definition(name), file: URL(filePath: "/tmp/\(name)"))
    }

    func command(_ name: String) throws -> UserCommand {
        UserCommand(definition: try definition(name), file: URL(filePath: "/tmp/\(name)"))
    }

    @Test func theyAllLoadTogether() throws {
        let examples = try Self.examples()
        #expect(examples.keys.sorted() == ["deploy.toml", "github.toml", "search-ddg.toml", "shrink-video.toml", "tracking.toml"])
        let directory = try temporaryDirectory()
        for (name, source) in examples {
            try source.write(to: directory.appending(path: name), atomically: true, encoding: .utf8)
        }
        let contents = UserActionLibrary.load(from: directory)
        #expect(contents.problems.isEmpty, "\(contents.problems.map(\.message))")
        #expect(contents.actions.map(\.file.lastPathComponent).sorted() == ["search-ddg.toml", "shrink-video.toml", "tracking.toml"])
        #expect(contents.commands.map(\.file.lastPathComponent).sorted() == ["deploy.toml", "github.toml", "tracking.toml"])
    }

    @Test func anActionOnFiles() throws {
        let shrink = try action("shrink-video.toml")
        #expect(shrink.definition.trigger == nil)
        #expect(shrink.accepts(.files([URL(filePath: "/a/clip.mov")])))
        #expect(!shrink.accepts(.files([URL(filePath: "/a/photo.png")])))
        #expect(shrink.definition.resolvedOutput(for: .files) == .files)
    }

    @Test func aTriggerThatOpensAURL() async throws {
        let github = try command("github.toml")
        #expect(github.name == "gh")
        #expect(!github.definition.takesContext)
        #expect(github.usage == "gh owner/repo")
        #expect(try await github.resolve(.text("apple/swift")) == .open(.url(URL(string: "https://github.com/apple/swift")!)))
    }

    @Test func aTriggerThatRunsACommandAfterAsking() async throws {
        let deploy = try command("deploy.toml")
        #expect(deploy.name == "deploy")
        #expect(deploy.argument?.isRequired == false)
        #expect(try await deploy.resolve(.none).kind == .act, "the question is previewed")
        #expect(deploy.accepts(.none) && deploy.accepts(.text("staging")), "the argument is optional")
        #expect(deploy.definition.resolvedOutput(for: .text) == .none)
    }

    @Test func aTriggerThatAlsoRunsOnTheClipboard() throws {
        let tracking = try action("tracking.toml")
        #expect(try command("tracking.toml").name == "track")
        #expect(tracking.matches(.text("1Z999AA10123456784")))
        #expect(!tracking.matches(.text("hello")))
        let listed = ActionCatalog.list([tracking], query: "", for: .context(.text("1Z999AA10123456784")))
        #expect(listed.count == 1)
    }
}
