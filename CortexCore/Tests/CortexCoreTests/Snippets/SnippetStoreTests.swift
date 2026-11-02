import Foundation
import Testing
@testable import CortexCore

@Suite struct SnippetStoreTests {
    let database: AppDatabase
    let store: SnippetStore

    init() throws {
        database = try makeTestDatabase()
        store = SnippetStore(database: database)
    }

    @Test func migrationCreatesTheTable() throws {
        #expect(try database.appliedMigrations().contains("v3_snippets"))
    }

    @Test func savesAndNormalizes() async throws {
        // Whole seconds: the database stores dates with millisecond precision.
        let saved = try store.save(
            Snippet(name: "  Sig  ", keyword: "  ", body: "Bye", tags: [" mail ", "", "Mail", "work"]),
            now: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(saved.id != nil)
        #expect(saved.name == "Sig")
        #expect(saved.keyword == nil)
        #expect(saved.tags == ["mail", "work"])

        let loaded = try #require(try await store.snippet(id: saved.id!))
        #expect(loaded == saved)
    }

    @Test func updatesInPlace() async throws {
        var snippet = try store.save(Snippet(name: "A", keyword: ";a", body: "one"))
        snippet.body = "two"
        snippet.name = "a"
        try store.save(snippet)
        let all = try await store.all()
        #expect(all.map(\.body) == ["two"])
        #expect(all.map(\.name) == ["a"], "renaming to a different case of the own name is fine")
    }

    @Test func rejectsDuplicateNamesIgnoringCase() throws {
        try store.save(Snippet(name: "Signature", body: "x"))
        #expect(throws: SnippetStoreError.duplicateName("Signature")) {
            try store.save(Snippet(name: "signature", body: "y"))
        }
    }

    @Test func rejectsDuplicateAndSpacedKeywords() throws {
        try store.save(Snippet(name: "A", keyword: ";a", body: "x"))
        #expect(throws: SnippetStoreError.duplicateKeyword(";a", usedBy: "A")) {
            try store.save(Snippet(name: "B", keyword: ";a", body: "y"))
        }
        #expect(throws: SnippetStoreError.keywordContainsWhitespace("a b")) {
            try store.save(Snippet(name: "C", keyword: "a b", body: "y"))
        }
        #expect(throws: SnippetStoreError.emptyName) {
            try store.save(Snippet(name: " ", body: "y"))
        }
        // Several snippets without a keyword are fine.
        try store.save(Snippet(name: "D", body: "y"))
        try store.save(Snippet(name: "E", body: "y"))
    }

    @Test func keywordsMapToIDs() async throws {
        let a = try store.save(Snippet(name: "A", keyword: ";a", body: "x"))
        try store.save(Snippet(name: "B", body: "y"))
        #expect(try await store.keywords() == [";a": a.id!])
    }

    @Test func markUsedCounts() async throws {
        let a = try store.save(Snippet(name: "A", body: "x"))
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try store.markUsed(id: a.id!, at: date)
        try store.markUsed(id: a.id!, at: date)
        let loaded = try #require(try await store.snippet(id: a.id!))
        #expect(loaded.usageCount == 2)
        #expect(loaded.lastUsedAt == date)
    }

    @Test func deletes() async throws {
        let a = try store.save(Snippet(name: "A", body: "x"))
        try store.delete(id: a.id!)
        #expect(try await store.count() == 0)
    }
}

@Suite struct SnippetSearchTests {
    let snippets = [
        Snippet(id: 1, name: "Signature", keyword: ";sig", body: "Best regards", usageCount: 1),
        Snippet(id: 2, name: "Meeting notes", keyword: ";mtg", body: "Agenda", tags: ["work"], usageCount: 5),
        Snippet(id: 3, name: "Home address", body: "Musterstraße 1", usageCount: 0),
        Snippet(id: 4, name: "Café order", body: "Flat white", usageCount: 2),
    ]

    func names(_ query: String) -> [String] {
        SnippetSearch.rank(snippets, query: query).map(\.name)
    }

    @Test func emptyQueryShowsMostUsedFirst() {
        #expect(names("") == ["Meeting notes", "Café order", "Signature", "Home address"])
    }

    @Test func keywordBeatsName() {
        #expect(names("sig").first == "Signature")
        #expect(names(";mtg") == ["Meeting notes"])
        #expect(names("mt").first == "Meeting notes")
    }

    @Test func matchesWordsTagsBodyAndFuzzy() {
        #expect(names("notes") == ["Meeting notes"])
        #expect(names("work") == ["Meeting notes"])
        #expect(names("musterstrasse") == ["Home address"], "ß folds to ss")
        #expect(names("muster") == ["Home address"])
        #expect(names("cafe") == ["Café order"], "diacritics are ignored")
        #expect(names("hmadr") == ["Home address"], "letters in order match fuzzily")
        #expect(names("home regards").isEmpty, "every word must match")
    }
}
