#if os(macOS)
import Foundation

/// `projects.toml` next to the actions folder: the projects `$code` opens
/// in VS Code, in the format `$term` shares (`FolderShortcuts`), where a
/// project may be on a host over SSH:
///
/// ```toml
/// scan = ["~/Developer"]        # each folder in it is a project (the default)
///
/// [api]                         # $code api
/// path = "~/Developer/myapp/myapp-api"
///
/// [pi]                          # over SSH: an alias from ~/.ssh/config
/// host = "raspberrypi"
/// path = "/home/pi/home-assistant"
/// ```
public enum CodeProjects {
    static let format = FolderShortcuts.Format(noun: "project", allowsHosts: true)

    /// `$XDG_CONFIG_HOME/cortex/projects.toml`, or `~/.config/cortex/projects.toml`.
    public static func defaultFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        CommandSettings.file("projects.toml", environment: environment)
    }

    /// What ⌘E on `$code` writes when there is no file: the defaults, with
    /// examples to uncomment.
    static let starter = """
        # Projects for $code (docs/modules/COMMANDS.md, "$code projects").

        # Folders whose folders are projects, by name; [] for none.
        # scan = ["~/Developer"]

        # [api]                                 # $code api
        # path = "~/Developer/myapp/myapp-api"  # a folder or a .code-workspace file

        # [pi]                                  # over SSH, with VS Code's Remote-SSH extension
        # host = "raspberrypi"                  # an alias from ~/.ssh/config, or user@host
        # path = "/home/pi/home-assistant"      # absolute on that host

        """

    /// The file's projects (none when there is no file) and the scanned
    /// folders'. A file that cannot be read throws, with its name and line.
    public static func load(
        file: URL = defaultFile(), home: URL = URL.homeDirectory, fileManager: FileManager = .default
    ) throws -> [FolderShortcut] {
        try FolderShortcuts.load(file: file, format: format, home: home, fileManager: fileManager).shortcuts
    }
}

extension FolderShortcut {
    /// The link VS Code opens it from: `vscode://file/Users/me/Developer/x`
    /// or `vscode://vscode-remote/ssh-remote+devbox/home/me/x`. A folder or a
    /// `.code-workspace` file gets `windowId=_blank`: VS Code then opens a new
    /// window, unless one already has it open, which it focuses. A single
    /// file opens in the window whose folder has it, else the last one.
    public var vscodeURL: URL {
        var components = URLComponents()
        components.scheme = "vscode"
        let path: String
        switch location {
        case .local(let local):
            components.host = "file"
            components.path = local
            path = local
        case .ssh(let host, let remote):
            components.host = "vscode-remote"
            components.path = "/ssh-remote+\(host)\(remote)"
            path = remote
        }
        if !isFile || path.hasSuffix(".code-workspace") { components.queryItems = [URLQueryItem(name: "windowId", value: "_blank")] }
        return components.url ?? URL(string: "vscode://")!
    }
}
#endif
