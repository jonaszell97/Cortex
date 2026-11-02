import Foundation
import Testing
@testable import Cortex
import CortexCore

/// What the module does for agents: the skills links it keeps in a
/// (temporary) Claude Code skills folder, and the line that adds the MCP
/// server.
@MainActor
@Suite struct KnowledgeAgentsTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"
    let root: URL
    let skills: URL
    let store: UserDefaults

    init() {
        let base = FileManager.default.temporaryDirectory.appending(path: "CortexAgents-\(UUID().uuidString)", directoryHint: .isDirectory)
        root = base.appending(path: "knowledge", directoryHint: .isDirectory)
        skills = base.appending(path: "skills", directoryHint: .isDirectory)
        store = UserDefaults(suiteName: suiteName)!
        store.set(root.path(percentEncoded: false), forKey: "knowledge.folder")
        store.set(false, forKey: "knowledge.keepHistory")
    }

    func makeService() -> KnowledgeService {
        KnowledgeService(settings: KnowledgeSettings(defaults: ModuleDefaults(id: "knowledge", store: store)), skillsFolder: skills)
    }

    func tearDown(_ service: KnowledgeService) {
        service.stop()
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    func links() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: skills.path(percentEncoded: false))) ?? []).sorted()
    }

    @Test func linksSkillsAndFollowsChanges() async throws {
        let service = makeService()
        defer { tearDown(service) }
        try service.folder.createSkill(name: "deploy", description: "Deploys", body: "Push", project: "server")
        await service.start()
        #expect(links() == ["deploy"])
        #expect(service.skillLinksReport?.linked == ["deploy"])

        try service.folder.createSkill(name: "review", description: "Reviews", body: "Read", project: "server")
        await service.refreshNow()
        #expect(links() == ["deploy", "review"])

        try service.folder.delete("server/skills/deploy/SKILL.md")
        await service.refreshNow()
        #expect(links() == ["review"])

        service.settings.linkSkills = false
        service.skillLinksSettingChanged()
        #expect(links().isEmpty)
        #expect(service.skillLinksReport == nil)

        service.settings.linkSkills = true
        service.skillLinksSettingChanged()
        #expect(links() == ["review"])
    }

    @Test func leavesSkillsAloneWhenOff() async throws {
        store.set(false, forKey: "knowledge.linkSkills")
        let service = makeService()
        defer { tearDown(service) }
        try service.folder.createSkill(name: "deploy", description: "Deploys", body: "Push", project: "server")
        await service.start()
        #expect(links().isEmpty)
    }

    @Test func namesTheMCPCommand() {
        let service = makeService()
        defer { tearDown(service) }
        // The tests use another folder, so the line passes it on.
        #expect(service.mcpCommand.hasPrefix("claude mcp add --scope user cortex -- "))
        #expect(service.mcpCommand.contains("/Contents/MacOS/cortex-mcp --folder "))
        #expect(KnowledgeService.shellQuoted("/Applications/Cortex.app/Contents/MacOS/cortex-mcp") == "/Applications/Cortex.app/Contents/MacOS/cortex-mcp")
        #expect(KnowledgeService.shellQuoted("/Users/me/My Notes") == "'/Users/me/My Notes'")
        #expect(KnowledgeService.shellQuoted("it's") == "'it'\\''s'")
    }
}
