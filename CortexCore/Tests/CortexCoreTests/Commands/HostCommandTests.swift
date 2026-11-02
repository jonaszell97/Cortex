import Foundation
import Testing
@testable import CortexCore

/// `$port` and `$kill` on a host: canned answers of a Linux host (`pi`) and a
/// Mac (`mini`), the same code as for this Mac.
@Suite struct HostCommandTests {
    let pi = Machine.ssh("pi")
    let mini = Machine.ssh("mini")

    private func context(_ machine: Machine) -> ActionContext {
        ActionContext(fallbackOutputDirectory: URL(filePath: "/tmp"), temporaryDirectory: URL(filePath: "/tmp"), machine: machine)
    }

    private func confirmation(_ output: ActionOutput) throws -> ActionConfirmation {
        guard case .confirm(let confirmation) = output else { throw QuickActionError("expected a confirmation, got \(output)") }
        return confirmation
    }

    /// `ss -Hlntup 'sport = :3000'` on a Pi: Node on TCP (v4 and v6), a UDP
    /// socket with two processes, and a socket of root's without `users`.
    static let ss = """
        tcp   LISTEN 0      511          0.0.0.0:3000       0.0.0.0:*    users:(("node",pid=812,fd=20))
        tcp   LISTEN 0      511             [::]:3000          [::]:*    users:(("node",pid=812,fd=21))
        udp   UNCONN 0      0          127.0.0.1:3000       0.0.0.0:*    users:(("Web Content",pid=813,fd=9),("helper",pid=814,fd=3))
        tcp   LISTEN 0      4096         0.0.0.0:3000       0.0.0.0:*
        tcp   LISTEN 0      4096         0.0.0.0:30000      0.0.0.0:*    users:(("other",pid=1,fd=3))
        """

    /// The answer to `PortCommand.lookupScript` on the Pi.
    static func piPort(ss: String = Self.ss, docker: String = "@@ nodocker") -> String {
        let pids = ss.isEmpty ? "" : """
            @@ names
              812 node
              813 Web Content
              814 helper
            @@ commands
              812 node /srv/app/server.js --port 3000
              813 /usr/lib/firefox/firefox -contentproc
              814 helper --serve
            """
        return "@@ system\nLinux\n@@ self\n5001 5000\n@@ ss\n\(ss)\n\(pids)\n\(docker)\n"
    }

    static let web = "880fb5d67454\tweb\tnginx:latest\t0.0.0.0:3000->80/tcp, [::]:3000->80/tcp"

    /// Hosts that answer the scripts of `$port`, `$kill` and docker with these.
    private func canned(
        port: String = piPort(), ending: String = "", own: String = ProcessToolsTests.linuxOwn
    ) -> CannedHosts {
        CannedHosts { _, script in
            if script.contains("docker stop") { return "" }
            if script.contains("echo '@@ ending'") { return "@@ ending\n\(ending)\n" }
            if script.contains("uid=$(id -u)") { return own }
            return port
        }
    }

    // MARK: - ss

    @Test func parsesSs() {
        let listeners = PortCommand.parse(ssOutput: Self.ss, port: 3000)
        #expect(listeners == [
            RunningProcess(pid: 812, name: "node", endpoints: ["TCP 0.0.0.0:3000", "TCP [::]:3000"]),
            RunningProcess(pid: 813, name: "Web Content", endpoints: ["UDP 127.0.0.1:3000"]),
            RunningProcess(pid: 814, name: "helper", endpoints: ["UDP 127.0.0.1:3000"]),
        ], "a socket of another user's has no processes, and the whole port counts, not a prefix")
        #expect(PortCommand.parse(ssOutput: "", port: 3000).isEmpty)
        #expect(PortCommand.parse(ssOutput: "Netid State Recv-Q Send-Q Local Address:Port Peer Address:Port Process\n", port: 3000).isEmpty,
                "the header of an old ss")
        #expect(PortCommand.parse(ssOutput: "tcp LISTEN 0 4096 127.0.0.53%lo:53 0.0.0.0:* users:((\"systemd-resolve\",pid=600,fd=14))", port: 53)
            == [RunningProcess(pid: 600, name: "systemd-resolve", endpoints: ["TCP 127.0.0.53%lo:53"])])
    }

    // MARK: - $port

    @Test func portOnALinuxHostListsTheSshUsersListeners() async throws {
        let hosts = canned()
        let output = try await PortCommand(shell: hosts.shell).output(.text("3000"), context: context(pi))
        let confirmation = try confirmation(output)
        #expect(confirmation.title == "Kill 3 processes on pi (port 3000)?")
        #expect(confirmation.confirmTitle == "Kill 3 Processes")
        #expect(confirmation.message.hasPrefix("node (PID 812)\nTCP 0.0.0.0:3000\nTCP [::]:3000\nnode /srv/app/server.js --port 3000\n\n"))
        #expect(confirmation.message.contains("Web Content (PID 813)\nUDP 127.0.0.1:3000\n/usr/lib/firefox/firefox -contentproc"))
        #expect(hosts.scripts.count == 1 && hosts.scripts[0].machine == pi, "one connection, to the host")
        #expect(hosts.scripts[0].script.contains("ss -Hlntup 'sport = :3000'") && hosts.scripts[0].script.contains("lsof"))
        #expect(!hosts.scripts[0].script.contains("sudo"))
    }

    @Test func endingRunsOnTheSameHostAndTellsWhatHappened() async throws {
        let hosts = canned(ending: "ended 812\nforced 813\nended 814")
        let command = PortCommand(shell: hosts.shell)
        let confirmation = try confirmation(try await command.output(.text("3000"), context: context(pi)))
        #expect(hosts.scripts.count == 1, "looking up ends nothing")
        #expect(try await confirmation.perform() == .done("Ended 3 processes on pi (port 3000), 1 of them with SIGKILL"))
        #expect(hosts.scripts.map { $0.machine } == [pi, pi])
        let script = hosts.scripts[1].script
        #expect(script.contains("term 812 'node'") && script.contains("term 813 'Web Content'") && script.contains("force 814 'helper'"))
    }

    @Test func oneListenerIsNamedByTheHost() async throws {
        let hosts = canned(port: Self.piPort(ss: Self.ss.components(separatedBy: "\n")[0]), ending: "ended 812")
        let confirmation = try confirmation(try await PortCommand(shell: hosts.shell).output(.text(":3000"), context: context(pi)))
        #expect(confirmation.title == "Kill node on pi?")
        #expect(confirmation.confirmTitle == "Kill")
        #expect(try await confirmation.perform() == .done("Ended node (PID 812) on pi (port 3000)"))
    }

    @Test func nothingListeningSaysWhichHost() async throws {
        let hosts = canned(port: Self.piPort(ss: "tcp   LISTEN 0      4096         0.0.0.0:3000       0.0.0.0:*"))
        await #expect(throws: QuickActionError.notice("Nothing is listening on port 3000 on pi (only your own processes are checked)"), "root's socket is not the user's") {
            try await PortCommand(shell: hosts.shell).resolve(.text("3000"), machine: pi)
        }
        let none = canned(port: Self.piPort(ss: ""))
        await #expect(throws: QuickActionError.notice("Nothing is listening on port 3000 on pi (only your own processes are checked)")) {
            try await PortCommand(shell: none.shell).resolve(.text("3000"), machine: pi)
        }
    }

    @Test func aLinuxHostAlwaysAsksDockerBecauseTheProxyIsRoots() async throws {
        let hosts = canned(port: Self.piPort(ss: "", docker: "@@ docker\n\(Self.web)"), ending: "")
        let command = PortCommand(shell: hosts.shell)
        let confirmation = try confirmation(try await command.output(.text("3000"), context: context(pi)))
        #expect(hosts.scripts.count == 1, "asked in the same connection")
        #expect(hosts.scripts[0].script.contains("docker ps --filter publish=3000"))
        #expect(confirmation.title == "Stop container web on pi?")
        #expect(confirmation.confirmTitle == "Stop Container")
        #expect(confirmation.message.hasPrefix("Container web (880fb5d67454)\nImage nginx:latest\n0.0.0.0:3000->80/tcp"))
        #expect(try await confirmation.perform() == .done("Stopped container web on pi (port 3000)"))
        #expect(hosts.scripts[1].machine == pi && hosts.scripts[1].script.contains("docker stop --time 3 '880fb5d67454'"))
    }

    @Test func aContainerWithTheOwnPortIsNotOfferedForThePort() async throws {
        let behind = "@@ docker\n880fb5d67454\tweb\tnginx:latest\t0.0.0.0:8080->80/tcp, [::]:8080->80/tcp"
        let hosts = canned(port: Self.piPort(ss: "", docker: behind))
        await #expect(throws: QuickActionError.notice("Nothing is listening on port 80 on pi (only your own processes are checked)")) {
            try await PortCommand(shell: hosts.shell).resolve(.text("80"), machine: pi)
        }
        let confirmation = try confirmation(try await PortCommand(shell: hosts.shell).output(.text("8080"), context: context(pi)))
        #expect(confirmation.title == "Stop container web on pi?")
    }

    @Test func aProcessAndAContainerTogether() async throws {
        let ss = Self.ss.components(separatedBy: "\n")[0]
        let hosts = canned(port: Self.piPort(ss: ss, docker: "@@ docker\n\(Self.web)"), ending: "ended 812")
        let confirmation = try confirmation(try await PortCommand(shell: hosts.shell).output(.text("3000"), context: context(pi)))
        #expect(confirmation.title == "Free port 3000 on pi?")
        #expect(confirmation.confirmTitle == "Stop and Kill")
        #expect(try await confirmation.perform() == .done("Stopped container web and ended node (PID 812) on pi (port 3000)"))
    }

    @Test func dockerTroubleOnlyMattersWhenNothingElseIsFound() async throws {
        let denied = "@@ dockererror\npermission denied while trying to connect to the Docker daemon socket\nsee 'docker --help'"
        let empty = canned(port: Self.piPort(ss: "", docker: denied))
        await #expect(throws: QuickActionError.notice("Nothing is listening on port 3000 on pi (only your own processes are checked). Looking for a container failed: docker ps failed: see 'docker --help'")) {
            try await PortCommand(shell: empty.shell).resolve(.text("3000"), machine: pi)
        }
        let busy = canned(port: Self.piPort(docker: denied))
        guard case .confirm = try await PortCommand(shell: busy.shell).output(.text("3000"), context: context(pi)) else {
            throw QuickActionError("the listeners are still offered")
        }
    }

    @Test func aMacHostAsksDockerOnlyWhenARuntimeHoldsThePort() async throws {
        let lsof = """
            p10628
            ccom.docker.backend
            Lalex
            f20
            PTCP
            n*:3000
            """
        let docker = "@@ docker\n\(Self.web)\n"
        let hosts = CannedHosts { _, script in
            if script.contains("docker stop") { return "" }
            if script.contains("lsof -nP") {
                return "@@ system\nDarwin\n@@ self\n7001 7000\n@@ lsof\n\(lsof)\n@@ names\n10628 /Applications/Docker.app/Contents/MacOS/com.docker.backend\n@@ commands\n10628 com.docker.backend run\n"
            }
            return "@@ system\nDarwin\n" + docker
        }
        let command = PortCommand(shell: hosts.shell)
        let confirmation = try confirmation(try await command.output(.text("3000"), context: context(mini)))
        #expect(hosts.scripts.count == 2 && hosts.scripts.allSatisfy { $0.machine == mini })
        #expect(!hosts.scripts[0].script.contains("docker ps") || hosts.scripts[0].script.contains("[ \"$system\" = Linux ]"), "Linux only")
        #expect(hosts.scripts[1].script.contains("docker ps --filter publish=3000"))
        #expect(confirmation.title == "Stop container web on mini?")
        #expect(!confirmation.message.contains("com.docker.backend"), "the runtime is never killed")
    }

    @Test func aMacWithoutARuntimeNeverAsksDocker() async throws {
        let hosts = CannedHosts { _, _ in
            "@@ system\nDarwin\n@@ self\n7001 7000\n@@ lsof\np55\nczzz\nPTCP\nn*:3000\n@@ names\n55 /usr/bin/nc\n@@ commands\n55 nc -l 3000\n"
        }
        let confirmation = try confirmation(try await PortCommand(shell: hosts.shell).output(.text("3000"), context: context(mini)))
        #expect(hosts.scripts.count == 1)
        #expect(confirmation.title == "Kill nc on mini?", "the name `ps` gives, which the script checks")
    }

    @Test func portErrorsNameTheHost() async throws {
        func error(_ output: String, _ machine: Machine) async -> QuickActionError? {
            let hosts = CannedHosts { _, _ in output }
            do {
                _ = try await PortCommand(shell: hosts.shell).output(.text("3000"), context: context(machine))
                return nil
            } catch let error as QuickActionError {
                return error
            } catch { return nil }
        }
        #expect(await error("@@ system\nLinux\n@@ nolisteners\n", pi) == QuickActionError("pi has no ss or lsof command"))
        #expect(await error("@@ system\nDarwin\n@@ nolisteners\n", mini) == QuickActionError("mini has no lsof command"))
        #expect(await error("@@ system\nDarwin\n@@ nolisteners\n", .local) == QuickActionError("lsof is not available"))
        #expect(await error("@@ system\nSunOS\n", pi) == QuickActionError("pi runs SunOS; only macOS and Linux hosts are read over SSH"))
        #expect(await error("", pi) == QuickActionError("pi runs an unknown system; only macOS and Linux hosts are read over SSH"))

        let down = CannedHosts { host, _ in throw QuickActionError("\(host): ssh: connect to host pi port 22: Operation timed out") }
        await #expect(throws: QuickActionError("pi: ssh: connect to host pi port 22: Operation timed out")) {
            try await PortCommand(shell: down.shell).output(.text("3000"), context: context(pi))
        }
        await #expect(throws: QuickActionError("“http” is not a port number (1–65535)")) {
            try await PortCommand(shell: down.shell).output(.text("http"), context: context(pi))
        }
        #expect(down.scripts.count == 1, "a bad port is not asked")
    }

    @Test func aProcessOfAnotherUserIsReportedNotSkipped() async throws {
        let ss = Self.ss.components(separatedBy: "\n")[0]
        let hosts = canned(port: Self.piPort(ss: ss), ending: "denied 812")
        let confirmation = try confirmation(try await PortCommand(shell: hosts.shell).output(.text("3000"), context: context(pi)))
        await #expect(throws: QuickActionError("Not allowed to kill node (PID 812) on pi: it belongs to another user")) {
            try await confirmation.perform()
        }
    }

    @Test func confirmingLateFindsEverythingGone() async throws {
        let hosts = canned(ending: "gone 812\ngone 813\ngone 814")
        let confirmation = try confirmation(try await PortCommand(shell: hosts.shell).output(.text("3000"), context: context(pi)))
        #expect(try await confirmation.perform() == .done("Nothing is listening on port 3000 on pi any more"))
    }

    // MARK: - $kill

    @Test func killByNameOnALinuxHost() async throws {
        let hosts = canned(ending: "ended 812\nended 813")
        let command = KillCommand(shell: hosts.shell)
        let confirmation = try confirmation(try await command.output(.text("node"), context: context(pi)))
        #expect(confirmation.title == "Kill 2 processes on pi?", "not nodemon")
        #expect(confirmation.confirmTitle == "Kill 2 Processes")
        #expect(confirmation.message.hasPrefix("node (PID 812)\nnode /srv/app/server.js --port 3000\n\nnode (PID 813)"))
        #expect(hosts.scripts.count == 1 && hosts.scripts[0].machine == pi)
        #expect(try await confirmation.perform() == .done("Ended 2 processes on pi"))
        #expect(hosts.scripts.map { $0.machine } == [pi, pi])
    }

    @Test func killNarrowedByTheCommandLineAndByPID() async throws {
        let hosts = canned(ending: "forced 813")
        let command = KillCommand(shell: hosts.shell)
        let byWords = try confirmation(try await command.output(.text("node worker.js"), context: context(pi)))
        #expect(byWords.title == "Kill node on pi?")
        #expect(try await byWords.perform() == .done("Force-killed node (PID 813) on pi: it did not quit after SIGTERM"))
        #expect(hosts.scripts[1].script.contains("term 813 'node'"))
        let byPID = try confirmation(try await command.output(.text("900"), context: context(pi)))
        #expect(byPID.title == "Kill nodemon on pi?")
    }

    @Test func killFindsNothingOnTheHost() async throws {
        let hosts = canned()
        let command = KillCommand(shell: hosts.shell)
        await #expect(throws: QuickActionError.notice("None of your processes on pi is called “nope”")) {
            try await command.resolve(.text("nope"), machine: pi)
        }
        await #expect(throws: QuickActionError.notice("None of your processes on pi has PID 4242")) {
            try await command.resolve(.text("4242"), machine: pi)
        }
        await #expect(throws: QuickActionError.notice("None of your processes on pi is called “systemd”"), "root's is not the user's") {
            try await command.resolve(.text("systemd"), machine: pi)
        }
        await #expect(throws: QuickActionError.notice("None of your processes is called “nope”")) {
            try await command.resolve(.text("nope"))
        }
    }

    @Test func killNeverOffersWhatLogsTheUserOut() async throws {
        let own = "@@ system\nLinux\n@@ uid\n1000\n@@ ps\n  600 1000 systemd\n@@ commands\n600 /lib/systemd/systemd --user\n"
        let hosts = canned(own: own)
        await #expect(throws: QuickActionError.notice("systemd is not offered: ending it logs you out")) {
            try await KillCommand(shell: hosts.shell).resolve(.text("systemd"), machine: pi)
        }
    }

    @Test func killNeverOffersSshdOrTheFirstProcess() async throws {
        let own = "@@ system\nLinux\n@@ uid\n1000\n@@ ps\n    1  1000 init\n  700  1000 sshd\n  701  1000 node\n"
            + "@@ commands\n1 /sbin/init\n700 sshd: pi [priv]\n701 node app.js\n"
        let hosts = canned(own: own)
        let command = KillCommand(shell: hosts.shell)
        await #expect(throws: QuickActionError.notice("sshd is not offered: ending it can lock you out of the host")) {
            try await command.resolve(.text("sshd"), machine: pi)
        }
        await #expect(throws: QuickActionError.notice("init is not offered: it is the first process, and ending it takes the system down")) {
            try await command.resolve(.text("1"), machine: pi)
        }
        await #expect(throws: QuickActionError.notice("init is not offered: it is the first process, and ending it takes the system down")) {
            try await command.resolve(.text("init"), machine: pi)
        }
        let node = try confirmation(try await command.output(.text("node"), context: context(pi)))
        #expect(node.title == "Kill node on pi?")
    }

    @Test func theFirstProcessIsNotOfferedWhateverItIsCalled() async throws {
        let own = "@@ system\nDarwin\n@@ uid\n0\n@@ ps\n    1     0 /sbin/launchd\n  310     0 /sbin/launchd\n@@ commands\n1 /sbin/launchd\n310 /sbin/launchd\n"
        let hosts = canned(own: own)
        let command = KillCommand(shell: hosts.shell)
        await #expect(throws: QuickActionError.notice("launchd is not offered: it is the first process, and ending it takes the system down")) {
            try await command.resolve(.text("1"), machine: pi)
        }
        await #expect(throws: QuickActionError.notice("launchd is not offered: ending it logs you out"), "the user's own is protected by its name") {
            try await command.resolve(.text("310"), machine: pi)
        }
    }

    @Test func alreadyQuitNamesTheHost() async throws {
        let hosts = canned(ending: "gone 900")
        let confirmation = try confirmation(try await KillCommand(shell: hosts.shell).output(.text("nodemon"), context: context(pi)))
        #expect(try await confirmation.perform() == .done("nodemon (PID 900) has already quit on pi"))
    }

    @Test func killWithAColonIsPortOnTheHost() async throws {
        let ss = Self.ss.components(separatedBy: "\n")[0]
        let hosts = canned(port: Self.piPort(ss: ss))
        let output = try await KillCommand(shell: hosts.shell).output(.text(":3000"), context: context(pi))
        #expect(try confirmation(output).title == "Kill node on pi?")
        #expect(hosts.scripts.map { $0.machine } == [pi])
    }

    @Test func thisMacTakesTheSameWayAndKeepsItsTitles() async throws {
        let hosts = canned(ending: "ended 312", own: ProcessToolsTests.macOwn)
        let command = KillCommand(shell: hosts.shell)
        let confirmation = try confirmation(try await command.output(.text("node"), context: context(.local)))
        #expect(confirmation.title == "Kill node?")
        #expect(hosts.scripts.map { $0.machine } == [.local])
        #expect(try await confirmation.perform() == .done("Ended node (PID 312)"))

        let port = PortCommand().confirmation(
            port: 3000, processes: [RunningProcess(pid: 1, name: "a"), RunningProcess(pid: 2, name: "b")], containers: [])
        #expect(port.title == "Kill 2 processes on port 3000?")
        let onHost = PortCommand().confirmation(
            port: 3000, machine: pi, processes: [RunningProcess(pid: 1, name: "a"), RunningProcess(pid: 2, name: "b")], containers: [])
        #expect(onHost.title == "Kill 2 processes on pi (port 3000)?")
        let web = DockerContainer(id: "1", name: "web", image: "nginx")
        let two = PortCommand().confirmation(port: 3000, machine: pi, processes: [], containers: [web, web])
        #expect(two.title == "Stop 2 containers on pi (port 3000)?")
        #expect(KillCommand().confirmation(for: [RunningProcess(pid: 1, name: "a")], on: pi).title == "Kill a on pi?")
    }
}
