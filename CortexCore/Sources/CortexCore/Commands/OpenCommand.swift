#if os(macOS)
import Foundation

/// `$open ~/Downloads`: shows a file or folder in Finder. A folder opens in
/// a window; a file, an app or another package is selected in its folder.
/// The path is absolute or starts with `~/`, quoted like a shell argument or
/// as copied, spaces and all. `>` also offers it on a copied path or a
/// copied file, and the form suggests copied paths.
public struct OpenCommand: Command {
    public let id = "command.open"
    public let name = "open"
    public let title = "Open in Finder"
    public let summary = "Shows a file or folder in Finder: a folder opens, anything else is selected in its folder."
    public let symbol = "folder"
    public let keywords = ["open", "finder", "reveal", "show", "path", "folder", "file", "locate"]
    public let argument: CommandArgument? = CommandArgument(
        title: "Path", placeholder: "~/Downloads", kind: .path, suggestions: .clips(matching: pathPattern))
    /// A copied path: one line, absolute or in the home folder.
    static let pathPattern = "^(/|~/)[^\\n]*$"

    public init() {}

    /// Any text, so that a path that does not exist is the preview's error,
    /// and one file or folder.
    public func accepts(_ input: ActionInput) -> Bool {
        switch input {
        case .text(let text): !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .files(let urls): urls.count == 1
        case .none, .image: false
        }
    }

    /// A copied path to something that exists, or one copied file.
    public func matches(_ input: ActionInput) -> Bool {
        (try? Self.location(of: input)) != nil
    }

    /// Looking the path up is quick; Finder only opens on ⏎.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .open(.reveal(try Self.location(of: invocation.input)))
    }

    /// The one existing file or folder `input` names.
    static func location(
        of input: ActionInput,
        home: URL = URL.homeDirectory,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> URL {
        switch input {
        case .files(let urls) where urls.count == 1:
            guard fileExists(urls[0].path(percentEncoded: false)) else {
                throw QuickActionError("“\(urls[0].lastPathComponent)” is no longer there")
            }
            return urls[0]
        case .files:
            throw QuickActionError("Opens one file or folder at a time")
        case .text(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch ActionInput.typed(trimmed, home: home, fileExists: fileExists) {
            case .files(let urls) where urls.count == 1:
                return urls[0]
            case .files:
                throw QuickActionError("Opens one file or folder at a time")
            default:
                throw QuickActionError(trimmed.hasPrefix("/") || trimmed.hasPrefix("~/")
                    ? "No file or folder at \(trimmed)"
                    : "“\(trimmed)” is not a path: start it with / or ~/")
            }
        case .none, .image:
            throw QuickActionError("Needs a path")
        }
    }
}
#endif
