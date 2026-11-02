import Foundation
import Testing
@testable import CortexCore

@Suite struct SnippetTemplateTests {
    /// 2026-10-16 14:05:09 UTC, a Friday.
    static let now = Date(timeIntervalSince1970: 1_792_159_509)

    func render(
        _ body: String,
        clipboard: [Int: String] = [0: "clip"],
        fillIns: [String: String] = [:],
        locale: Locale = Locale(identifier: "en_US_POSIX")
    ) -> RenderedSnippet {
        let context = SnippetContext(
            now: Self.now, locale: locale, timeZone: TimeZone(identifier: "UTC")!,
            clipboard: clipboard, fillIns: fillIns,
            makeUUID: { UUID(uuidString: "00000000-0000-0000-0000-000000000001")! })
        return SnippetTemplate(body).render(in: context)
    }

    @Test func plainTextStaysAsItIs() {
        #expect(render("Hello\nworld").text == "Hello\nworld")
        #expect(SnippetTemplate("Hello").hasPlaceholders == false)
    }

    @Test func clipboard() {
        #expect(render("Copied: {clipboard}.").text == "Copied: clip.")
        #expect(render("{clipboard offset=1}", clipboard: [0: "new", 1: "older"]).text == "older")
        #expect(render("[{clipboard}]", clipboard: [:]).text == "[]", "an empty clipboard pastes nothing")
        #expect(SnippetTemplate("{clipboard} {clipboard offset=2}").clipboardOffsets == [0, 2])
        // Too far back stays as text instead of reading (and overflowing) a huge range.
        #expect(SnippetTemplate("{clipboard offset=100}").clipboardOffsets == [100])
        #expect(SnippetTemplate("{clipboard offset=101}").clipboardOffsets.isEmpty)
        #expect(SnippetTemplate("{clipboard offset=9223372036854775807}").clipboardOffsets.isEmpty)
    }

    @Test func uuid() {
        #expect(render("{uuid}").text == "00000000-0000-0000-0000-000000000001")
    }

    @Test func dates() {
        #expect(render("{date:yyyy-MM-dd}").text == "2026-10-16")
        #expect(render("{date:HH:mm}").text == "14:05", "a colon in the format is part of the format")
        #expect(render("{date format=\"dd.MM.yyyy\"}").text == "16.10.2026")
        #expect(render("{date format=\"yyyy-MM-dd\" offset=\"+1d\"}").text == "2026-10-17")
        #expect(render("{date:yyyy-MM-dd}|{date offset=\"-1w\" format=\"yyyy-MM-dd\"}").text == "2026-10-16|2026-10-09")
        #expect(render("{day}").text == "Friday")
        #expect(render("{date}").text == "Oct 16, 2026")
        #expect(render("{time}", locale: Locale(identifier: "de_DE")).text == "14:05")
        #expect(render("{day}", locale: Locale(identifier: "de_DE")).text == "Freitag")
    }

    @Test func cursor() {
        let rendered = render("Dear {cursor},\nthanks")
        #expect(rendered.text == "Dear ,\nthanks")
        #expect(rendered.cursorPosition == 5)
        #expect(rendered.charactersAfterCursor == 8)

        let twice = render("a{cursor}b{cursor}c")
        #expect(twice.text == "abc")
        #expect(twice.cursorPosition == 1, "only the first cursor counts")

        #expect(render("none").cursorPosition == nil)
        #expect(render("none").charactersAfterCursor == 0)
    }

    @Test func namedFillIns() {
        let template = SnippetTemplate("Hi {first name}, {greeting}! Bye {first name}.")
        #expect(template.fillIns.map(\.name) == ["first name", "greeting"])
        #expect(render("Hi {first name}, {greeting}! Bye {first name}.",
                       fillIns: ["first name": "Ada", "greeting": "welcome"]).text
                == "Hi Ada, welcome! Bye Ada.")
        #expect(render("[{missing}]").text == "[]")
    }

    @Test func raycastArguments() {
        let template = SnippetTemplate("{argument name=\"Team\" default=\"Platform\"} / {argument name=Topic}")
        #expect(template.fillIns == [
            .init(name: "Team", defaultValue: "Platform"),
            .init(name: "Topic", defaultValue: nil),
        ])
        #expect(render("{argument name=\"Team\" default=\"Platform\"}").text == "Platform")
        #expect(render("{argument name=\"Team\" default=\"Platform\"}", fillIns: ["Team": "Core"]).text == "Core")
    }

    @Test func clipboardFilter() {
        let plan = "Run {clipboard|plans/.*\\.md} now"
        #expect(render(plan, clipboard: [0: "/repo/plans/IOS.md"]).text == "Run /repo/plans/IOS.md now")
        #expect(render(plan, clipboard: [0: "/repo/notes/IOS.md"]).text == "Run {placeholder} now", "no match becomes {placeholder}")
        #expect(render(plan, clipboard: [:]).text == "Run {placeholder} now", "an empty clipboard doesn't match")
        #expect(render("{clipboard | ^(a|b)$ | uppercase}", clipboard: [0: "b"]).text == "B", "alternation, then a modifier")
        #expect(render("{clipboard offset=1|^x}", clipboard: [0: "y", 1: "xy"]).text == "xy")
        #expect(render("{clipboard|(}", clipboard: [0: "("]).text == "{clipboard|(}", "an invalid expression is literal text")
        #expect(SnippetTemplate("{clipboard|^a}").clipboardOffsets == [0])
        #expect(SnippetTemplate("{clipboard|a}").hasPlaceholders)
    }

    @Test func modifiers() {
        #expect(render("{clipboard | uppercase}", clipboard: [0: "abc"]).text == "ABC")
        #expect(render("{clipboard|trim|lowercase}", clipboard: [0: "  MiXed \n"]).text == "mixed")
        #expect(render("q={clipboard | percent-encode}", clipboard: [0: "a b&c"]).text == "q=a%20b%26c")
        #expect(render("{clipboard | json-stringify}", clipboard: [0: "say \"hi\"\n"]).text == #""say \"hi\"\n""#)
        #expect(render("{name | uppercase}", fillIns: ["name": "ada"]).text == "ADA")
        #expect(render("{name | shout}").text == "{name | shout}", "an unknown modifier makes it literal")
    }

    @Test func otherBracesStayLiteral() {
        let literals = [
            #"{"key": 1}"#,
            "function f() { return 1 }",
            "{ spaced }",
            "{}",
            "{1st}",
            "{unclosed",
            "{a\nb}",
            "{snippet name=\"other\"}",
            "{date offset=\"+1x\"}",
            "{time:  }",
        ]
        for text in literals {
            #expect(render(text).text == text, "\(text)")
            #expect(!SnippetTemplate(text).hasPlaceholders, "\(text)")
        }
    }

    @Test func nestedBracesUseTheInnerPlaceholder() {
        #expect(render("{{clipboard}}").text == "{clip}")
    }

    @Test func reservedWordsIgnoreCase() {
        #expect(render("{Clipboard}").text == "clip")
        #expect(SnippetTemplate("{Clipboard}").fillIns.isEmpty)
    }

    @Test func placeholderRangesIncludeTheBraces() {
        let body = "Hi {name}, {{clipboard | trim}} {\"json\": 1} 🚀{date format=\"yyyy\" offset=\"+1d\"}{cursor}"
        let found = SnippetTemplate.placeholderRanges(in: body).map { String(body[$0]) }
        #expect(found == ["{name}", "{clipboard | trim}", "{date format=\"yyyy\" offset=\"+1d\"}", "{cursor}"])
        #expect(SnippetTemplate.placeholderRanges(in: "function f() { return 1 }").isEmpty)
    }
}
