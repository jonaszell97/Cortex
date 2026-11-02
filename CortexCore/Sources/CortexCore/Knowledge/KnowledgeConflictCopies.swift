import Foundation

/// The versions sync kept in `.conflicts/` (the loser of a conflict, a file
/// another device deleted): `<folders>/<name>-<yyyyMMdd-HHmmss>-<hash>.<ext>`,
/// see `KnowledgeFileSync.archive`. Listed so they can be read, put back or
/// thrown away.
public struct KnowledgeConflictCopies: Sendable {
    public struct Copy: Sendable, Equatable, Identifiable {
        /// Inside `.conflicts/`.
        public var path: String
        /// Where it came from in the knowledge folder.
        public var originalPath: String
        /// When it was kept (UTC, from the name).
        public var kept: Date

        public var id: String { path }
    }

    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    var directory: URL {
        root.appending(path: KnowledgeFileSync.conflictsDirectoryName, directoryHint: .isDirectory)
    }

    public func url(for copy: Copy) -> URL {
        directory.appending(path: copy.path, directoryHint: .notDirectory)
    }

    /// Every kept version, the most recent first.
    public func list(fileManager: FileManager = .default) -> [Copy] {
        guard let enumerator = fileManager.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
        else { return [] }
        var prefix = directory.standardizedFileURL.path(percentEncoded: false)
        if !prefix.hasSuffix("/") { prefix += "/" }
        let copies = enumerator.compactMap { element -> Copy? in
            guard let url = element as? URL,
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { return nil }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard path.hasPrefix(prefix) else { return nil }
            return Self.copy(at: String(path.dropFirst(prefix.count)))
        }
        return copies.sorted { $0.kept != $1.kept ? $0.kept > $1.kept : $0.path < $1.path }
    }

    /// Reads the original path and the date from a kept file's name; nil for
    /// a name sync did not make.
    static func copy(at path: String) -> Copy? {
        var components = path.split(separator: "/").map(String.init)
        guard let name = components.popLast(),
              let match = name.wholeMatch(of: /(.+)-(\d{8}-\d{6})-[0-9a-f]{8}(\.[^.\/]+)?/),
              let kept = Self.formatter.date(from: String(match.output.2))
        else { return nil }
        let original = String(match.output.1) + String(match.output.3 ?? "")
        return Copy(path: path, originalPath: (components + [original]).joined(separator: "/"), kept: kept)
    }

    private static var formatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }

    /// Puts a kept version back where it came from. The file there now, if
    /// any and different, is kept in `.conflicts/` in turn, so restoring
    /// loses nothing. The copy is removed.
    public func restore(_ copy: Copy, now: Date = .now) throws {
        let data = try Data(contentsOf: url(for: copy))
        let folder = KnowledgeFolder(root: root)
        let target = folder.url(for: copy.originalPath)
        if let current = try? Data(contentsOf: target), current != data {
            guard KnowledgeFileSync(root: root).archive(current, at: copy.originalPath, now: now) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [
                    NSLocalizedDescriptionKey: "The current version of \(copy.originalPath) could not be kept, so it was not replaced.",
                ])
            }
        }
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        try delete(copy)
    }

    /// Throws the copy away, and the folders that leaves empty.
    public func delete(_ copy: Copy) throws {
        try FileManager.default.removeItem(at: url(for: copy))
        var folder = url(for: copy).deletingLastPathComponent().standardizedFileURL
        let top = directory.standardizedFileURL.path(percentEncoded: false)
        while folder.path(percentEncoded: false).count > top.count,
              (try? FileManager.default.contentsOfDirectory(atPath: folder.path(percentEncoded: false)))?.isEmpty == true {
            try? FileManager.default.removeItem(at: folder)
            folder = folder.deletingLastPathComponent()
        }
    }
}
