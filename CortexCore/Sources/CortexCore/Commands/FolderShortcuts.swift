#if os(macOS)
import Foundation

/// A folder (or file) by a short name: what is typed after `$code` or
/// `$term`.
public struct FolderShortcut: Sendable, Equatable {
    public enum Location: Sendable, Equatable {
        /// An absolute path on this Mac.
        case local(String)
        /// An absolute path on a host VS Code reaches with Remote-SSH and
        /// `$term` with `ssh`: an alias from `~/.ssh/config`, or `user@host`.
        case ssh(host: String, path: String)
    }

    /// "cortex".
    public var name: String
    public var location: Location
    /// A single file rather than a folder (`$code ~/.zshrc`).
    public var isFile: Bool

    public init(name: String, location: Location, isFile: Bool = false) {
        self.name = name
        self.location = location
        self.isFile = isFile
    }

    /// "~/Developer/Cortex" or "devbox:/home/me/x".
    public func displayLocation(home: URL = URL.homeDirectory) -> String {
        switch location {
        case .local(let path):
            var homePath = home.path(percentEncoded: false)
            if !homePath.hasSuffix("/") { homePath += "/" }
            return path.hasPrefix(homePath) ? "~/" + path.dropFirst(homePath.count) : path
        case .ssh(let host, let path):
            return "\(host):\(path)"
        }
    }
}

/// The format `projects.toml` (`$code`) and `terminal.toml` (`$term`) share,
/// and finding a shortcut by what is typed:
///
/// ```toml
/// scan = ["~/Developer"]        # each folder in it is a shortcut (the default)
///
/// [api]                         # $code api
/// path = "~/Developer/myapp/myapp-api"
///
/// [pi]                          # over SSH, where the format allows it
/// host = "raspberrypi"
/// path = "/home/pi/home-assistant"
/// ```
///
/// The shortcuts of the file come first, in its order, then the scanned
/// folders by name. A name the file gives wins over a scanned folder's,
/// and the first scanned folder of a name over a later one.
public enum FolderShortcuts {
    /// What sets one file apart from the other.
    public struct Format: Sendable {
        /// "project": in messages.
        public var noun: String
        /// Whether a shortcut may name a host (`$code`'s Remote-SSH, `$term`'s `ssh`).
        public var allowsHosts: Bool
        /// The top-level keys other than `scan`, handed back as they are
        /// (`terminal.toml`'s `app`).
        public var settings: [String]

        public init(noun: String, allowsHosts: Bool, settings: [String] = []) {
            self.noun = noun
            self.allowsHosts = allowsHosts
            self.settings = settings
        }
    }

    /// What a file holds.
    public struct Contents: Sendable, Equatable {
        public var shortcuts: [FolderShortcut]
        public var scan: [String]
        /// The format's `settings` the file sets.
        public var settings: [String: TOML.Value]
    }

    /// What `scan` is when the file does not set it, or there is no file.
    public static let defaultScan = ["~/Developer"]

    /// The file's shortcuts (none when there is no file), then the scanned
    /// folders', and the settings it sets. A file that cannot be read
    /// throws, with its name and line.
    public static func load(
        file: URL, format: Format, home: URL = URL.homeDirectory, fileManager: FileManager = .default
    ) throws -> (shortcuts: [FolderShortcut], settings: [String: TOML.Value]) {
        let contents = try CommandSettings.read(file, fileManager: fileManager) { try parse($0, format: format, home: home) }
            ?? Contents(shortcuts: [], scan: defaultScan, settings: [:])
        let scanned = contents.scan.flatMap { folders(in: CommandSettings.expand($0, home: home), fileManager: fileManager) }
        return (merge(contents.shortcuts, scanned: scanned), contents.settings)
    }

    /// What a file lists, the folders it scans and the settings it sets.
    static func parse(_ text: String, format: Format, home: URL) throws -> Contents {
        let document = try TOML.parseTables(text)
        let nouns = format.noun + "s"
        var scan = defaultScan
        var settings: [String: TOML.Value] = [:]
        for (key, value) in document.keys {
            if format.settings.contains(key) {
                settings[key] = value
                continue
            }
            guard key == "scan" else {
                let allowed = (["scan"] + format.settings).joined(separator: " and ")
                throw QuickActionError("unknown key “\(key)”: only \(allowed) come\(format.settings.isEmpty ? "s" : "") before the \(nouns)")
            }
            guard case .array(let values) = value else { throw QuickActionError("scan is a list of folders: scan = [\"~/Developer\"]") }
            scan = try values.map {
                guard case .string(let folder) = $0 else { throw QuickActionError("scan is a list of folders: scan = [\"~/Developer\"]") }
                return folder
            }
        }
        let shortcuts = try document.tables.map { table in
            let at = "[\(table.name)] (line \(table.line))"
            var path: String?
            var host: String?
            for (key, value) in table.keys {
                guard case .string(let string) = value, !string.isEmpty else { throw QuickActionError("\(at): \(key) is text in quotes") }
                switch key {
                case "path": path = string
                case "host" where format.allowsHosts: host = string
                default:
                    let has = format.allowsHosts ? "a path and, over SSH, a host" : "a path"
                    throw QuickActionError("\(at): unknown key “\(key)”: a \(format.noun) has \(has)")
                }
            }
            guard let path else { throw QuickActionError("\(at): path is missing") }
            if let host {
                guard path.hasPrefix("/") else { throw QuickActionError("\(at): a path on \(host) starts with /") }
                return FolderShortcut(name: table.name, location: .ssh(host: host, path: path))
            }
            guard path.hasPrefix("/") || path.hasPrefix("~/") else { throw QuickActionError("\(at): the path starts with / or ~/") }
            return FolderShortcut(name: table.name, location: .local(CommandSettings.expand(path, home: home)))
        }
        return Contents(shortcuts: shortcuts, scan: scan, settings: settings)
    }

    /// The folders directly in `folder`, by name. Hidden ones are left out;
    /// a folder that is not there has none.
    static func folders(in folder: String, fileManager: FileManager = .default) -> [FolderShortcut] {
        let url = URL(filePath: folder, directoryHint: .isDirectory)
        let children = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { (try? $0.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { child in
                var path = child.path(percentEncoded: false)
                if path.count > 1, path.hasSuffix("/") { path.removeLast() }
                return FolderShortcut(name: child.lastPathComponent, location: .local(path))
            }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// The listed shortcuts, then the scanned ones whose name is not taken.
    static func merge(_ listed: [FolderShortcut], scanned: [FolderShortcut]) -> [FolderShortcut] {
        var names = Set<String>()
        return (listed + scanned).filter { names.insert(SnippetSearch.fold($0.name)).inserted }
    }

    // MARK: - What is typed

    /// What `text` means: a path (absolute or `~/`, quoted or as copied)
    /// is that file or folder on this Mac; anything else names a shortcut,
    /// matched like a choice (`CommandChoices.pick`). `none` is the message
    /// for there being no shortcuts at all.
    static func target(
        _ text: String, in shortcuts: () throws -> [FolderShortcut], noun: String, none: String,
        home: URL, fileExists: (String) -> Bool, isDirectory: (String) -> Bool
    ) throws -> FolderShortcut {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ActionInput.startsLikePath(text) else {
            let shortcuts = try shortcuts()
            let choice = try CommandChoices.pick(text, in: choices(shortcuts), noun: noun, none: none)
            return shortcuts.first { $0.name == choice.value }!
        }
        let url = try OpenCommand.location(of: .text(text), home: home, fileExists: fileExists)
        let path = url.path(percentEncoded: false)
        return FolderShortcut(name: url.lastPathComponent, location: .local(path), isFile: !isDirectory(path))
    }

    /// One choice per shortcut, by name.
    static func choices(_ shortcuts: [FolderShortcut]) -> [ActionOption.Choice] {
        shortcuts.map { ActionOption.Choice($0.name, title: $0.name) }
    }

    /// Whether `path` is a folder (through a link too).
    public static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
#endif
