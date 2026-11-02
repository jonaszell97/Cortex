import Foundation
import Testing
@testable import Cortex
import CortexCore

/// The real modules, as `ModuleList` lists them.
@MainActor
@Suite struct ModuleListTests {
    let suiteName = "CortexTests-\(UUID().uuidString)"

    func host() throws -> ModuleHost {
        let services = ModuleServices(
            database: try makeTestDatabase(), defaults: UserDefaults(suiteName: suiteName)!, secrets: MemorySecrets())
        return ModuleHost(ModuleList.all, services: services, registerHotkey: { _ in })
    }

    @Test func manifestsHaveNoProblems() {
        #expect(ModuleManifest.problems(in: ModuleList.all.map { $0.manifest }).isEmpty)
    }

    @Test func theTriggersInPlaceholderOrder() {
        let routes = ModuleList.all.map { $0.manifest }.sorted { $0.order < $1.order }.compactMap { manifest -> String? in
            guard case .prefix(let prefix)? = manifest.trigger else { return nil }
            return prefix
        }
        #expect(routes == [";", "+", "?", ">", "$", ":", "=", "::"])
        let commands = ModuleList.all.map { $0.manifest }.first { $0.id == "commands" }
        #expect(commands?.requirements == [.module("actions")], "runs its commands through Quick Actions")
    }

    @Test func optionIDsAreUniqueWithinEachModule() throws {
        let host = try host()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        for module in host.modules {
            let ids = module.options.map(\.id)
            #expect(Set(ids).count == ids.count, "\(ModuleHost.manifest(of: module).id)")
        }
    }

    @Test func activeModulesAskForAccessibilityAndFinderAutomation() throws {
        let host = try host()
        defer { UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName) }
        #expect(host.activePermissions == [.accessibility, .finderAutomation])
    }
}
