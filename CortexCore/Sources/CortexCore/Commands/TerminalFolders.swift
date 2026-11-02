#if os(macOS)
import Foundation

/// `terminal.toml` next to the actions folder: the folders `$term` opens a
/// terminal in, in the format `$code` shares (`FolderShortcuts`, on this Mac or
/// over SSH), and the terminal app:
///
/// ```toml
/// app = "Ghostty"               # default: Terminal
/// scan = ["~/Developer"]        # each folder in it is a folder by its name (the default)
///
/// [dl]                          # $term dl
/// path = "~/Downloads"
///
/// [pi]                          # $term pi: ssh raspberrypi, in this folder
/// host = "raspberrypi"
/// path = "/home/pi/home-assistant"
/// ```
public enum TerminalFolders {
    /// The app when the file does not name one.
    public static let defaultApp = "Terminal"
    /// Where an app given by name is looked for, in this order.
    static let applicationFolders = [
        "~/Applications", "/Applications", "/Applications/Utilities",
        "/System/Applications", "/System/Applications/Utilities",
    ]
    static let format = FolderShortcuts.Format(noun: "folder", allowsHosts: true, settings: ["app"])

    /// `$XDG_CONFIG_HOME/cortex/terminal.toml`, or `~/.config/cortex/terminal.toml`.
    public static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        CommandSettings.file("terminal.toml", environment: environment)
    }

    /// What ⌘E on `$term` writes when there is no file: the defaults, with
    /// examples to uncomment.
    static let starter = """
        # Folders for $term (docs/modules/COMMANDS.md, "$term folders").

        # The terminal app, by name or as a path to the .app.
        # app = "Terminal"

        # Folders whose folders open by their name; [] for none.
        # scan = ["~/Developer"]

        # [dl]                                  # $term dl
        # path = "~/Downloads"                  # starting with / or ~/

        # [pi]                                  # $term pi: an SSH session in a new window
        # host = "raspberrypi"                  # an alias from ~/.ssh/config, or user@host
        # path = "/home/pi/home-assistant"      # absolute on that host

        """

    /// The app and the folders, as the file sets them.
    public struct Contents: Sendable, Equatable {
        /// "Terminal", "Ghostty" or "/Applications/iTerm.app".
        public var app: String
        /// The file's folders, then the scanned ones.
        public var folders: [FolderShortcut]

        public init(app: String = TerminalFolders.defaultApp, folders: [FolderShortcut]) {
            self.app = app
            self.folders = folders
        }
    }

    /// The file's app and folders (none when there is no file) and the
    /// scanned folders. A file that cannot be read throws, with its name and
    /// line.
    public static func load(
        file: URL = defaultFile(), home: URL = URL.homeDirectory, fileManager: FileManager = .default
    ) throws -> Contents {
        let (folders, settings) = try FolderShortcuts.load(file: file, format: format, home: home, fileManager: fileManager)
        var app = defaultApp
        switch settings["app"] {
        case nil: break
        case .string(let name) where !name.trimmingCharacters(in: .whitespaces).isEmpty: app = name
        default: throw QuickActionError("\(file.lastPathComponent): app is the name of an app in quotes: app = \"Terminal\"")
        }
        return Contents(app: app, folders: folders)
    }

    /// The app `name` means: a path to it (absolute or `~/`), or its name
    /// with or without `.app` in the application folders.
    static func application(named name: String, home: URL, fileExists: (String) -> Bool) throws -> URL {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.hasPrefix("/") || name.hasPrefix("~/") {
            let path = CommandSettings.expand(name, home: home)
            guard fileExists(path) else { throw QuickActionError("There is no app at \(name)") }
            return URL(filePath: path, directoryHint: .isDirectory)
        }
        let bundle = name.lowercased().hasSuffix(".app") ? name : name + ".app"
        for folder in applicationFolders {
            let path = CommandSettings.expand(folder, home: home) + "/" + bundle
            if fileExists(path) { return URL(filePath: path, directoryHint: .isDirectory) }
        }
        throw QuickActionError("No app called “\(name)” in Applications: set app in terminal.toml to its name or path")
    }
}
#endif
