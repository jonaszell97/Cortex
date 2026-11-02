import Foundation
import Testing
@testable import CortexCore

/// The iPhone's capture from outside the app (plans/IOS.md, M5): the share
/// extension's notes and links, the widgets' snapshot, Spotlight, the links.
@Suite struct KnowledgeCaptureTests {
    let directory: URL
    let folder: KnowledgeFolder
    let now = Date(timeIntervalSince1970: 1_793_000_000)

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appending(path: "KnowledgeCaptureTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        folder = KnowledgeFolder(root: directory.appending(path: "knowledge", directoryHint: .isDirectory))
        try folder.prepare()
    }

    func item(_ path: String) throws -> KnowledgeItem {
        try #require(try folder.item(at: path))
    }

    // MARK: - Links

    @Test func todosAndReadingListLinks() {
        #expect(KnowledgeLink.todos.url.absoluteString == "cortex://todos")
        #expect(KnowledgeLink.readingList.url.absoluteString == "cortex://reading-list")
        #expect(KnowledgeLink(url: URL(string: "cortex://todos")!) == .todos)
        #expect(KnowledgeLink(url: URL(string: "cortex://reading-list/")!) == .readingList)
        // A project called "todos" still opens through its MCP resources.
        #expect(KnowledgeLink(url: URL(string: "cortex://todos/notes/a.md")!) == .item("todos/notes/a.md"))
    }

    // MARK: - Notes

    @Test(arguments: [
        ("Buy oat milk\nand bread", "Buy oat milk"),
        ("\n\n  # A heading  \nbody", "A heading"),
        ("", ""),
        (String(repeating: "word ", count: 30), String(repeating: "word ", count: 15).trimmingCharacters(in: .whitespaces) + " word…"),
    ])
    func titleOfSharedText(text: String, title: String) {
        let made = KnowledgeCapture.title(forText: text)
        #expect(made == title)
        #expect(made.count <= KnowledgeCapture.maxTitleLength + 1)
    }

    @Test func sharedTextBecomesAnInboxNote() throws {
        let path = try KnowledgeCapture.createNote(
            in: folder, title: "", text: "Ideas for the trip\n\n- Lisbon\n- Porto\n", now: now)
        #expect(path.hasPrefix("inbox/notes/"))
        #expect(path.hasSuffix("-ideas-for-the-trip.md"))
        let note = try item(path)
        #expect(note.title == "Ideas for the trip")
        #expect(note.body == "Ideas for the trip\n\n- Lisbon\n- Porto\n")
    }

    @Test func aLineOfTextIsJustTheTitle() throws {
        let note = try item(try KnowledgeCapture.createNote(in: folder, title: "", text: " Buy oat milk \n", now: now))
        #expect(note.title == "Buy oat milk")
        #expect(note.body == "")
        let long = String(repeating: "word ", count: 30)
        #expect(try item(try KnowledgeCapture.createNote(in: folder, title: "", text: long, now: now)).body
            == long.trimmingCharacters(in: .whitespaces) + "\n")
        let titled = try item(try KnowledgeCapture.createNote(in: folder, title: "Groceries", text: "Buy oat milk", now: now))
        #expect(titled.body == "Buy oat milk\n")
    }

    @Test func picturesGoToAssetsAndAreLinked() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47])
        let pictures = [
            KnowledgeCapture.Picture(data: png, fileExtension: "PNG"),
            KnowledgeCapture.Picture(data: Data([1, 2, 3]), fileExtension: "jpeg"),
        ]
        let path = try KnowledgeCapture.createNote(in: folder, title: "Whiteboard [Monday]", text: "", pictures: pictures, now: now)
        let stem = KnowledgeFolder.fileName(project: "inbox", title: "Whiteboard [Monday]", date: now)
        #expect(try Data(contentsOf: folder.url(for: "inbox/assets/\(stem).png")) == png)
        #expect(try Data(contentsOf: folder.url(for: "inbox/assets/\(stem).jpeg")) == Data([1, 2, 3]))
        let note = try item(path)
        #expect(note.title == "Whiteboard [Monday]")
        #expect(note.body == "![Whiteboard Monday](../assets/\(stem).png)\n\n![Whiteboard Monday](../assets/\(stem).jpeg)\n")
        // The assets are files, not items.
        #expect(folder.itemFiles().keys.sorted() == [path])

        // A second one with the same title doesn't overwrite the first picture.
        let second = try KnowledgeCapture.createNote(in: folder, title: "Whiteboard [Monday]", text: "Again", pictures: [pictures[0]], now: now)
        #expect(try item(second).body == "Again\n\n![Whiteboard Monday](../assets/\(stem)-2.png)\n")
    }

    @Test func picturesAloneAreTitledPicture() throws {
        let picture = KnowledgeCapture.Picture(data: Data([1]), fileExtension: "heic")
        #expect(try item(try KnowledgeCapture.createNote(in: folder, title: " ", text: "", pictures: [picture], now: now)).title == "Picture")
        #expect(try item(try KnowledgeCapture.createNote(in: folder, title: "", text: "", pictures: [picture, picture], now: now)).title == "Pictures")
    }

    // MARK: - Reading list outbox

    @Test func outboxEntriesReachTheReadingListInOrder() async throws {
        let database = try makeTestDatabase()
        let store = ReadingListStore(database: database)
        let outbox = ReadingListOutbox(dataDirectory: directory)
        try outbox.add(url: "https://example.com/a?utm_source=x", title: "  First  ", sourceAppName: "Safari", now: now)
        try outbox.add(url: "example.com/b", now: now.addingTimeInterval(1))
        #expect(throws: ReadingListError.notALink("hello")) { try outbox.add(url: "hello") }
        #expect(!outbox.isEmpty)

        #expect(try outbox.apply(to: store) == 2)
        #expect(outbox.isEmpty)
        let items = try await store.all()
        #expect(items.map(\.url) == ["https://example.com/b", "https://example.com/a"])
        #expect(items[1].title == "First")
        #expect(items[1].sourceAppName == "Safari")
        #expect(items[1].addedAt == now)
        #expect(try outbox.apply(to: store) == 0)
    }

    @Test func aBrokenOutboxEntryDoesNotHoldUpTheRest() async throws {
        let store = ReadingListStore(database: try makeTestDatabase())
        let outbox = ReadingListOutbox(dataDirectory: directory)
        try FileManager.default.createDirectory(at: outbox.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: outbox.directory.appending(path: "0-broken.json"))
        try outbox.add(url: "https://example.com/c", now: now)
        #expect(try outbox.apply(to: store) == 1)
        #expect(outbox.isEmpty)
        #expect(try await store.all().map(\.url) == ["https://example.com/c"])
    }

    // MARK: - Widgets

    @Test func snapshotOfTodosAndLinks() throws {
        try folder.createProject(id: "server-config", name: "Server config", summary: nil, color: .blue)
        let rotate = try folder.createTodo(
            title: "Rotate the S3 key", body: "- [x] create key\n- [ ] update env\n", project: "server-config", due: "2026-10-20",
            now: now)
        let call = try folder.createTodo(title: "Call Anna", now: now)
        let projects = [KnowledgeProject(id: "inbox"), KnowledgeProject(id: "server-config", readme: try folder.item(at: "server-config/README.md"))]
        let links = [
            ReadingItem(url: "https://news.example.co.uk/story", title: "A story"),
            ReadingItem(url: "https://example.com/read", readAt: now),
            ReadingItem(url: "https://code.claude.com/docs/en/context-window"),
        ]

        let snapshot = WidgetSnapshot(openTodos: [try item(rotate), try item(call)], projects: projects, readingList: links)
        #expect(snapshot.openTodoCount == 2)
        #expect(snapshot.todos.map(\.title) == ["Rotate the S3 key", "Call Anna"])
        let first = snapshot.todos[0]
        #expect(first.projectName == "Server config")
        #expect(first.projectColor == .blue)
        #expect(first.due == "2026-10-20")
        #expect(first.isOverdue(now: now))
        #expect((first.checklistDone, first.checklistCount) == (1, 2))
        #expect(!snapshot.todos[1].isOverdue(now: now))
        #expect(snapshot.unreadCount == 2)
        #expect(snapshot.links.map(\.title) == ["A story", "Context Window (claude.com)"])
        #expect(snapshot.links.map(\.site) == ["example.co.uk", "claude.com"])

        let url = WidgetSnapshot.url(inDataDirectory: directory)
        #expect(WidgetSnapshot.read(from: url) == WidgetSnapshot())
        try snapshot.write(to: url)
        #expect(WidgetSnapshot.read(from: url) == snapshot)

        let ticked = snapshot.completing(rotate)
        #expect(ticked.todos.map(\.path) == [call])
        #expect(ticked.openTodoCount == 1)
        #expect(ticked.completing("inbox/todos/gone.md") == ticked)
    }

    @Test func snapshotKeepsTheFirstTodos() throws {
        let todos = try (0..<12).map { try item(try folder.createTodo(title: "To-do \($0)", now: now)) }
        let snapshot = WidgetSnapshot(openTodos: todos, projects: [], readingList: [])
        #expect(snapshot.todos.count == WidgetSnapshot.todoLimit)
        #expect(snapshot.todos.first?.title == "To-do 0")
        #expect(snapshot.openTodoCount == 12)
        #expect(snapshot.todos.first?.projectName == "Inbox")
    }

    // MARK: - Spotlight

    @Test func spotlightAttributesOfATodo() throws {
        let path = try folder.createTodo(
            title: "Rotate the S3 key", body: "Use **restic**.\n\n- [ ] create key\n", project: "server-config",
            tags: ["backup"], due: "2026-10-30", now: now)
        let attributes = KnowledgeSpotlight.attributes(for: try item(path), projectName: "Server config")
        #expect(attributes.title == "Rotate the S3 key")
        #expect(attributes.contentDescription == "Server config · Due 2026-10-30\nUse restic.\n\n☐ create key")
        #expect(attributes.textContent == "Use restic.\n\n☐ create key")
        #expect(attributes.keywords == ["backup", "Server config"])

        try folder.setStatus(.done, of: path, now: now)
        #expect(KnowledgeSpotlight.attributes(for: try item(path), projectName: "Server config").contentDescription?
            .hasPrefix("Server config · Done\n") == true)

        let searchable = KnowledgeSpotlight.searchableItem(for: try item(path), projectName: "Server config")
        #expect(searchable.uniqueIdentifier == path)
        #expect(searchable.domainIdentifier == "server-config")
    }

    @Test func spotlightChangesFromTheDates() {
        let old = Date(timeIntervalSince1970: 1), new = Date(timeIntervalSince1970: 2)
        let changes = KnowledgeSpotlight.changes(
            indexed: ["a.md": old, "b.md": old, "gone.md": old],
            current: ["a.md": old, "b.md": new, "c.md": new])
        #expect(changes.update == ["b.md", "c.md"])
        #expect(changes.remove == ["gone.md"])
    }
}
