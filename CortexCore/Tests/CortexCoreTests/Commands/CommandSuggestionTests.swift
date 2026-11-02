import Foundation
import Testing
@testable import CortexCore

/// What a `$` form suggests for its argument, and what its field holds as
/// input (docs/modules/COMMANDS.md, "The form" and "Suggestions").
@Suite struct CommandSuggestionTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    private func history(_ texts: String...) -> [RecentClipText] {
        texts.enumerated().map { RecentClipText(text: $1, copiedAt: now.addingTimeInterval(-Double($0) * 60)) }
    }

    // MARK: - Suggestions

    @Test func clipsMatchingThePatternPasteboardFirst() {
        let suggestions = CommandSuggestion.clips(
            pasteboard: "8080", history: history("hello", " 3000\n", "4000 apples", ":5000"),
            matching: PortCommand.portPattern, for: .number(1...65_535))
        #expect(suggestions.map(\.value) == ["8080", "3000", "5000"], ":5000 is suggested as its number")
        #expect(suggestions.first?.source == .clipboard)
        #expect(suggestions[1].source == .history(now.addingTimeInterval(-60)))
    }

    @Test func clipsWithoutDuplicatesAndAtMostFive() {
        let suggestions = CommandSuggestion.clips(
            pasteboard: "3000", history: history("3000", ":3000", "1", "2", "3", "4", "5", "6"),
            matching: PortCommand.portPattern, for: .number(1...65_535))
        #expect(suggestions.map(\.value) == ["3000", "1", "2", "3", "4"])
        #expect(suggestions.first?.source == .clipboard, "the newest clip is the pasteboard")
    }

    @Test func clipsForTextKeepTheTrimmedText() {
        let suggestions = CommandSuggestion.clips(
            pasteboard: nil, history: history("apple/swift ", "no match here", "swiftlang/swift"),
            matching: "^[\\w.-]+/[\\w.-]+$", for: .text)
        #expect(suggestions.map(\.value) == ["apple/swift", "swiftlang/swift"])
    }

    @Test func anInvalidPatternSuggestsNothing() {
        #expect(CommandSuggestion.clips(pasteboard: "x", history: [], matching: "(", for: .text).isEmpty)
    }

    @Test func theClipboardTextIsOneEntry() {
        #expect(CommandSuggestion.clipboardText("why\nis the sky blue") == [CommandSuggestion("why\nis the sky blue", source: .clipboard)])
        #expect(CommandSuggestion.clipboardText(nil).isEmpty)
        #expect(CommandSuggestion.clipboardText(" \n").isEmpty)
    }

    @Test func typingFilters() {
        let suggestions = CommandSuggestion.choices([
            ActionOption.Choice("/", title: "Macintosh HD"),
            ActionOption.Choice("/Volumes/Backup", title: "Backup"),
        ])
        #expect(CommandSuggestion.filter(suggestions, by: "").map(\.value) == ["Macintosh HD", "Backup"])
        #expect(CommandSuggestion.filter(suggestions, by: "mac").map(\.value) == ["Macintosh HD"])
        #expect(CommandSuggestion.filter(suggestions, by: "x").isEmpty)
    }

    // MARK: - The field's value

    @Test func anEmptyFieldIsMissingOrNothing() {
        let required = CommandArgument(title: "Port", placeholder: "3000", kind: .number(1...65_535))
        #expect(required.input(from: " ") == .failure(.missing))
        let optional = CommandArgument(title: "Argument", placeholder: "…", isRequired: false)
        #expect(optional.input(from: "") == .success(.none))
    }

    @Test func numbersInRangeOnly() {
        let port = CommandArgument(title: "Port", placeholder: "3000", kind: .number(1...65_535))
        #expect(port.input(from: " 3000 ") == .success(.text("3000")))
        #expect(port.input(from: "abc") == .failure(.invalid("Port: a whole number from 1 to 65535")))
        #expect(port.input(from: "70000") == .failure(.invalid("Port: a whole number from 1 to 65535")))
        #expect(port.input(from: "٣٠٠٠") == .failure(.invalid("Port: a whole number from 1 to 65535")))
    }

    @Test func pathsMustExist() {
        let home = URL(filePath: "/Users/me")
        let argument = CommandArgument(title: "File", placeholder: "~/a.txt", kind: .path)
        let exists = { (path: String) in path == "/Users/me/a b.txt" }
        #expect(argument.input(from: "'~/a b.txt'", home: home, fileExists: exists)
            == .success(.files([URL(filePath: "/Users/me/a b.txt")])))
        #expect(argument.input(from: "~/nope.txt", home: home, fileExists: exists)
            == .failure(.invalid("File: no file or folder at ~/nope.txt")))
    }

    @Test func choicesMatchByTitleOrValue() {
        let argument = CommandArgument(
            title: "Volume", placeholder: "Macintosh HD",
            kind: .choice(CommandChoices(id: "volumes") { [] }))
        let choices = [ActionOption.Choice("/", title: "Macintosh HD"), ActionOption.Choice("/Volumes/Backup", title: "Backup")]
        #expect(argument.input(from: "macintosh hd", choices: choices) == .success(.text("/")))
        #expect(argument.input(from: "/volumes/backup", choices: choices) == .success(.text("/Volumes/Backup")))
        #expect(argument.input(from: "Nope", choices: choices) == .failure(.invalid("Volume: “Nope” is not in the list")))
        #expect(argument.input(from: "Backup", choices: nil) == .failure(.invalid("Volume: the list is still loading")))
    }

    @Test func textAndPromptsAreTrimmed() {
        let prompt = CommandArgument(title: "Prompt", placeholder: "…", kind: .prompt)
        #expect(prompt.input(from: "\n why\nnot \n") == .success(.text("why\nnot")))
    }
}
