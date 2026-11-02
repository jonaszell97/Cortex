import Foundation
import CortexCore

/// Knowledge preferences, stored as "knowledge.<name>".
@MainActor
@Observable
final class KnowledgeSettings {
    @ObservationIgnored private let defaults: ModuleDefaults

    /// A git repository in the folder, committed to a minute after changes.
    var keepHistory: Bool { didSet { defaults.set(keepHistory, for: "keepHistory") } }
    /// One symlink per skill in `~/.claude/skills`, so Claude Code loads
    /// them without the MCP server.
    var linkSkills: Bool { didSet { defaults.set(linkSkills, for: "linkSkills") } }
    /// Another folder than `~/.config/cortex/knowledge`, for tests and for
    /// trying things out ("knowledge.folder"). Not shown in Settings.
    let folderOverride: String?

    init(defaults: ModuleDefaults) {
        self.defaults = defaults
        keepHistory = defaults.bool("keepHistory") ?? true
        linkSkills = defaults.bool("linkSkills") ?? true
        folderOverride = defaults.string("folder").flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The override, else the default folder. Under tests, a temporary
    /// folder: the app tests start every module, and the real folder's git
    /// history must not get their commits.
    var folder: URL {
        if let folderOverride {
            return URL(filePath: (folderOverride as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        if Self.isTesting {
            return FileManager.default.temporaryDirectory.appending(
                path: "CortexTests-knowledge-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return KnowledgeFolder.defaultDirectory()
    }

    /// Claude Code's skills folder. Under tests a temporary one, whatever
    /// the knowledge folder: the tests' skills must never reach Claude Code.
    var skillsFolder: URL {
        if Self.isTesting {
            return FileManager.default.temporaryDirectory.appending(
                path: "CortexTests-skills-\(ProcessInfo.processInfo.processIdentifier)", directoryHint: .isDirectory)
        }
        return KnowledgeSkillLinks.defaultDirectory()
    }

    private static var isTesting: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
