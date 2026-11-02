#if os(macOS)
import Foundation

/// A sound `$sound` plays, by a short name.
public struct Sound: Sendable, Equatable {
    /// "airhorn": what is typed after `$sound`.
    public var name: String
    public var file: URL

    public init(name: String, file: URL) {
        self.name = name
        self.file = file
    }
}

/// `sounds.toml` next to the actions folder, and the folder `$clip` saves
/// clips to:
///
/// ```toml
/// folder = "~/Music/Sounds"   # each sound file in it plays by its name; default: sounds/ next to the file
///
/// [horn]                               # $sound horn
/// path = "airhorn.mp4"                 # in the folder, or starting with / or ~/
/// ```
///
/// The sounds of the file come first, in its order, then the folder's files
/// by name. A name the file gives wins over a file's.
public enum SoundLibrary {
    /// The file extensions of the folder's sounds: what AVFoundation plays.
    static let extensions: Set<String> = ["mp4", "m4a", "m4v", "mov", "mp3", "wav", "aif", "aiff", "aifc", "caf", "aac"]

    /// `$XDG_CONFIG_HOME/cortex/sounds.toml`, or `~/.config/cortex/sounds.toml`.
    public static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        CommandSettings.file("sounds.toml", environment: environment)
    }

    /// What ⌘E on `$sound` writes when there is no file: the defaults, with
    /// an example to uncomment.
    static let starter = """
        # Sounds for $sound; $clip saves new ones to the folder (docs/modules/COMMANDS.md, "$clip and $sound").

        # Where $clip saves clips (default: the sounds folder next to this file).
        # Every sound file in it plays by its name.
        # folder = "~/Music/Sounds"

        # [horn]                        # $sound horn
        # path = "airhorn.mp4"          # in the folder, or a path starting with / or ~/

        """

    /// The folder and the sounds, as the file at `file` sets them.
    public struct Contents: Sendable, Equatable {
        public var folder: URL
        /// The file's sounds, then the folder's.
        public var sounds: [Sound]
    }

    /// The file's sounds (none when there is no file) and the folder's. A
    /// file that cannot be read throws, with its name and line.
    public static func load(
        file: URL = defaultFile(), home: URL = URL.homeDirectory, fileManager: FileManager = .default
    ) throws -> Contents {
        let standard = defaultFolder(for: file)
        let (folder, listed) = try CommandSettings.read(file, fileManager: fileManager) { try parse($0, home: home, folder: standard) }
            ?? (standard, [])
        var names = Set<String>()
        let sounds = (listed + files(in: folder, fileManager: fileManager)).filter { names.insert(SnippetSearch.fold($0.name)).inserted }
        return Contents(folder: folder, sounds: sounds)
    }

    /// `sounds/` next to the file: where clips go unless it sets `folder`.
    public static func defaultFolder(for file: URL) -> URL {
        file.deletingLastPathComponent().appending(path: "sounds", directoryHint: .isDirectory)
    }

    /// The folder a file sets (else `folder`) and the sounds it lists.
    static func parse(_ text: String, home: URL, folder: URL) throws -> (folder: URL, sounds: [Sound]) {
        let document = try TOML.parseTables(text)
        var folder = folder
        for (key, value) in document.keys {
            guard key == "folder" else { throw QuickActionError("unknown key “\(key)”: only folder comes before the sounds") }
            guard case .string(let path) = value, path.hasPrefix("/") || path.hasPrefix("~/") else {
                throw QuickActionError("folder is a path in quotes, starting with / or ~/")
            }
            folder = URL(filePath: CommandSettings.expand(path, home: home), directoryHint: .isDirectory)
        }
        let sounds = try document.tables.map { table in
            let at = "[\(table.name)] (line \(table.line))"
            var path: String?
            for (key, value) in table.keys {
                guard key == "path" else { throw QuickActionError("\(at): unknown key “\(key)”: a sound has a path") }
                guard case .string(let string) = value, !string.isEmpty else { throw QuickActionError("\(at): path is text in quotes") }
                path = string
            }
            guard let path else { throw QuickActionError("\(at): path is missing") }
            let file = path.hasPrefix("/") || path.hasPrefix("~/")
                ? URL(filePath: CommandSettings.expand(path, home: home))
                : folder.appending(path: path)
            return Sound(name: table.name, file: file)
        }
        return (folder, sounds)
    }

    /// The sound files directly in `folder`, by name without the extension.
    /// Hidden ones are left out; a folder that is not there has none.
    static func files(in folder: URL, fileManager: FileManager = .default) -> [Sound] {
        let children = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { extensions.contains($0.pathExtension.lowercased()) }
            .map { Sound(name: $0.deletingPathExtension().lastPathComponent, file: $0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
