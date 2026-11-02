import Foundation
import Testing
@testable import CortexCore

@Suite struct TextActionTests {
    func action(_ id: String) -> TextAction {
        TextAction.all.first { $0.id == id }!
    }

    func text(_ id: String, _ input: String) throws -> String {
        guard case .text(let output) = try action(id).perform(.text(input)) else {
            Issue.record("\(id) did not return text")
            return ""
        }
        return output
    }

    @Test func jsonPrettyKeepsKeyOrderAndNumbers() throws {
        let input = #"{"b":1.50,"a":[1,2,{"c":null}],"e":{},"f":[],"s":"x\"y\u00e9"}"#
        #expect(try JSONFormatter.pretty(input) == """
            {
              "b": 1.50,
              "a": [
                1,
                2,
                {
                  "c": null
                }
              ],
              "e": {},
              "f": [],
              "s": "x\\"y\\u00e9"
            }
            """)
        #expect(try text("text.json.pretty", " [ true , false ] ") == "[\n  true,\n  false\n]")
    }

    @Test func jsonMinify() throws {
        #expect(try text("text.json.minify", "{\n  \"a\" : [ 1, 2e3 ],\n  \"b\": \"x y\"\n}\n") == #"{"a":[1,2e3],"b":"x y"}"#)
    }

    @Test func invalidJSONSaysWhere() {
        #expect(throws: QuickActionError("Not valid JSON: Expected “,” or “}” (line 2, column 3)")) {
            try JSONFormatter.pretty("{\"a\": 1\n  \"b\": 2}")
        }
        #expect(throws: QuickActionError.self) { try JSONFormatter.minify("{\"a\": 01}") }
        #expect(throws: QuickActionError.self) { try JSONFormatter.minify("[1,]") }
        #expect(throws: QuickActionError.self) { try JSONFormatter.minify("[1] x") }
    }

    @Test func base64RoundTrip() throws {
        #expect(try text("text.base64.encode", "Grüße") == "R3LDvMOfZQ==")
        #expect(try text("text.base64.decode", "R3LDvMOfZQ==") == "Grüße")
        #expect(try text("text.base64.decode", "R3LD\nvMOfZQ") == "Grüße", "line breaks and missing padding")
        #expect(try text("text.base64.decode", "PDw_Pz4-") == "<<??>>", "URL-safe alphabet")
        #expect(throws: QuickActionError.self) { try action("text.base64.decode").perform(.text("not base64!")) }
    }

    @Test func base64DecodesImages() throws {
        let png = makePNG(width: 2, height: 2)
        let output = try action("text.base64.decode").perform(.text("data:image/png;base64," + png.base64EncodedString()))
        #expect(output == .image(png))
    }

    @Test func urlEncoding() throws {
        #expect(try text("text.url.encode", "a b&c=d/é") == "a%20b%26c%3Dd%2F%C3%A9")
        #expect(try text("text.url.decode", "a%20b%26c%3Dd%2F%C3%A9") == "a b&c=d/é")
        #expect(throws: QuickActionError.self) { try action("text.url.decode").perform(.text("100%")) }
    }

    @Test func caseAndWhitespace() throws {
        #expect(try text("text.trim", "  \n hello world \t\n") == "hello world")
        #expect(try text("text.uppercase", "straße") == "STRASSE")
        #expect(try text("text.lowercase", "ÄBC") == "äbc")
        #expect(try text("text.titlecase", "the quick brown fox") == "The Quick Brown Fox")
    }

    @Test func caseConversionsAcceptAnyInputCase() throws {
        let inputs = ["foo bar baz", "fooBarBaz", "FooBarBaz", "foo_bar_baz", "foo-bar-baz", "FOO_BAR_BAZ", "Foo Bar Baz", "foo.bar.baz", "  foo -- bar__baz "]
        for input in inputs {
            #expect(try text("text.case.snake", input.trimmingCharacters(in: .whitespaces)) == "foo_bar_baz", "\(input)")
            #expect(try text("text.case.camel", input.trimmingCharacters(in: .whitespaces)) == "fooBarBaz", "\(input)")
            #expect(try text("text.case.pascal", input.trimmingCharacters(in: .whitespaces)) == "FooBarBaz", "\(input)")
            #expect(try text("text.case.kebab", input.trimmingCharacters(in: .whitespaces)) == "foo-bar-baz", "\(input)")
            #expect(try text("text.case.constant", input.trimmingCharacters(in: .whitespaces)) == "FOO_BAR_BAZ", "\(input)")
        }
    }

    @Test func caseConversionsKeepAcronymsAndDigitsTogether() throws {
        #expect(try text("text.case.snake", "HTTPServerError") == "http_server_error")
        #expect(try text("text.case.snake", "parseXML") == "parse_xml")
        #expect(try text("text.case.camel", "HTTP_SERVER") == "httpServer")
        #expect(try text("text.case.snake", "sha256Hash") == "sha256_hash")
        #expect(try text("text.case.snake", "v2Beta") == "v2_beta")
        #expect(try text("text.case.pascal", "größe der straße") == "GrößeDerStraße")
    }

    @Test func caseConversionsWorkPerLine() throws {
        #expect(try text("text.case.snake", "fooBar\n  bazQux\r\n_privateName\n\n__init__") == "foo_bar\n  baz_qux\r\n_private_name\n\n__init__")
        #expect(try text("text.case.camel", "foo bar\n---\nbaz") == "fooBar\n\nbaz")
    }

    @Test func caseConversionNeedsAWord() {
        #expect(throws: QuickActionError("No words found")) { try action("text.case.snake").perform(.text(" -- __ ")) }
    }

    @Test func singleLineJoinsAShellCommand() throws {
        let command = #"""
            build dataset --output-dir datasets/example-b \
              --benchmark-runs runs/grid-v2/step3/source-a \
              --source-dir /Volumes/Data/source-work \
              --min-score 0.815 --run-gates 131_:0:0.80 --max-per-case 4 \
              --exclude runs/grid-v2/step1/rejected.txt,runs/grid-v2/step3/rejected.txt \
              --hero-modes-a raw --hero-modes-b raw

            """#
        #expect(try text("text.singleline", command) == "build dataset --output-dir datasets/example-b --benchmark-runs runs/grid-v2/step3/source-a --source-dir /Volumes/Data/source-work --min-score 0.815 --run-gates 131_:0:0.80 --max-per-case 4 --exclude runs/grid-v2/step1/rejected.txt,runs/grid-v2/step3/rejected.txt --hero-modes-a raw --hero-modes-b raw")
    }

    @Test func singleLineEdgeCases() {
        #expect(TextTransforms.singleLine("a \\  \r\n\tb \\\r\nc") == "a b c", "CRLF, spaces after the backslash, tabs")
        #expect(TextTransforms.singleLine("--out\\\nput x") == "--output x", "no space on either side: the shell joins the words")
        #expect(TextTransforms.singleLine("echo 'a  b' \\\\\nls") == "echo 'a  b' \\\\ ls", "an escaped backslash does not continue")
        #expect(TextTransforms.singleLine("first\n\n  second  \n") == "first second", "plain line breaks and blank lines")
        #expect(TextTransforms.singleLine("  one line  ") == "one line")
    }

    @Test func counts() throws {
        #expect(try action("text.count").perform(.text("Hello, world.\nSecond line here")) == .done("5 words · 30 characters · 2 lines"))
        #expect(TextTransforms.counts("one") == "1 word · 3 characters · 1 line")
    }

    @Test func markdownTable() throws {
        let tsv = "Name\tAge\tCity\nAda\t36\tLondon\nLinus\t\"5|4\"\nGrace\t85\tNew York\n"
        #expect(try text("text.markdown.table", tsv) == """
            | Name  | Age  | City     |
            | ----- | ---- | -------- |
            | Ada   | 36   | London   |
            | Linus | 5\\|4 |          |
            | Grace | 85   | New York |
            """)
        #expect(throws: QuickActionError("No tab-separated columns found")) {
            try TextTransforms.markdownTable(fromTSV: "just one column\nno tabs")
        }
    }

    @Test func markdownTableRefusesTablesThatWouldExplode() {
        // A few KB of tabs and newlines used to become hundreds of MB.
        let wide = String(repeating: "\t", count: 4000) + String(repeating: "\n", count: 4000)
        #expect(throws: QuickActionError.self) { try TextTransforms.markdownTable(fromTSV: wide) }
        let tall = String(repeating: String(repeating: "x", count: 1000) + "\t" + String(repeating: "\t", count: 150) + "\n", count: 100)
            + String(repeating: "a\tb\n", count: 20_000)
        #expect(throws: QuickActionError.self) { try TextTransforms.markdownTable(fromTSV: tall) }
    }

    @Test func padUsesItsOptions() async throws {
        let pad = action("text.pad")
        #expect(pad.options.map(\.id) == ["side", "length", "character"])
        #expect(try pad.perform(.text("42")) == .text("0000000042"), "defaults: left, 10, “0”")

        var options = ActionOptionValues()
        options[PadOptions.side] = "right"
        options[PadOptions.length] = " 5 "
        options[PadOptions.character] = "·"
        #expect(try pad.perform(.text("ab"), options: options) == .text("ab···"))
        let context = ActionContext(fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), options: options)
        #expect(try await pad.run(.text("ab"), context: context) == .text("ab···"), "a run gets them from the context")
    }

    @Test func padWorksPerLine() {
        #expect(TextTransforms.pad("1\n22\n\n4444\r\n55555\n", to: 4, with: "0", left: true) == "0001\n0022\n\n4444\r\n55555\n",
                "longer and empty lines stay, line breaks are kept")
        #expect(TextTransforms.pad("é", to: 3, with: " ", left: false) == "é  ", "counts characters, not bytes")
    }

    @Test func padRejectsBadOptions() {
        let pad = action("text.pad")
        var options = ActionOptionValues()
        options[PadOptions.length] = "abc"
        #expect(throws: QuickActionError("Length must be a whole number from 1 to 1000")) { try pad.perform(.text("x"), options: options) }
        options[PadOptions.length] = "0"
        #expect(throws: QuickActionError.self) { try pad.perform(.text("x"), options: options) }
        options[PadOptions.length] = "3"
        options[PadOptions.character] = ""
        #expect(throws: QuickActionError("Character: enter one character")) { try pad.perform(.text("x"), options: options) }
        options[PadOptions.character] = "ab"
        #expect(throws: QuickActionError.self) { try pad.perform(.text("x"), options: options) }
    }

    @Test func qrCodeIsAPNG() throws {
        let output = try action("text.qrcode").perform(.text("https://example.com/notes"))
        guard case .image(let data) = output else {
            Issue.record("expected an image")
            return
        }
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    }

    @Test func createSnippetKeepsTheTextAsIs() throws {
        let snippet = action("snippet.create")
        #expect(try snippet.perform(.text("  Hi {name},\n")) == .snippet("  Hi {name},\n"))
        #expect(!snippet.accepts(.text("")) && !snippet.accepts(.none))
    }

    @Test func generators() throws {
        let uuid = try text("generate.uuid", "")
        #expect(UUID(uuidString: uuid) != nil)
        let date = Date(timeIntervalSince1970: 1_792_159_509)
        #expect(TextTransforms.isoDate(date, timeZone: TimeZone(identifier: "Europe/Berlin")!) == "2026-10-16T16:05:09+02:00")
        #expect(TextTransforms.isoDate(date, timeZone: TimeZone(identifier: "UTC")!) == "2026-10-16T14:05:09Z")
    }

    @Test func whatTextActionsAccept() {
        let json = action("text.json.pretty")
        #expect(json.accepts(.text("{}")))
        #expect(!json.accepts(.text("")))
        #expect(!json.accepts(.files([URL(filePath: "/tmp/a.json")])))
        #expect(!json.accepts(.none))
        let uuid = action("generate.uuid")
        #expect(uuid.accepts(.none) && uuid.accepts(.text("x")))
        #expect(!uuid.accepts(.files([URL(filePath: "/tmp/a.png")])), "not cluttering the file actions")
    }

    @Test func idsAreUnique() {
        let ids = ActionCatalog.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite struct ActionCatalogTests {
    let actions = ActionCatalog.builtIns

    @Test func filtersByInput() {
        let forText = ActionCatalog.rank(actions, for: .text("x"), query: "")
        #expect(forText.contains { $0.id == "text.json.pretty" })
        #expect(!forText.contains { $0.id == "file.video.gif" })

        let forVideo = ActionCatalog.rank(actions, for: .files([URL(filePath: "/tmp/clip.mov")]), query: "")
        #expect(forVideo.map(\.id).contains("file.video.gif"))
        #expect(!forVideo.contains { $0.id == "file.image.jpg" })
        #expect(!forVideo.contains { $0.id == "text.uppercase" })
        #expect(forVideo.contains { $0.id == "file.zip" })

        let mixed = ActionCatalog.rank(actions, for: .files([URL(filePath: "/tmp/a.heic"), URL(filePath: "/tmp/b.mov")]), query: "")
        #expect(!mixed.contains { $0.id == "file.image.jpg" }, "every file must fit")

        let onePDF = ActionCatalog.rank(actions, for: .files([URL(filePath: "/tmp/a.pdf")]), query: "")
        #expect(!onePDF.contains { $0.id == "file.pdf.merge" }, "merging needs two")
        #expect(onePDF.contains { $0.id == "file.pdf.compress" })

        let image = ActionCatalog.rank(actions, for: .image(Data([1])), query: "")
        #expect(image.contains { $0.id == "file.image.jpg" })
        #expect(!image.contains { $0.id == "file.zip" })
    }

    @Test func searchMatchesTitleAndKeywords() {
        let heic = ActionInput.files([URL(filePath: "/tmp/IMG_0001.HEIC")])
        #expect(ActionCatalog.rank(actions, for: heic, query: "jpg").first?.id == "file.image.jpg")
        #expect(ActionCatalog.rank(actions, for: heic, query: "jpeg").first?.id == "file.image.jpg")
        #expect(ActionCatalog.rank(actions, for: .files([URL(filePath: "/tmp/a.mov")]), query: "gif").first?.id == "file.video.gif")
        #expect(ActionCatalog.rank(actions, for: .text("{}"), query: "json min").first?.id == "text.json.minify")
        #expect(ActionCatalog.rank(actions, for: .text("x"), query: "zzz").isEmpty)
    }

    @Test func usageOrdersEqualMatches() {
        let input = ActionInput.text("x")
        let usage = ["text.lowercase": ActionUsage(count: 3, lastUsedAt: .now)]
        #expect(ActionCatalog.rank(actions, for: input, query: "", usage: usage).first?.id == "text.lowercase")
        #expect(ActionCatalog.rank(actions, for: input, query: "ercase", usage: usage).first?.id == "text.lowercase")
        #expect(ActionCatalog.rank(actions, for: input, query: "").first?.id == "text.json.pretty", "catalog order without usage")
    }
}
