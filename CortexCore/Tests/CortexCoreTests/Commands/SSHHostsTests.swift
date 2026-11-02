import Testing
@testable import CortexCore

/// The hosts `@host` can name: the aliases of `~/.ssh/config`.
@Suite struct SSHHostsTests {
    @Test func aliasesOfOneHostEachExceptGitHosting() {
        let config = """
            # Home
            Host raspberrypi pi
               HostName 192.168.178.117
            Host github.com
               HostName github.com
            Host github-private
               HostName github.com
            host vps-docker
                hostname=5.75.183.81
            Host *.internal !bastion ?
                User admin
            Match host foo
                User bar
            Host -oProxyCommand=evil
            Host pi
            """
        #expect(SSHHosts.aliases(config: config) == ["raspberrypi", "pi", "vps-docker"])
    }

    @Test func scriptOutputIsSplitIntoItsSections() {
        let sections = SSHHosts.sections("motd\n@@ system\nLinux\n@@ empty\n@@ ps\n  1 a\n  2 b\n\n")
        #expect(sections == ["system": "Linux", "empty": "", "ps": "  1 a\n  2 b"])
        #expect(HostPlatform(uname: "Darwin\n") == .mac && HostPlatform(uname: "Linux") == .linux && HostPlatform(uname: "AIX") == nil)
    }
}
