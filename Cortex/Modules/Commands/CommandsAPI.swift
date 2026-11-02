import Foundation
import CortexCore

/// A module that adds `$` commands (AI: `$ask`, `$img`). Asked whenever
/// the commands are listed, so the commands of a module that is switched off
/// disappear, and Commands names no module.
@MainActor
protocol CommandContributing: AnyObject {
    /// Listed after the built-ins, before the user's command files. Names
    /// must not clash with the built-ins'.
    var contributedCommands: [any Command] { get }
}
