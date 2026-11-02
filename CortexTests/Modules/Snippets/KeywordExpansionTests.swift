import AppKit
import Carbon.HIToolbox
import Testing
@testable import Cortex
import CortexCore

@Suite struct KeywordBufferTests {
    let keywords = [";sig", ";sig2", "addr", "@@"]

    func buffer(typing text: String) -> KeywordBuffer {
        var buffer = KeywordBuffer()
        buffer.setKeywords(keywords)
        for character in text { buffer.type(String(character)) }
        return buffer
    }

    @Test func matchesAtTheEndAfterABoundary() {
        #expect(buffer(typing: ";sig").match(in: keywords) == ";sig")
        #expect(buffer(typing: "Hello ;sig").match(in: keywords) == ";sig")
        #expect(buffer(typing: "(addr").match(in: keywords) == "addr")
        #expect(buffer(typing: "line\naddr").match(in: keywords) == "addr")
        #expect(buffer(typing: "mail:@@").match(in: keywords) == "@@")
    }

    @Test func noMatchInsideAWord() {
        #expect(buffer(typing: "foo;sig").match(in: keywords) == nil)
        #expect(buffer(typing: "myaddr").match(in: keywords) == nil)
        #expect(buffer(typing: ";si").match(in: keywords) == nil)
        #expect(buffer(typing: ";sig ").match(in: keywords) == nil, "only right after the keyword")
    }

    @Test func longestKeywordWins() {
        var buffer = buffer(typing: ";sig")
        buffer.type("2")
        #expect(buffer.match(in: keywords) == ";sig2")
    }

    @Test func backspaceEditsTheBuffer() {
        var buffer = buffer(typing: ";sigx")
        #expect(buffer.match(in: keywords) == nil)
        buffer.deleteBackward()
        #expect(buffer.match(in: keywords) == ";sig")
        var empty = KeywordBuffer()
        empty.deleteBackward()
        #expect(empty.text.isEmpty)
    }

    @Test func resetForgetsEverything() {
        var buffer = buffer(typing: "foo")
        buffer.reset()
        #expect(buffer.text.isEmpty)
        buffer.type(";sig")
        #expect(buffer.match(in: keywords) == ";sig", "after a reset, the start counts as a boundary")
    }

    @Test func staysShort() {
        var buffer = buffer(typing: String(repeating: "x", count: 100))
        #expect(buffer.text.count == KeywordBuffer.minimumCapacity)
        buffer.setKeywords([String(repeating: "k", count: 30)])
        #expect(buffer.capacity == 31)
        #expect(buffer.text.isEmpty, "new keywords start a fresh buffer")
    }

    @Test func longKeywordsFit() {
        let long = ";" + String(repeating: "k", count: 29)
        var buffer = KeywordBuffer()
        buffer.setKeywords([long])
        buffer.type("some text before " + long)
        #expect(buffer.match(in: [long]) == long)
    }
}

@MainActor
@Suite struct KeywordExpanderKeyTests {
    func action(_ keyCode: Int, _ flags: CGEventFlags = [], _ characters: String = "") -> KeywordExpander.KeyAction {
        KeywordExpander.action(keyCode: keyCode, flags: flags, characters: characters)
    }

    @Test func typedCharactersGoToTheBuffer() {
        #expect(action(kVK_ANSI_A, [], "a") == .type("a"))
        #expect(action(kVK_ANSI_A, .maskShift, "A") == .type("A"))
        // ⌥L is @ on a German keyboard: ⌥ types characters, it is no shortcut.
        #expect(action(kVK_ANSI_L, .maskAlternate, "@") == .type("@"))
        #expect(action(kVK_Return, [], "\r") == .type("\r"))
        #expect(action(kVK_Tab, [], "\t") == .type("\t"))
        #expect(action(kVK_Space, [], " ") == .type(" "))
    }

    @Test func shortcutsAndCursorKeysReset() {
        #expect(action(kVK_ANSI_V, .maskCommand, "v") == .reset)
        #expect(action(kVK_ANSI_A, .maskControl, "\u{01}") == .reset)
        #expect(action(kVK_LeftArrow, [], "\u{F702}") == .reset)
        #expect(action(kVK_Home) == .reset)
        #expect(action(kVK_Escape, [], "\u{1B}") == .reset)
        #expect(action(kVK_ForwardDelete, [], "\u{F728}") == .reset)
        #expect(action(kVK_F5, [], "\u{F708}") == .reset)
    }

    @Test func backspace() {
        #expect(action(kVK_Delete, [], "\u{08}") == .deleteBackward)
        #expect(action(kVK_Delete, .maskAlternate, "\u{08}") == .reset, "⌥⌫ deletes a whole word")
    }

    @Test func deadKeysWaitForTheComposedCharacter() {
        #expect(action(kVK_ANSI_E, .maskAlternate, "") == .ignore)
    }

    @Test func processingFindsKeywordsOffTheMainThread() async {
        var state = KeywordExpander.State(keywords: [";sig": 7])
        state.buffer.setKeywords(state.keywords.keys)
        let result = await Task.detached { () -> [Int64] in
            var matches: [Int64] = []
            for character in "Hi ;sig" {
                let input = KeywordExpander.Input(type: .keyDown, keyCode: kVK_ANSI_A, characters: String(character))
                if let match = KeywordExpander.process(input, in: &state) { matches.append(match.id) }
            }
            return matches
        }.value
        #expect(result == [7])
    }

    @Test func ownEventsClicksAndOwnWindowsDoNotExpand() {
        var state = KeywordExpander.State(keywords: [";sig": 7])
        func type(_ text: String, own: Bool = false) -> Int64? {
            var last: Int64?
            for character in text {
                let input = KeywordExpander.Input(type: .keyDown, keyCode: kVK_ANSI_A, characters: String(character), isOwn: own)
                last = KeywordExpander.process(input, in: &state)?.id
            }
            return last
        }
        #expect(type(";sig", own: true) == nil)
        #expect(type(";si") == nil)
        _ = KeywordExpander.process(.init(type: .leftMouseDown, keyCode: 0), in: &state)
        #expect(type("g") == nil, "a click resets the buffer")
        state.ownWindowIsKey = true
        #expect(type(";sig") == nil)
        state.ownWindowIsKey = false
        #expect(type(" ;sig") == 7)
    }

    @Test func stoppedWithoutStarting() {
        let expander = KeywordExpander()
        expander.stop()
        #expect(!expander.isRunning)
    }
}

@MainActor
@Suite struct SnippetsSettingsTests {
    @Test func keywordExpansionIsOffByDefault() {
        let suiteName = "CortexTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = SnippetsSettings(defaults: defaults)
        #expect(!settings.keywordExpansion)
        settings.keywordExpansion = true
        #expect(SnippetsSettings(defaults: defaults).keywordExpansion)
    }
}
