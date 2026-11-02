import Foundation
import Testing
@testable import CortexCore

@Suite struct FrontMatterTests {
    @Test func readsTheToDoExample() throws {
        let text = """
            ---
            title: Fix the restic backup on atlas
            status: open            # open | done
            tags: [backup, "atlas, the server"]
            due: 2026-10-30         # optional
            created: 2026-10-22T10:12:00Z
            done: ~                 # set when status becomes done
            ---
            The nightly run has been failing.
            """
        let (frontMatter, body) = FrontMatter.split(text)
        let meta = try #require(frontMatter)
        #expect(meta.string("title") == "Fix the restic backup on atlas")
        #expect(meta.string("status") == "open")
        #expect(meta.list("tags") == ["backup", "atlas, the server"])
        #expect(meta["done"] == .null)
        #expect(meta.date("created") == Date(timeIntervalSince1970: 1_792_663_920))
        #expect(meta.date("due") != nil)
        #expect(body == "The nightly run has been failing.")
    }

    @Test func readsBlockListsAndKeepsNestedMaps() throws {
        let text = """
            ---
            name: Server config
            folders:
              - ~/Developer/homelab
              - "~/Developer/other"
            metadata:
              type: project
              owner: me
            ---
            About.
            """
        let meta = try #require(FrontMatter.split(text).frontMatter)
        #expect(meta.list("folders") == ["~/Developer/homelab", "~/Developer/other"])
        #expect(meta["metadata"] == .raw("  type: project\n  owner: me"))
        #expect(meta.rendered() == """
            ---
            name: Server config
            folders: [~/Developer/homelab, ~/Developer/other]
            metadata:
              type: project
              owner: me
            ---

            """)
    }

    @Test func textWithoutFrontMatterIsAllBody() {
        #expect(FrontMatter.split("# Hello\n\nworld").frontMatter == nil)
        #expect(FrontMatter.split("---\nno end").frontMatter == nil, "an unclosed block is text")
        #expect(FrontMatter.split("---\n---\nbody").body == "body")
    }

    @Test func roundTripsWhatItWrites() throws {
        var meta = FrontMatter()
        meta.set("title", text: "Convert: PNG to SVG #potrace")
        meta.set("tags", .list(["images", "cli", "a, b"]))
        meta.set("yes", text: "yes")
        meta.set("number", text: "12")
        meta.set("quote", text: "say \"hi\"\nthen go")
        meta.set("updated", date: Date(timeIntervalSince1970: 0))
        let text = FrontMatter.compose(meta, body: "Body\n")
        let (read, body) = FrontMatter.split(text)
        #expect(read == meta)
        #expect(body == "Body\n")
        #expect(text.contains("updated: 1970-01-01T00:00:00Z"))
        #expect(text.contains("title: \"Convert: PNG to SVG #potrace\""))
    }

    @Test func setReplacesInPlaceAndRemoves() {
        var meta = FrontMatter()
        meta.set("a", text: "1")
        meta.set("b", text: "2")
        meta.set("a", text: "3")
        meta.set("b", nil)
        #expect(meta.entries == [FrontMatter.Entry(key: "a", value: .text("3"))])
    }

    @Test func stripsCommentsOnlyOutsideQuotes() {
        #expect(FrontMatter.stripComment("open  # comment") == "open  ")
        #expect(FrontMatter.stripComment("\"a # b\"") == "\"a # b\"")
        #expect(FrontMatter.stripComment("C#") == "C#")
    }
}
