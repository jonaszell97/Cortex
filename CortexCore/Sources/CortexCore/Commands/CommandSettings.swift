#if os(macOS)
import Foundation

/// A command whose names come from a settings file next to the actions folder
/// (docs/modules/COMMANDS.md, "Settings files"): `$code`'s `projects.toml`,
/// `$term`'s `terminal.toml`, `$sound`'s `sounds.toml`. While the command is
/// typed, ⌘E in the palette opens the file in VS Code (`settingsLink`); the
/// command itself never does.
public protocol SettingsFileCommand: Command {
    var settingsFile: URL { get }
    /// What is written when there is no file: the defaults, with examples to
    /// uncomment.
    var settingsStarter: String { get }
}

public extension SettingsFileCommand {
    /// The link that opens the settings file in VS Code, after writing
    /// `settingsStarter` (and its folder) when there is none, so VS Code has
    /// something to open.
    func settingsLink() throws -> URL {
        try CommandSettings.createIfMissing(settingsFile, starter: settingsStarter)
        return FolderShortcut(name: settingsFile.lastPathComponent, location: .local(settingsFile.path(percentEncoded: false)), isFile: true).vscodeURL
    }
}

/// What the settings files have in common.
public enum CommandSettings {
    /// `name` in `$XDG_CONFIG_HOME/cortex/`, or `~/.config/cortex/`: next to
    /// the actions folder.
    public static func file(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        UserActionLibrary.defaultDirectory(environment: environment)
            .deletingLastPathComponent()
            .appending(path: name, directoryHint: .notDirectory)
    }

    /// What `parse` makes of the file, or nil when there is none. A file that
    /// cannot be read throws, with its name and line.
    static func read<T>(_ file: URL, fileManager: FileManager = .default, parse: (String) throws -> T) throws -> T? {
        guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return nil }
        do {
            return try parse(try String(contentsOf: file, encoding: .utf8))
        } catch let error as TOML.ParseError {
            throw QuickActionError("\(file.lastPathComponent), \(error)")
        } catch let error as QuickActionError {
            throw QuickActionError("\(file.lastPathComponent): \(error.message)")
        }
    }

    /// Writes `starter` to `file`, and its folder, unless the file is there.
    static func createIfMissing(_ file: URL, starter: String, fileManager: FileManager = .default) throws {
        guard !fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { return }
        do {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try starter.write(to: file, atomically: true, encoding: .utf8)
        } catch {
            throw QuickActionError("Cannot create \(file.path(percentEncoded: false)): \(error.localizedDescription)")
        }
    }

    /// `~/x` in `home`; anything else as it is.
    static func expand(_ path: String, home: URL) -> String {
        guard path.hasPrefix("~/") else { return path }
        return home.appending(path: String(path.dropFirst(2))).path(percentEncoded: false)
    }
}
#endif
