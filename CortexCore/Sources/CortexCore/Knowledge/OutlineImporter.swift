#if os(macOS)
import Foundation

/// An Outline export (Settings → Export → All collections, Markdown): one
/// folder per collection, one `.md` file per document, a nested document in
/// a folder named after its parent, attachments next to the documents that
/// use them (linked relatively, as `uploads/…/image.png`).
public struct OutlineExport: Sendable {
    public struct Document: Sendable, Equatable {
        public var title: String
        /// Relative to the export's root: `Servers/Docker/Copy a volume.md`.
        public var path: String
        /// Without the title heading Outline puts first.
        public var body: String
        /// The parent documents' titles (their folder names), outermost first.
        public var parents: [String]
        public var modified: Date
    }

    public struct Collection: Sendable, Identifiable {
        public var name: String
        public var documents: [Document]
        public var id: String { name }
    }

    public let root: URL
    public var collections: [Collection]

    /// Unpacks the zip with `ditto` into a new folder inside `directory` and
    /// returns that folder.
    public static func extract(zip: URL, into directory: URL) async throws -> URL {
        let destination = directory.appending(path: "outline-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let result = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", zip.path(percentEncoded: false), destination.path(percentEncoded: false)])
        guard result.status == 0 else {
            throw QuickActionError("Cannot unpack \(zip.lastPathComponent): \(result.errorSummary())")
        }
        return destination
    }

    /// Reads an unpacked export. A folder holding just one folder of
    /// collections (as some unzip tools make it) is looked into.
    public static func read(directory: URL) throws -> OutlineExport {
        var root = directory
        let fileManager = FileManager.default
        while true {
            let (folders, documents) = try contents(of: root)
            guard folders.count == 1, documents.isEmpty, try contents(of: folders[0]).documents.isEmpty else { break }
            root = folders[0]
        }
        let (folders, documents) = try contents(of: root)
        var collections = try folders.map { folder in
            Collection(name: folder.lastPathComponent, documents: try readDocuments(in: folder, root: root, fileManager: fileManager))
        }
        // Documents at the top level: one collection named after the folder.
        if !documents.isEmpty {
            let topLevel = try readDocuments(in: root, root: root, fileManager: fileManager, recursive: false)
            collections.insert(Collection(name: root.lastPathComponent, documents: topLevel), at: 0)
        }
        return OutlineExport(root: root, collections: collections.filter { !$0.documents.isEmpty })
    }

    private static func contents(of folder: URL) throws -> (folders: [URL], documents: [URL]) {
        let urls = try FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { $0.lastPathComponent != "__MACOSX" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let folders = urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
        let documents = urls.filter { $0.pathExtension.lowercased() == "md" }
        return (folders, documents)
    }

    private static func readDocuments(in folder: URL, root: URL, fileManager: FileManager, recursive: Bool = true) throws -> [Document] {
        let rootPath = root.standardizedFileURL.path(percentEncoded: false)
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        let folderPath = folder.standardizedFileURL.path(percentEncoded: false)
        let folderPrefix = folderPath.hasSuffix("/") ? folderPath : folderPath + "/"
        var urls: [URL] = []
        if recursive {
            let enumerator = fileManager.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            while let url = enumerator?.nextObject() as? URL {
                if url.pathExtension.lowercased() == "md" { urls.append(url) }
            }
        } else {
            urls = try contents(of: folder).documents
        }
        return try urls
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            .map { url in
                let path = url.standardizedFileURL.path(percentEncoded: false)
                let relative = String(path.dropFirst(prefix.count))
                let inCollection = String(path.dropFirst(folderPrefix.count))
                let parents = inCollection.split(separator: "/").dropLast().map(String.init)
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .now
                let (title, body) = titleAndBody(
                    try String(contentsOf: url, encoding: .utf8), fileName: url.deletingPathExtension().lastPathComponent)
                return Document(title: title, path: relative, body: body, parents: parents, modified: modified)
            }
    }

    /// The title from the front matter or the first line's heading (which
    /// is then dropped), else the file name.
    static func titleAndBody(_ text: String, fileName: String) -> (String, String) {
        let (frontMatter, body) = FrontMatter.split(text)
        var lines = body.split(separator: "\n", omittingEmptySubsequences: false)[...]
        while lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
        var title = frontMatter?.string("title")
        if let first = lines.first, first.hasPrefix("# ") {
            let heading = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
            if title == nil || title == heading {
                title = heading
                lines.removeFirst()
                while lines.first?.allSatisfy(\.isWhitespace) == true { lines.removeFirst() }
            }
        }
        let resolved = title.flatMap { $0.isEmpty ? nil : $0 } ?? fileName
        return (resolved, lines.joined(separator: "\n"))
    }
}

/// Where a collection goes. Made by hand in the import sheet.
public enum OutlineImportTarget: Hashable, Sendable {
    case project(String)
    /// A new project named after the collection.
    case newProject
    case inbox
    case skip
}

public struct OutlineImportReport: Sendable, Equatable {
    public var imported = 0
    /// Notes that existed at the same path already, left as they were.
    public var skipped: [String] = []
    public var attachments = 0
    /// Links that looked like attachments but had no file in the export.
    public var missingAttachments: [String] = []
    public var createdProjects: [String] = []

    public init() {}
}

/// Turns an Outline export into notes (docs/modules/KNOWLEDGE.md, "The
/// importers"): each document a note in the project its collection is mapped to,
/// a nested document tagged with its parent's name, attachments copied to the
/// project's `assets/` with the links rewritten, links between documents pointed
/// at the new notes. Existing notes are never overwritten.
public struct OutlineImporter: Sendable {
    public let folder: KnowledgeFolder

    public init(folder: KnowledgeFolder) {
        self.folder = folder
    }

    public func run(_ export: OutlineExport, mapping: [String: OutlineImportTarget], now: Date = .now) throws -> OutlineImportReport {
        var report = OutlineImportReport()

        // Where every document goes, before anything is written, so links
        // between documents can point at their new paths.
        var planned: [(document: OutlineExport.Document, project: String, path: String)] = []
        var taken: Set<String> = []
        for collection in export.collections {
            let project: String
            switch mapping[collection.name] ?? .skip {
            case .skip: continue
            case .inbox: project = KnowledgeProject.inboxID
            case .project(let id): project = id
            case .newProject:
                project = folder.newProjectID(for: collection.name)
                try folder.createProject(id: project, name: collection.name)
                report.createdProjects.append(project)
            }
            for document in collection.documents {
                var path = KnowledgeFolder.notePath(project: project, title: document.title, date: document.modified)
                if folder.exists(path) {
                    report.skipped.append(path)
                    continue
                }
                if taken.contains(path) {
                    let stem = String(path.dropLast(3))
                    var number = 2
                    while taken.contains("\(stem)-\(number).md") || folder.exists("\(stem)-\(number).md") { number += 1 }
                    path = "\(stem)-\(number).md"
                }
                taken.insert(path)
                planned.append((document, project, path))
            }
        }

        let notePaths = Dictionary(planned.map { ($0.document.path, $0.path) }, uniquingKeysWith: { first, _ in first })
        var copiedAssets: [String: String] = [:]
        for (document, project, path) in planned {
            let body = rewriteLinks(
                in: document.body, of: document, root: export.root, notePath: path, project: project,
                notePaths: notePaths, copied: &copiedAssets, report: &report)
            var meta = FrontMatter()
            meta.set("title", text: document.title)
            if let parent = document.parents.last {
                let tag = KnowledgeTag.normalize(parent)
                if !tag.isEmpty { meta.set("tags", .list([tag])) }
            }
            meta.set("created", date: document.modified)
            meta.set("updated", date: document.modified)
            try folder.write(FrontMatter.compose(meta, body: KnowledgeFolder.bodyText(body)), to: path)
            report.imported += 1
        }
        return report
    }

    // MARK: - Links

    private func rewriteLinks(
        in body: String, of document: OutlineExport.Document, root: URL, notePath: String, project: String,
        notePaths: [String: String], copied: inout [String: String], report: inout OutlineImportReport
    ) -> String {
        let documentFolder = (document.path as NSString).deletingLastPathComponent
        var result = ""
        var rest = body[...]
        // Markdown links and images `](target)`, and HTML `src="target"`.
        let pattern = /(\]\(<?|src=")([^)>"\s]+)/
        while let match = rest.firstMatch(of: pattern) {
            result += rest[..<match.range.lowerBound]
            result += match.output.1
            let target = String(match.output.2)
            result += rewrite(
                target, documentFolder: documentFolder, root: root, notePath: notePath, project: project,
                notePaths: notePaths, copied: &copied, report: &report) ?? target
            rest = rest[match.range.upperBound...]
        }
        return result + rest
    }

    private func rewrite(
        _ target: String, documentFolder: String, root: URL, notePath: String, project: String,
        notePaths: [String: String], copied: inout [String: String], report: inout OutlineImportReport
    ) -> String? {
        guard !target.contains("://"), !target.hasPrefix("mailto:"), !target.hasPrefix("#"), !target.hasPrefix("/") else { return nil }
        var linkPath = target
        var fragment = ""
        if let hash = linkPath.firstIndex(of: "#") {
            fragment = String(linkPath[hash...])
            linkPath = String(linkPath[..<hash])
        }
        let decoded = linkPath.removingPercentEncoding ?? linkPath
        let relative = Self.normalize(documentFolder.isEmpty ? decoded : "\(documentFolder)/\(decoded)")
        guard let relative else { return nil }

        // Another document of the export.
        if relative.lowercased().hasSuffix(".md") {
            guard let other = notePaths[relative] else { return nil }
            return Self.relativeLink(from: notePath, to: other) + fragment
        }

        let source = root.appending(path: relative, directoryHint: .notDirectory)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path(percentEncoded: false), isDirectory: &isDirectory), !isDirectory.boolValue
        else {
            if relative.contains("uploads/") || !(relative as NSString).pathExtension.isEmpty {
                report.missingAttachments.append(relative)
            }
            return nil
        }
        let key = "\(project)\n\(relative)"
        if let asset = copied[key] {
            return Self.relativeLink(from: notePath, to: asset)
        }
        do {
            let asset = folder.unusedPath("\(project)/assets/\(source.lastPathComponent)")
            let destination = folder.url(for: asset)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source, to: destination)
            copied[key] = asset
            report.attachments += 1
            return Self.relativeLink(from: notePath, to: asset)
        } catch {
            report.missingAttachments.append(relative)
            return nil
        }
    }

    /// `a/./b/../c` is `a/c`; nil when it leaves the export.
    static func normalize(_ path: String) -> String? {
        var parts: [Substring] = []
        for part in path.split(separator: "/") {
            switch part {
            case ".": continue
            case "..":
                guard !parts.isEmpty else { return nil }
                parts.removeLast()
            default: parts.append(part)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// A link from one file in the knowledge folder to another, percent-encoded.
    static func relativeLink(from source: String, to target: String) -> String {
        let from = source.split(separator: "/").dropLast()
        let to = target.split(separator: "/")
        var common = 0
        while common < from.count, common < to.count - 1, from[from.startIndex + common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        let path = (ups + to[common...].map(String.init)).joined(separator: "/")
        return path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }
}
#endif
