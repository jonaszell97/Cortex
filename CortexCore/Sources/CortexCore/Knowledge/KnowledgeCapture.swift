import Foundation

/// Notes made outside the app on the iPhone (plans/IOS.md, M5): from the
/// share sheet, Shortcuts and Siri. They are written into the folder like
/// any note; the app indexes and syncs them the next time it runs.
public enum KnowledgeCapture {
    /// A picture to go with a note: its bytes and file extension (`jpeg`,
    /// `png`, `heic`).
    public struct Picture: Sendable, Equatable {
        public var data: Data
        public var fileExtension: String

        public init(data: Data, fileExtension: String) {
            self.data = data
            self.fileExtension = fileExtension
        }
    }

    public static let maxTitleLength = 80

    /// The title for shared text: its first non-empty line, without a
    /// heading's `#`, cut at a word to `maxTitleLength` characters.
    public static func title(forText text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline)
            .lazy.map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        let title = line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
        guard title.count > maxTitleLength else { return title }
        let cut = title.prefix(maxTitleLength)
        if let space = cut.lastIndex(of: " "), cut.distance(from: cut.startIndex, to: space) > maxTitleLength / 2 {
            return cut[..<space].trimmingCharacters(in: .whitespaces) + "…"
        }
        return cut + "…"
    }

    /// Writes a note with `text` as its body and the pictures below it, each
    /// saved in the project's `assets/` and linked relatively. An empty
    /// title is made from the text (a single line is only the title), or
    /// "Picture" for pictures alone. Returns the note's path.
    @discardableResult
    public static func createNote(
        in folder: KnowledgeFolder, title: String, text: String, pictures: [Picture] = [],
        project: String = KnowledgeProject.inboxID, now: Date = .now
    ) throws -> String {
        var title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty {
            title = Self.title(forText: body)
            // One line that became the title whole: the body would repeat it.
            if title == body { body = "" }
        }
        if title.isEmpty { title = pictures.count > 1 ? "Pictures" : "Picture" }

        let stem = KnowledgeFolder.fileName(project: project, title: title, date: now)
        let alt = title.filter { $0 != "[" && $0 != "]" }
        for picture in pictures {
            let ext = picture.fileExtension.lowercased().filter { $0.isLetter || $0.isNumber }
            let asset = folder.unusedPath("\(project)/assets/\(stem).\(ext.isEmpty ? "jpeg" : ext)")
            let url = folder.url(for: asset)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try picture.data.write(to: url, options: .atomic)
            // Notes are in `<project>/notes/`, next to `assets/`.
            let name = String(asset.dropFirst("\(project)/assets/".count))
            let link = "![\(alt)](../assets/\(name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? name))"
            body += body.isEmpty ? link : "\n\n\(link)"
        }
        return try folder.createNote(title: title, body: body, project: project, now: now)
    }
}
