import Foundation
import Testing
@testable import CortexCore

@Suite struct TOMLTests {
    @Test func parsesTheSupportedSubset() throws {
        let table = try TOML.parse(#"""
            # An action
            name = "Shrink \"video\"" # trailing comment
            literal = 'C:\path'
            count = 1_000
            negative = -3
            enabled = true
            "quoted key" = false
            list = [
              "a",   # first
              'b',
            ]
            empty = []
            command = """
            line one \
              still one
            line two"""
            raw = '''
            keep \n as is'''
            """#)
        #expect(table["name"] == .string("Shrink \"video\""))
        #expect(table["literal"] == .string(#"C:\path"#))
        #expect(table["count"] == .integer(1000))
        #expect(table["negative"] == .integer(-3))
        #expect(table["enabled"] == .bool(true))
        #expect(table["quoted key"] == .bool(false))
        #expect(table["list"] == .array([.string("a"), .string("b")]))
        #expect(table["empty"] == .array([]))
        #expect(table["command"] == .string("line one still one\nline two"))
        #expect(table["raw"] == .string(#"keep \n as is"#))
    }

    @Test func reportsErrorsWithLines() {
        #expect(throws: TOML.ParseError(line: 2, message: "Expected “=” after “b”")) { try TOML.parse("a = 1\nb 2") }
        #expect(throws: TOML.ParseError(line: 1, message: "Tables ([section]) are not supported; put every key at the top")) {
            try TOML.parse("[action]\nname = 'x'")
        }
        #expect(throws: TOML.ParseError(line: 2, message: "“a” is set twice")) { try TOML.parse("a = 1\na = 2") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("a = \"unterminated") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("a = bare") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("a = 1.5") }
        #expect(throws: TOML.ParseError.self) { try TOML.parse("a = 1 b = 2") }
    }
}

@Suite struct UserActionDefinitionTests {
    // MARK: - Actions on what the palette finds

    @Test func parsesAFullDefinition() throws {
        let definition = try UserActionDefinition.parse("""
            name = "Shrink video"
            accepts = ["files"]
            extensions = [".MOV", "mp4"]
            command = "ffmpeg -i {input} -vf scale=-2:720 {output}"
            output_extension = ".mp4"
            output_suffix = "-720p"
            symbol = "film"
            keywords = ["small"]
            """)
        #expect(definition == UserActionDefinition(
            name: "Shrink video", target: .shell("ffmpeg -i {input} -vf scale=-2:720 {output}"), accepts: [.files],
            extensions: ["mov", "mp4"], outputExtension: "mp4", outputSuffix: "-720p",
            symbol: "film", keywords: ["small"]))
        #expect(definition.resolvedOutput(for: .files) == .files)
    }

    @Test func defaultsForTheOutput() throws {
        let filter = try UserActionDefinition.parse("name = 'Sort'\naccepts = 'text'\ncommand = 'sort'")
        #expect(filter.resolvedOutput(for: .text) == .text)
        let open = try UserActionDefinition.parse("name = 'Preview'\naccepts = ['files']\ncommand = 'open -a Preview {input}'")
        #expect(open.resolvedOutput(for: .files) == .none)
        let hash = try UserActionDefinition.parse("name = 'Hash'\naccepts = ['files']\ncommand = 'shasum {input}'\noutput = 'text'")
        #expect(hash.resolvedOutput(for: .files) == .text)
    }

    @Test func explainsMistakes() {
        func message(_ text: String) -> String? {
            do {
                _ = try UserActionDefinition.parse(text)
                return nil
            } catch {
                return (error as? QuickActionError)?.message
            }
        }
        #expect(message("accepts = ['text']\ncommand = 'x'") == "“name” is missing")
        #expect(message("name = 'x'\naccepts = ['text']") == "“command” is missing")
        #expect(message("name = 'x'\ncommand = 'x'") == "“accepts” is missing (any of: text, image, files, none)")
        #expect(message("name = 'x'\naccepts = ['file']\ncommand = 'x'") == "“accepts” has “file”; use text, image, files or none")
        #expect(message("name = 'x'\naccepts = ['text']\ncommand = 'x'\ncomand = 'y'") == "Unknown key “comand”")
        #expect(message("name = 'x'\naccepts = ['files']\ncommand = 'x {input}'\noutput = 'files'") == "“output” is files, but the command never writes to {output}")
        #expect(message("name = 'x'\naccepts = ['text']\ncommand = 'x'\noutput = 'clipboard'") == "“output” is “clipboard”; use files, text or none")
        #expect(message("name = 'x\naccepts") == "line 1: Line break in a string; use '''…''' for several lines")
    }

    // MARK: - With a trigger

    @Test func parsesAQuicklink() throws {
        let definition = try UserActionDefinition.parse("""
            name = "GitHub Repository"
            trigger = "gh"
            url = "https://github.com/{argument}"
            example = "owner/repo"
            keywords = ["github"]
            """)
        #expect(definition == UserActionDefinition(
            name: "GitHub Repository", target: .url("https://github.com/{argument}"), accepts: [.text],
            takesContext: false, trigger: "gh", example: "owner/repo", keywords: ["github"]))
    }

    @Test func parsesAShellCommand() throws {
        let definition = try UserActionDefinition.parse("""
            name = "Deploy"
            trigger = "$deploy"
            command = "~/bin/deploy.sh {argument}"
            argument = "optional"
            confirm = true
            output = "text"
            symbol = "paperplane"
            """)
        #expect(definition == UserActionDefinition(
            name: "Deploy", target: .shell("~/bin/deploy.sh {argument}"), accepts: [.text, .none], takesContext: false,
            output: .text, trigger: "deploy", confirm: true, symbol: "paperplane"))
    }

    @Test func theArgumentDefaultsToWhetherItIsUsed() throws {
        let without = try UserActionDefinition.parse("name = 'Lock'\ntrigger = 'lock'\ncommand = 'pmset displaysleepnow'")
        #expect(without.accepts == [.none])
        let shellArgument = try UserActionDefinition.parse("name = 'Say'\ntrigger = 'say'\ncommand = 'say \"$1\"'\nargument = 'required'")
        #expect(shellArgument.accepts == [.text], "it may use $1 instead of {argument}")
    }

    @Test func reportsProblems() {
        let cases: [(String, String)] = [
            ("trigger = 'x'\nurl = 'https://x'", "“name” is missing"),
            ("name = 'X'\ntrigger = 'two words'\nurl = 'https://x'", "“trigger” must be one word, like “gh” for $gh"),
            ("name = 'X'\ntrigger = 'x'", "“url” or “command” is missing"),
            ("name = 'X'\ntrigger = 'x'\nurl = 'https://x'\ncommand = 'ls'", "Give either “url” or “command”, not both"),
            ("name = 'X'\ntrigger = 'x'\nurl = 'not a url {argument}'", "“not a url x” is not a URL"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'cat {input}'", "{input} needs “accepts”; with only a trigger the command gets {argument}"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'ls'\naccepts = ['text']\nargument = 'optional'", "Give either “accepts” or “argument”, not both"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'echo {argument}'\nargument = 'none'", "“argument” is none, but {argument} is used"),
            ("name = 'X'\ntrigger = 'x'\ncommand = \"jq '.{argument}'\"", "{argument} is inside single quotes, where the shell cannot fill it in; use double quotes"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'ls'\nargument = 'maybe'", "“argument” is “maybe”; use required, optional or none"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'ls'\noutput = 'files'", "“output” is files, but the command never writes to {output}"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'ls'\noutput = 'clipboard'", "“output” is “clipboard”; use files, text or none"),
            ("name = 'X'\naccepts = ['files']\nurl = 'https://x/{argument}'", "{argument} is text, but “accepts” has no text"),
            ("name = 'X'\naccepts = ['files', 'text']\nurl = 'https://x'", "A URL gets text: “accepts” can only have text and none"),
            ("name = 'X'\naccepts = ['text']\nurl = 'https://x/{input}'", "{input} is for commands; a URL gets {argument}"),
            ("name = 'X'\naccepts = ['text']\ncommand = 'ls'\nexample = 'x'", "“example” shows how to type the trigger; there is no “trigger”"),
            ("name = 'X'\ntrigger = 'x'\naccepts = ['text']\ncommand = 'ls'\nmatches = '(['", "“matches” is not a regular expression"),
            ("name = 'X'\ntrigger = 'x'\nurl = 'https://x'\noutput = 'text'", "“output” is only for commands; a URL is opened"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'ls'\nconfirm = 'yes'", "“confirm” must be true or false"),
            ("name = 'X'\ntrigger = 'x'\ncommand = 'ls'\ncomand = 'ls'", "Unknown key “comand”"),
        ]
        for (text, message) in cases {
            #expect(throws: QuickActionError(message), "\(text)") { try UserActionDefinition.parse(text) }
        }
    }

    @Test func aTriggerAndAcceptsRunOnEither() throws {
        let definition = try UserActionDefinition.parse("""
            name = "Kill Port"
            trigger = ">kp"
            accepts = ["text"]
            matches = "^[0-9]{1,5}$"
            command = "lsof -ti :$1 | xargs kill"
            confirm = true
            """)
        #expect(definition.trigger == "kp")
        #expect(definition.takesContext)
        #expect(definition.accepts == [.text])
        #expect(definition.resolvedOutput(for: .text) == .text, "an action's default output")
        #expect(definition.matches == "^[0-9]{1,5}$")
    }

    @Test func aURLMayWorkOnTheClipboard() throws {
        let definition = try UserActionDefinition.parse("name = 'Search'\naccepts = ['text']\nurl = 'https://duckduckgo.com/?q={argument}'")
        #expect(definition.target == .url("https://duckduckgo.com/?q={argument}"))
        #expect(definition.trigger == nil)
    }
}

@Suite struct UserActionTests {
    @Test func accepts() throws {
        let definition = try UserActionDefinition.parse("name = 'x'\naccepts = ['files']\nextensions = ['heic']\ncommand = 'x'")
        let action = UserAction(definition: definition, file: URL(filePath: "/tmp/convert-heic.toml"))
        #expect(action.id == "user.convert-heic")
        #expect(action.accepts(.files([URL(filePath: "/a/IMG.HEIC")])))
        #expect(!action.accepts(.files([URL(filePath: "/a/IMG.HEIC"), URL(filePath: "/a/b.png")])))
        #expect(!action.accepts(.text("x")))
        #expect(!action.accepts(.files([])))
    }

    func action(_ toml: String) throws -> UserAction {
        UserAction(definition: try UserActionDefinition.parse(toml), file: URL(filePath: "/tmp/cmd.toml"))
    }

    func context() -> ActionContext {
        ActionContext(fallbackOutputDirectory: FileManager.default.temporaryDirectory,
                      temporaryDirectory: FileManager.default.temporaryDirectory)
    }

    @Test func anActionGetsTheTextAsArgumentAndOnStandardInput() async throws {
        let echo = try action("name = 'Echo'\naccepts = ['text']\ncommand = 'printf \"%s|%s|\" {argument} \"$1\"; cat'")
        #expect(try await echo.run(.text("a b"), context: context()) == .text("a b|a b|a b"))
    }

    @Test func matchesNarrowsWhatAFileWithATriggerIsOfferedFor() throws {
        let port = try action("name = 'P'\ntrigger = 'p'\naccepts = ['text']\nmatches = '^[0-9]+$'\ncommand = 'echo $1'")
        #expect(port.matches(.text("3000")))
        #expect(!port.matches(.text("hello")))
        #expect(ActionCatalog.list([port], query: "", for: .context(.text("3000"))).count == 1)
        let anyText = try action("name = 'A'\ntrigger = 'a'\naccepts = ['text', 'files']\ncommand = 'echo {input}'")
        #expect(!anyText.matches(.text("hello")), "a trigger that takes any text waits for $")
        #expect(anyText.matches(.files([URL(filePath: "/tmp/x")])))
        let plain = try action("name = 'U'\naccepts = ['text']\ncommand = 'tr a-z A-Z'")
        #expect(plain.matches(.text("hello")))
    }

    @Test func aConfirmedActionShowsItsCommand() async throws {
        let echo = try action("name = 'T'\naccepts = ['text']\ncommand = 'echo {argument}'\nconfirm = true")
        guard case .confirm(let confirmation) = try await echo.run(.text("x"), context: context()) else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(confirmation.message == "echo 'x'")
        #expect(try await confirmation.perform() == .text("x"))
    }
}

@Suite struct ShellCommandTests {
    @Test func quoting() {
        #expect(ShellCommand.quote("plain") == "'plain'")
        #expect(ShellCommand.quote("it's $HOME") == #"'it'\''s $HOME'"#)
    }

    @Test func placeholdersBecomeVariables() {
        let values = ["input": "/a b/c's.mov", "output": "/out.mp4"]
        let script = ShellCommand.script("ffmpeg -i {input} {output}", values)
        #expect(script.source == #"ffmpeg -i "${CORTEX_INPUT}" "${CORTEX_OUTPUT}""#)
        #expect(script.environment == ["CORTEX_INPUT": "/a b/c's.mov", "CORTEX_OUTPUT": "/out.mp4"])
        #expect(script.arguments.isEmpty)
        #expect(ShellCommand.script(#"cat "{input}" > '{output}'"#, values).source == #"cat "${CORTEX_INPUT}" > "${CORTEX_OUTPUT}""#,
                "quoted alone")
        #expect(ShellCommand.script(#"echo "Result: {argument}!""#, [:]).source == #"echo "Result: ${CORTEX_ARGUMENT}!""#)
        #expect(ShellCommand.script("echo {other} ${input} \\{input}", values).source == "echo {other} ${input} \\{input}",
                "not placeholders")
    }

    @Test func inputsComeAfterTheArguments() {
        let script = ShellCommand.script("zip x.zip {inputs}", [:], inputs: ["/a", "/b c"], arguments: ["text"])
        #expect(script.source == """
            cortex_inputs=("${@[2,-1]}"); set -- "${@[1,1]}"
            zip x.zip "${cortex_inputs[@]}"
            """)
        #expect(script.arguments == ["text", "/a", "/b c"])
    }

    @Test func displayQuotesTheValuesInPlace() {
        let values = ["input": "/a b/c's.mov", "argument": "it's"]
        #expect(ShellCommand.display("ffmpeg -i {input} {output}", values) == #"ffmpeg -i '/a b/c'\''s.mov' {output}"#)
        #expect(ShellCommand.display(#"cat '{input}'; echo "say {argument}""#, values) == #"cat '/a b/c'\''s.mov'; echo "say it's""#)
        #expect(ShellCommand.display("zip x.zip {inputs}", [:], inputs: ["/a", "/b c"]) == "zip x.zip '/a' '/b c'")
    }

    @Test func whereAPlaceholderSits() {
        func quoting(_ template: String) -> [ShellCommand.Quoting] {
            ShellCommand.placeholders(in: template).map(\.quoting)
        }
        #expect(quoting("a {input} b") == [.none])
        #expect(quoting(#"a "{input}" '{input}'"#) == [.none, .none])
        #expect(quoting(#"echo "x {input}" 'y {input}' $'z {input}'"#) == [.double, .single, .single])
        #expect(quoting(#"echo "it's {argument}""#) == [.double])
        #expect(quoting(#"jq '.{argument}'"#) == [.single])
        #expect(quoting(#"echo "$(basename {input})" 'a\' {input}"#) == [.none, .none], "a substitution starts unquoted")
        #expect(quoting(#"echo \"{input} \'"#) == [.none])
        #expect(quoting("echo {input} # don't {input}\necho {output}") == [.none, .none])
    }
}

@Suite struct UserActionLibraryTests {
    @Test func loadsFilesAndReportsProblems() throws {
        let directory = try temporaryDirectory()
        try "name = 'Upper'\naccepts = ['text']\ncommand = 'tr a-z A-Z'".write(to: directory.appending(path: "b-upper.toml"), atomically: true, encoding: .utf8)
        try "name = 'Broken'".write(to: directory.appending(path: "a-broken.toml"), atomically: true, encoding: .utf8)
        try "not an action".write(to: directory.appending(path: "notes.txt"), atomically: true, encoding: .utf8)

        let contents = UserActionLibrary.load(from: directory)
        #expect(contents.actions.map(\.title) == ["Upper"])
        #expect(contents.problems.map(\.file.lastPathComponent) == ["a-broken.toml"])
        #expect(contents.problems.first?.message == "“command” is missing")

        #expect(UserActionLibrary.load(from: directory.appending(path: "missing")).actions.isEmpty)
    }

    @Test func defaultDirectory() {
        #expect(UserActionLibrary.defaultDirectory(environment: ["XDG_CONFIG_HOME": "/x/config"]).path == "/x/config/cortex/actions")
        #expect(UserActionLibrary.defaultDirectory(environment: [:]).path.hasSuffix("/.config/cortex/actions"))
    }
}

func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "CortexActions-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}
