import Foundation
import Testing
@testable import CortexCore

@Suite struct OutlineImporterTests {
    let folder: KnowledgeFolder

    init() throws {
        folder = try makeKnowledgeFolder()
    }

    func fixture() throws -> URL {
        try #require(Bundle.module.url(forResource: "outline-export", withExtension: nil, subdirectory: "Fixtures"))
    }

    @Test func readsTheExport() throws {
        let export = try OutlineExport.read(directory: try fixture())
        #expect(export.collections.map(\.name) == ["Recipes", "Servers"])
        let servers = export.collections[1]
        #expect(servers.documents.map(\.title) == ["Docker on a new server", "Copy a volume"])
        #expect(servers.documents[1].parents == ["Docker on a new server"])
        #expect(servers.documents[1].path == "Servers/Docker on a new server/Copy a volume.md")
        #expect(servers.documents[0].body.hasPrefix("Install with"), "the title heading is dropped")
        #expect(export.collections[0].documents.map(\.title) == ["Pancakes", "Untitled"], "no heading: the file name")
    }

    @Test func importsIntoMappedProjects() throws {
        let export = try OutlineExport.read(directory: try fixture())
        try folder.createProject(id: "server-config", name: "Server config")
        let report = try OutlineImporter(folder: folder).run(export, mapping: ["Servers": .project("server-config"), "Recipes": .newProject])

        #expect(report.imported == 4)
        #expect(report.createdProjects == ["recipes"])
        #expect(report.attachments == 1, "one picture used twice is copied once")
        #expect(report.missingAttachments == ["Recipes/uploads/missing/photo.jpg"])
        #expect(report.skipped.isEmpty)

        let docker = try #require(try folder.item(at: "server-config/notes/docker-on-a-new-server.md"))
        #expect(docker.title == "Docker on a new server")
        #expect(docker.tags.isEmpty)
        #expect(docker.body.contains("![The dashboard](../assets/image%20one.png)"))
        #expect(docker.body.contains("[Copy a volume](copy-a-volume.md)"))
        #expect(docker.body.contains("(https://docs.getoutline.com)"), "web links stay")
        #expect(KnowledgeMarkdown.codeBlocks(in: docker.body).count == 1)

        let copy = try #require(try folder.item(at: "server-config/notes/copy-a-volume.md"))
        #expect(copy.tags == ["docker-on-a-new-server"], "the parent's name")
        #expect(copy.body.contains("![](../assets/image%20one.png)"))
        #expect(copy.body.contains("[the setup](docker-on-a-new-server.md#install)"))
        #expect(folder.exists("server-config/assets/image one.png"))

        #expect(try folder.item(at: "recipes/README.md")?.title == "Recipes")
        let pancakes = try #require(try folder.item(at: "recipes/notes/pancakes.md"))
        #expect(pancakes.body.contains("(/doc/other-abc123)"), "unresolved links stay as they were")
    }

    @Test func skipsWhatExistsAndWhatIsSkipped() throws {
        let export = try OutlineExport.read(directory: try fixture())
        let mapping: [String: OutlineImportTarget] = ["Servers": .inbox, "Recipes": .skip]
        let first = try OutlineImporter(folder: folder).run(export, mapping: mapping)
        #expect(first.imported == 2)
        let notes = try FileManager.default.contentsOfDirectory(atPath: folder.url(for: "inbox/notes").path(percentEncoded: false))
        #expect(notes.allSatisfy { $0.wholeMatch(of: /\d{4}-\d{2}-\d{2}-.+\.md/) != nil }, "inbox notes start with their date")
        #expect(!folder.exists("recipes"))

        let second = try OutlineImporter(folder: folder).run(export, mapping: mapping)
        #expect(second.imported == 0)
        #expect(second.skipped.count == 2)
    }

    @Test func extractsAZip() async throws {
        let scratch = FileManager.default.temporaryDirectory.appending(path: "outline-zip-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let zip = scratch.appending(path: "export.zip")
        // Zipped with the folder itself, as one wrapper folder.
        let result = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/ditto"),
            arguments: ["-c", "-k", "--keepParent", try fixture().path(percentEncoded: false), zip.path(percentEncoded: false)])
        #expect(result.status == 0)
        let extracted = try await OutlineExport.extract(zip: zip, into: scratch)
        let export = try OutlineExport.read(directory: extracted)
        #expect(export.collections.map(\.name) == ["Recipes", "Servers"])
    }

    @Test func links() {
        #expect(OutlineImporter.relativeLink(from: "p/notes/a.md", to: "p/notes/b c.md") == "b%20c.md")
        #expect(OutlineImporter.relativeLink(from: "p/notes/a.md", to: "p/assets/x.png") == "../assets/x.png")
        #expect(OutlineImporter.relativeLink(from: "p/notes/a.md", to: "q/notes/b.md") == "../../q/notes/b.md")
        #expect(OutlineImporter.normalize("a/./b/../c") == "a/c")
        #expect(OutlineImporter.normalize("../x") == nil)
    }
}
