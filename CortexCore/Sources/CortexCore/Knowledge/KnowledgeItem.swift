import Foundation

public enum KnowledgeKind: String, Sendable, CaseIterable, Codable {
    case note, skill, todo, project
}

public enum TodoStatus: String, Sendable, Codable {
    case open, done
}

/// One file of the knowledge base: a note, a skill, a to-do or a project's
/// README. The path relative to the knowledge folder is its identity.
public struct KnowledgeItem: Sendable, Equatable, Identifiable {
    /// `server-config/notes/docker-on-a-new-server.md`
    public var path: String
    /// The project folder's name.
    public var project: String
    public var kind: KnowledgeKind
    public var title: String
    public var tags: [String]
    /// A skill's description, a project's summary.
    public var summary: String?
    /// To-dos only.
    public var status: TodoStatus?
    /// A to-do's due day as written (`2026-10-30`).
    public var due: String?
    public var created: Date?
    /// From the front matter, else the file's modification date.
    public var updated: Date
    /// The text after the front matter.
    public var body: String
    public var frontMatter: FrontMatter

    public var id: String { path }

    public init(
        path: String, project: String, kind: KnowledgeKind, title: String, tags: [String] = [], summary: String? = nil,
        status: TodoStatus? = nil, due: String? = nil, created: Date? = nil, updated: Date, body: String,
        frontMatter: FrontMatter = FrontMatter()
    ) {
        self.path = path
        self.project = project
        self.kind = kind
        self.title = title
        self.tags = tags
        self.summary = summary
        self.status = status
        self.due = due
        self.created = created
        self.updated = updated
        self.body = body
        self.frontMatter = frontMatter
    }

    /// The item a file is, or nil for a path that holds none (an asset, a
    /// skill's supporting file, anything under a dot folder).
    public static func parse(path: String, text: String, modified: Date) -> KnowledgeItem? {
        guard let (project, kind) = KnowledgePath.classify(path) else { return nil }
        let (frontMatter, body) = FrontMatter.split(text)
        let meta = frontMatter ?? FrontMatter()
        let title = switch kind {
        case .skill: meta.string("name") ?? meta.string("title")
        case .project: meta.string("name") ?? meta.string("title")
        default: meta.string("title")
        }
        let summary = switch kind {
        case .skill: meta.string("description")
        case .project: meta.string("summary")
        default: meta.string("summary")
        }
        return KnowledgeItem(
            path: path, project: project, kind: kind,
            title: title.flatMap { $0.isEmpty ? nil : $0 } ?? Self.fallbackTitle(path: path, kind: kind, body: body),
            tags: meta.list("tags").map(KnowledgeTag.normalize).filter { !$0.isEmpty },
            summary: summary,
            status: kind == .todo ? (meta.string("status").flatMap { TodoStatus(rawValue: $0.lowercased()) } ?? .open) : nil,
            due: kind == .todo ? meta.string("due") : nil,
            created: meta.date("created"),
            updated: meta.date("updated") ?? modified,
            body: body, frontMatter: meta)
    }

    /// The first `# ` heading, else the file name (a skill's or project's
    /// folder name, an inbox file without its date).
    static func fallbackTitle(path: String, kind: KnowledgeKind, body: String) -> String {
        if let heading = KnowledgeMarkdown.firstHeading(in: body) { return heading }
        let components = path.split(separator: "/")
        switch kind {
        case .project:
            return KnowledgeProject.defaultName(for: String(components[0]))
        case .skill:
            return String(components[components.count - 2])
        default:
            var name = String(components.last!)
            if let dot = name.lastIndex(of: ".") { name = String(name[..<dot]) }
            if let match = name.prefixMatch(of: /\d{4}-\d{2}-\d{2}-/) { name = String(name[match.range.upperBound...]) }
            return name.isEmpty ? "Untitled" : name
        }
    }

    /// What ⏎ pastes: the body without the front matter, trimmed.
    public var pasteText: String {
        body.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A project: a folder in the knowledge folder, described by the front
/// matter of its `README.md`.
/// The colours a project can be labelled with: the system colours by name,
/// so a README reads `color: teal` and every platform draws its own teal.
public enum ProjectColor: String, CaseIterable, Sendable, Codable {
    case red, orange, yellow, green, mint, teal, cyan, blue, indigo, purple, pink, brown, gray

    /// A README's value, in any case; `grey` is gray.
    public init?(name: String) {
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        self.init(rawValue: name == "grey" ? "gray" : name)
    }

    /// The colours picked for a project without one: hues far enough apart
    /// to tell at a glance (not teal, cyan and mint side by side), so gray
    /// stays the inbox's and the others are only chosen.
    static let automatic: [ProjectColor] = [.blue, .orange, .green, .purple, .pink, .teal, .red, .yellow]

    /// For a new project: the first of `automatic` the fewest of `projects`
    /// are drawn in, written to its README so it keeps it.
    public static func leastUsed(by projects: [KnowledgeProject]) -> ProjectColor {
        let counts = Dictionary(projects.filter { !$0.isInbox }.map { ($0.tint, 1) }, uniquingKeysWith: +)
        return automatic.min { counts[$0, default: 0] < counts[$1, default: 0] }!
    }

    /// Gray for the inbox, else one of `automatic` by a hash of the ID (FNV-1a,
    /// not `Hasher`, which differs between launches).
    public static func automatic(for id: String) -> ProjectColor {
        guard id != KnowledgeProject.inboxID else { return .gray }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return automatic[Int(hash % UInt64(automatic.count))]
    }
}

public struct KnowledgeProject: Sendable, Equatable, Identifiable {
    /// The built-in project captures land in.
    public static let inboxID = "inbox"

    /// The folder name.
    public var id: String
    public var name: String
    public var summary: String?
    /// An SF Symbol.
    public var symbol: String?
    /// The README's `color`; nil (or a name Cortex does not know) picks one
    /// from the ID, see `tint`.
    public var color: ProjectColor?
    /// Working directories this project belongs to (`~` expanded by the reader).
    public var folders: [String]
    /// The README's text after the front matter.
    public var about: String

    public init(
        id: String, name: String? = nil, summary: String? = nil, symbol: String? = nil, color: ProjectColor? = nil,
        folders: [String] = [], about: String = ""
    ) {
        self.id = id
        self.name = name ?? Self.defaultName(for: id)
        self.summary = summary
        self.symbol = symbol
        self.color = color
        self.folders = folders
        self.about = about
    }

    public init(id: String, readme: KnowledgeItem?) {
        let meta = readme?.frontMatter ?? FrontMatter()
        self.init(
            id: id, name: meta.string("name") ?? meta.string("title"), summary: meta.string("summary"),
            symbol: meta.string("symbol"), color: meta.string("color").flatMap(ProjectColor.init(name:)),
            folders: meta.list("folders"), about: readme?.body ?? "")
    }

    public var isInbox: Bool { id == Self.inboxID }

    /// The SF Symbol the project is shown with: its own, else a tray for the
    /// inbox and a folder for the rest.
    public var displaySymbol: String {
        symbol.flatMap { $0.isEmpty ? nil : $0 } ?? (isInbox ? "tray" : "folder")
    }

    /// The colour its labels are drawn in: its own, else gray for the inbox
    /// and one picked from the ID for the rest, the same on every device.
    public var tint: ProjectColor {
        color ?? ProjectColor.automatic(for: id)
    }

    /// The project one of whose `folders` holds `directory` (the deepest
    /// such folder wins), or nil. `~` in a folder is the home folder.
    public static func linked(to directory: String, in projects: [KnowledgeProject], home: String = NSHomeDirectory()) -> KnowledgeProject? {
        let directory = standardized(directory, home: home)
        var best: (project: KnowledgeProject, length: Int)?
        for project in projects {
            for folder in project.folders {
                let folder = standardized(folder, home: home)
                guard !folder.isEmpty, directory == folder || directory.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
                else { continue }
                if folder.count > best?.length ?? -1 { best = (project, folder.count) }
            }
        }
        return best?.project
    }

    private static func standardized(_ path: String, home: String) -> String {
        var path = path.trimmingCharacters(in: .whitespaces)
        if path == "~" || path.hasPrefix("~/") { path = home + path.dropFirst() }
        guard path.hasPrefix("/") else { return "" }
        let standardized = URL(filePath: path).standardizedFileURL.path(percentEncoded: false)
        return standardized.count > 1 && standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    /// "server-config" is "Server config", the inbox "Inbox".
    public static func defaultName(for id: String) -> String {
        let words = id.replacing("-", with: " ").replacing("_", with: " ")
        return words.prefix(1).uppercased() + words.dropFirst()
    }
}

/// Where in the folder tree a file is, and what that makes it.
public enum KnowledgePath {
    /// The project and kind a relative path stands for, or nil.
    ///
    /// - `<project>/README.md`: the project
    /// - `<project>/todos/…/*.md`: a to-do
    /// - `<project>/skills/<name>/SKILL.md`: a skill (other files there are its own)
    /// - `<project>/assets/…`: nothing
    /// - any other `<project>/…/*.md`: a note
    public static func classify(_ path: String) -> (project: String, kind: KnowledgeKind)? {
        let components = path.split(separator: "/").map(String.init)
        guard components.count >= 2, !components.contains(where: { $0.hasPrefix(".") }),
              components.last!.lowercased().hasSuffix(".md")
        else { return nil }
        let project = components[0]
        switch components[1] {
        case "assets":
            return nil
        case "README.md" where components.count == 2:
            return (project, .project)
        case "todos":
            return components.count >= 3 ? (project, .todo) : nil
        case "skills":
            return components.count == 4 && components[3] == "SKILL.md" ? (project, .skill) : nil
        default:
            return (project, .note)
        }
    }

    /// Whether a path is skipped altogether: hidden files and folders,
    /// `.conflicts/`, `.git/`.
    public static func isHidden(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0.hasPrefix(".") }
    }
}

public enum KnowledgeTag {
    /// Lowercase, `#` dropped, spaces as hyphens: "Docker Compose" is "docker-compose".
    public static func normalize(_ tag: String) -> String {
        var tag = tag.trimmingCharacters(in: .whitespaces)
        while tag.hasPrefix("#") { tag.removeFirst() }
        return tag.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: "-")
    }
}

public enum KnowledgeSlug {
    /// A file name for a title: lowercase ASCII letters and digits with
    /// hyphens, at most `maxLength` characters, "untitled" when nothing is left.
    /// German umlauts become ae, oe, ue and ß ss; other accents are dropped.
    public static func make(_ title: String, maxLength: Int = 60) -> String {
        let replaced = title.lowercased()
            .replacing("ä", with: "ae").replacing("ö", with: "oe").replacing("ü", with: "ue").replacing("ß", with: "ss")
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        var slug = ""
        for scalar in replaced.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                slug.unicodeScalars.append(scalar)
            } else if !slug.isEmpty, !slug.hasSuffix("-") {
                slug.append("-")
            }
        }
        if slug.count > maxLength {
            slug = String(slug.prefix(maxLength))
            // Cut at a word boundary when there is one in the second half.
            if let hyphen = slug.lastIndex(of: "-"), slug.distance(from: slug.startIndex, to: hyphen) > maxLength / 2 {
                slug = String(slug[..<hyphen])
            }
        }
        while slug.hasSuffix("-") { slug.removeLast() }
        return slug.isEmpty ? "untitled" : slug
    }
}

public enum KnowledgeMarkdown {
    /// The text of the first `# ` heading.
    public static func firstHeading(in body: String) -> String? {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let heading = trimmed.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return heading.isEmpty ? nil : heading
            }
        }
        return nil
    }

    public struct CodeBlock: Sendable, Equatable {
        /// The info string after the fence: `sh`, `swift`, or empty.
        public var language: String
        public var code: String
    }

    /// The fenced code blocks (``` or ~~~), in order. An unclosed fence runs
    /// to the end, as in CommonMark.
    public static func codeBlocks(in body: String) -> [CodeBlock] {
        var blocks: [CodeBlock] = []
        var open: (fence: String, language: String, lines: [Substring])?
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            let trimmed = line.drop { $0 == " " }
            if var current = open {
                if trimmed.hasPrefix(current.fence),
                   trimmed.drop(while: { String($0) == String(current.fence.first!) }).allSatisfy(\.isWhitespace) {
                    blocks.append(CodeBlock(language: current.language, code: current.lines.joined(separator: "\n")))
                    open = nil
                } else {
                    current.lines.append(line)
                    open = current
                }
            } else if line.count - trimmed.count < 4, let fenceCharacter = trimmed.first, fenceCharacter == "`" || fenceCharacter == "~" {
                let fence = trimmed.prefix { $0 == fenceCharacter }
                guard fence.count >= 3 else { continue }
                let info = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                if fenceCharacter == "`", info.contains("`") { continue }
                open = (String(fence), String(info.split(separator: " ").first ?? ""), [])
            }
        }
        if let open { blocks.append(CodeBlock(language: open.language, code: open.lines.joined(separator: "\n"))) }
        return blocks
    }
}
