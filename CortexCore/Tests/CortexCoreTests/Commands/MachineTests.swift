import Foundation
import Testing
@testable import CortexCore

/// Where a command runs: this Mac, or a host the typed `@words` name.
@Suite struct MachineTests {
    let hosts = ["raspberrypi", "linode", "lab-1", "lab-2"]

    @Test func itsTitleIsThisMacOrTheAlias() {
        #expect(Machine.local.title == "This Mac" && Machine.local.alias == nil)
        #expect(Machine.ssh("pi").title == "pi" && Machine.ssh("pi").alias == "pi")
        #expect(Machine.local.describing("Memory Usage") == "Memory Usage")
        #expect(Machine.ssh("pi").describing("Memory Usage") == "Memory Usage on pi")
    }

    @Test func noWordMeansThisMac() throws {
        #expect(try Machine.named(by: [], in: hosts) == .local)
        #expect(try Machine.named(by: [], in: []) == .local)
    }

    @Test func aWordPicksAHostLikeAChoice() throws {
        #expect(try Machine.named(by: ["linode"], in: hosts) == .ssh("linode"))
        #expect(try Machine.named(by: ["LINODE"], in: hosts) == .ssh("linode"), "ignoring case")
        #expect(try Machine.named(by: ["rasp"], in: hosts) == .ssh("raspberrypi"), "the only one that starts with it")
        #expect(try Machine.named(by: ["lab-1"], in: hosts) == .ssh("lab-1"))
    }

    @Test func anythingElseSaysWhichHostsThereAre() {
        #expect(throws: QuickActionError("“@nas” is not a host in ~/.ssh/config. Hosts: raspberrypi, linode, lab-1, lab-2")) {
            try Machine.named(by: ["nas"], in: hosts)
        }
        #expect(throws: QuickActionError("“@” is not a host in ~/.ssh/config. Hosts: raspberrypi, linode, lab-1, lab-2")) {
            try Machine.named(by: [""], in: hosts)
        }
        #expect(throws: QuickActionError("“@nas” is not a host in ~/.ssh/config.")) {
            try Machine.named(by: ["nas"], in: [])
        }
        #expect(throws: QuickActionError("“@lab” could be lab-1, lab-2: type more of the name")) {
            try Machine.named(by: ["lab"], in: hosts)
        }
    }

    @Test func oneHostAtATime() {
        #expect(throws: QuickActionError("One host at a time: @linode and @lab-1")) {
            try Machine.named(by: ["linode", "lab-1"], in: hosts)
        }
        #expect(throws: QuickActionError("One host at a time: @linode and @linode")) {
            try Machine.named(by: ["linode", "linode"], in: hosts)
        }
    }

    @Test func thisMacRunsAScriptWithSh() async throws {
        #expect(try await Machine.local.run("echo hello; echo 'a b'") == "hello\na b\n")
        let shell: MachineShell = Machine.shell
        #expect(try await shell(.local, "printf %s ok") == "ok")
        await #expect(throws: QuickActionError("boom")) {
            try await Machine.local.run("echo boom >&2; exit 3")
        }
    }
}
