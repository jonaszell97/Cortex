import Foundation
import Testing
import CortexCore

@Suite struct KnowledgeItemExportTests {
    func item(_ path: String, _ text: String) throws -> KnowledgeItem {
        try #require(KnowledgeItem.parse(path: path, text: text, modified: .now))
    }

    // MARK: - Deep links

    @Test func itemLinksRoundTripWithEncodedComponents() throws {
        let link = KnowledgeLink.item("server-config/notes/2026-10-22 docker & co?.md")
        #expect(link.url.absoluteString == "cortex://item/server-config/notes/2026-10-22%20docker%20&%20co%3F.md")
        #expect(KnowledgeLink(url: link.url) == link)
    }

    @Test func searchAndNewLinks() throws {
        let search = KnowledgeLink.search("@server #docker compose")
        #expect(KnowledgeLink(url: search.url) == search)
        #expect(KnowledgeLink(url: URL(string: "cortex://search?q=potrace")!) == .search("potrace"))
        #expect(KnowledgeLink(url: URL(string: "cortex://search")!) == .search(""))

        #expect(KnowledgeLink(url: URL(string: "cortex://new?kind=todo")!) == .new(.todo, project: nil))
        #expect(KnowledgeLink(url: URL(string: "cortex://new")!) == .new(.note, project: nil))
        let new = KnowledgeLink.new(.todo, project: "server-config")
        #expect(new.url.absoluteString == "cortex://new?kind=todo&project=server-config")
        #expect(KnowledgeLink(url: new.url) == new)
    }

    @Test func readsTheMCPServersResourceURIs() {
        #expect(KnowledgeLink(url: URL(string: "cortex://server-config/notes/docker.md")!) == .item("server-config/notes/docker.md"))
        #expect(KnowledgeLink(url: URL(string: "cortex://server-config/assets/a.png")!) == nil, "not an item")
    }

    @Test func refusesOtherLinks() {
        #expect(KnowledgeLink(url: URL(string: "cortex://")!) == nil)
        #expect(KnowledgeLink(url: URL(string: "https://item/inbox/notes/a.md")!) == nil)
        #expect(KnowledgeLink(url: URL(string: "cortex://item/inbox/../../etc/passwd")!) == nil)
        #expect(KnowledgeLink(url: URL(string: "cortex://item/.conflicts/a.md")!) == nil)
        #expect(KnowledgeLink(url: URL(string: "cortex://item")!) == nil)
    }

    // MARK: - Text

    @Test func plainTextOfABody() {
        let markdown = """
            ## Steps

            Run **this** and see [the docs](https://example.com/docs) or https://example.com.

            - one
              - nested
            1. first
            - [ ] open
            - [x] done

            > quoted

            ```
            code here
            ```

            | a | b |
            | - | - |
            | 1 | 2 |

            ![a chart](assets/chart.png)

            ---
            """
        #expect(MarkdownBlock.plainText(MarkdownBlock.parse(markdown)) == """
            Steps

            Run this and see the docs (example.com/docs) or https://example.com.

            • one
                • nested
            1. first
            ☐ open
            ☑ done

            > quoted

            code here

            a\tb
            1\t2

            a chart

            ———
            """)
    }

    @Test func markdownAndNotesTextLeadWithTheTitle() throws {
        let note = try item("inbox/notes/a.md", "---\ntitle: Potrace\n---\n\nConvert with *potrace*.\n")
        #expect(note.markdown == "# Potrace\n\nConvert with *potrace*.\n")
        #expect(note.notesText == "Potrace\n\nConvert with potrace.")
        #expect(note.link == URL(string: "cortex://item/inbox/notes/a.md"))

        // An imported note repeats its title as a heading: not twice.
        let imported = try item("inbox/notes/b.md", "---\ntitle: Potrace\n---\n\n# Potrace\n\nText.\n")
        #expect(imported.markdown == "# Potrace\n\nText.\n")
        #expect(imported.notesText == "Potrace\n\nText.")

        let empty = try item("inbox/notes/c.md", "---\ntitle: Empty\n---\n")
        #expect(empty.markdown == "# Empty\n")
        #expect(empty.notesText == "Empty")
    }

    // MARK: - Reminders

    @Test func aToDoAsOneReminder() throws {
        let todo = try item("inbox/todos/a.md", """
            ---
            title: Rotate the key
            status: open
            due: 2026-10-30
            ---

            On atlas.

            - [ ] check the cron log
            - [x] update the env
            """)
        #expect(KnowledgeReminder.reminders(for: todo, perItem: false) == [
            KnowledgeReminder(
                key: "", title: "Rotate the key",
                notes: "On atlas.\n\n☐ check the cron log\n☑ update the env\n\ncortex://item/inbox/todos/a.md",
                due: DateComponents(year: 2026, month: 10, day: 30), isCompleted: false),
        ])
    }

    @Test func aToDoAsOneReminderPerItem() throws {
        let todo = try item("inbox/todos/a.md", """
            ---
            title: Groceries
            status: done
            ---

            - [ ] **milk**
            - [x] bread
            - [ ] milk
            """)
        let notes = "From “Groceries”\ncortex://item/inbox/todos/a.md"
        #expect(KnowledgeReminder.reminders(for: todo, perItem: true) == [
            KnowledgeReminder(key: "milk", title: "milk", notes: notes, due: nil, isCompleted: true),
            KnowledgeReminder(key: "bread", title: "bread", notes: notes, due: nil, isCompleted: true),
            KnowledgeReminder(key: "milk (2)", title: "milk", notes: notes, due: nil, isCompleted: true),
        ])

        // Without a checklist, one reminder after all.
        let note = try item("inbox/notes/a.md", "---\ntitle: Read this\n---\n")
        #expect(KnowledgeReminder.reminders(for: note, perItem: true) == [
            KnowledgeReminder(key: "", title: "Read this", notes: "cortex://item/inbox/notes/a.md", due: nil, isCompleted: false),
        ])
    }

    @Test func dueDays() {
        #expect(KnowledgeReminder.dueComponents("2026-01-05") == DateComponents(year: 2026, month: 1, day: 5))
        #expect(KnowledgeReminder.dueComponents("2026-13-05") == nil)
        #expect(KnowledgeReminder.dueComponents("friday") == nil)
    }
}
