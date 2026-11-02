import Foundation

/// Keeps one symlink per skill in Claude Code's skills folder
/// (`~/.claude/skills/<name>` → `<knowledge>/<project>/skills/<name>`), so
/// Claude Code loads the knowledge base's skills as its own in every
/// session, with or without the MCP server (docs/modules/KNOWLEDGE.md, "The MCP
/// server").
///
/// Only symlinks that point into the knowledge folder are ever made or
/// removed; everything else in the skills folder is left alone, and a skill
/// whose name is taken there by something else is not linked.
public struct KnowledgeSkillLinks: Sendable {
    /// The knowledge folder.
    public let knowledge: URL
    /// Claude Code's skills folder.
    public let skills: URL

    public init(knowledge: URL, skills: URL) {
        self.knowledge = knowledge
        self.skills = skills
    }

    /// `$CLAUDE_CONFIG_DIR/skills`, else `~/.claude/skills`.
    public static func defaultDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment, home: URL = URL(filePath: NSHomeDirectory())
    ) -> URL {
        if let config = environment["CLAUDE_CONFIG_DIR"], !config.isEmpty {
            return URL(filePath: (config as NSString).expandingTildeInPath, directoryHint: .isDirectory)
                .appending(path: "skills", directoryHint: .isDirectory)
        }
        return home.appending(path: ".claude/skills", directoryHint: .isDirectory)
    }

    public struct Report: Sendable, Equatable {
        /// Names linked now, sorted.
        public var linked: [String] = []
        /// Links made or changed by this update.
        public var added: [String] = []
        /// Links removed by this update.
        public var removed: [String] = []
        /// Skill paths not linked: their name is taken in the skills folder
        /// by something else, or by a skill of another project.
        public var conflicts: [String] = []

        public init(linked: [String] = [], added: [String] = [], removed: [String] = [], conflicts: [String] = []) {
            self.linked = linked
            self.added = added
            self.removed = removed
            self.conflicts = conflicts
        }
    }

    /// Makes the links match `paths` (`<project>/skills/<name>/SKILL.md`).
    /// Two skills of the same name: the first path in sorted order wins.
    @discardableResult
    public func update(skillPaths paths: [String]) throws -> Report {
        var wanted: [String: URL] = [:]
        var report = Report()
        for path in paths.sorted() {
            guard KnowledgePath.classify(path)?.kind == .skill else { continue }
            let folder = knowledge.appending(path: path).deletingLastPathComponent().standardizedFileURL
            let name = folder.lastPathComponent
            if wanted[name] == nil { wanted[name] = folder } else { report.conflicts.append(path) }
        }

        let fileManager = FileManager.default
        let existing = (try? fileManager.contentsOfDirectory(atPath: skills.path(percentEncoded: false))) ?? []
        var present: Set<String> = []
        for name in existing {
            let link = skills.appending(path: name).path(percentEncoded: false)
            guard let target = try? fileManager.destinationOfSymbolicLink(atPath: link) else {
                present.insert(name)
                continue
            }
            guard isInKnowledge(target, relativeTo: skills) else {
                present.insert(name)
                continue
            }
            if let folder = wanted[name], Self.same(target, folder.path(percentEncoded: false)) {
                present.insert(name)
                report.linked.append(name)
                wanted[name] = nil
                continue
            }
            try fileManager.removeItem(atPath: link)
            report.removed.append(name)
        }

        for (name, folder) in wanted {
            guard !present.contains(name) else {
                report.conflicts.append(Self.relative(folder, to: knowledge).trimmingSuffix("/") + "/SKILL.md")
                continue
            }
            try fileManager.createDirectory(at: skills, withIntermediateDirectories: true)
            try fileManager.createSymbolicLink(
                atPath: skills.appending(path: name).path(percentEncoded: false),
                withDestinationPath: folder.path(percentEncoded: false).trimmingSuffix("/"))
            report.removed.removeAll { $0 == name }
            report.added.append(name)
            report.linked.append(name)
        }
        report.linked.sort()
        report.added.sort()
        report.removed.sort()
        report.conflicts.sort()
        return report
    }

    /// Removes every link into the knowledge folder; returns their names.
    @discardableResult
    public func removeAll() throws -> [String] {
        try update(skillPaths: []).removed
    }

    private func isInKnowledge(_ target: String, relativeTo directory: URL) -> Bool {
        let absolute = target.hasPrefix("/") ? target : directory.appending(path: target).path(percentEncoded: false)
        let target = URL(filePath: absolute).standardizedFileURL.path(percentEncoded: false)
        let roots = [knowledge.standardizedFileURL, knowledge.resolvingSymlinksInPath()]
            .map { $0.path(percentEncoded: false) }
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        return roots.contains { target.hasPrefix($0) }
    }

    private static func same(_ lhs: String, _ rhs: String) -> Bool {
        URL(filePath: lhs).standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
            == URL(filePath: rhs).standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/")
    }

    private static func relative(_ url: URL, to root: URL) -> String {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let prefix = root.standardizedFileURL.path(percentEncoded: false).trimmingSuffix("/") + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}

private extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        hasSuffix(suffix) ? String(dropLast(suffix.count)) : self
    }
}
