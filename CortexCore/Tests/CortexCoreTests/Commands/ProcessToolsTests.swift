import Foundation
import Testing
@testable import CortexCore

/// A shell for `$port` and `$kill` that answers the scripts of canned hosts and
/// remembers what it was asked.
final class CannedHosts: @unchecked Sendable {
    /// `host` is the alias, or "This Mac".
    typealias Answer = @Sendable (_ host: String, _ script: String) throws -> String

    private let lock = NSLock()
    private var asked: [(machine: Machine, script: String)] = []
    private let answer: Answer

    init(_ answer: @escaping Answer) {
        self.answer = answer
    }

    /// Every script that was run, in order.
    var scripts: [(machine: Machine, script: String)] { lock.withLock { asked } }

    var shell: MachineShell {
        { [self] machine, script in
            lock.withLock { asked.append((machine, script)) }
            return try answer(machine.title, script)
        }
    }
}

/// Reading and ending processes, whichever machine answers: canned output of a
/// Linux host (`pi`) and a Mac host (`mini`).
@Suite struct ProcessToolsTests {
    /// The user's processes on Linux: `ps -A -o pid=,uid=,comm=` shows
    /// everyone's, with the executable's bare name.
    static let linuxOwn = """
        @@ system
        Linux
        @@ self
        5001 5000
        @@ uid
        1000
        @@ ps
            1     0 systemd
          777     0 sshd
          812  1000 node
          813  1000 node
          900  1000 nodemon
         1200  1000 Web Content
         5000  1000 bash
         5001  1000 sh
         5002  1000 ps
        @@ commands
        812 node /srv/app/server.js --port 3000
        813 node /srv/other/worker.js
        900 nodemon app.js
        1200 /usr/lib/firefox/firefox -contentproc
        5000 bash -c sh -c '…'
        5001 sh -c …
        """

    /// The same on a Mac: `comm` is the path of the executable.
    static let macOwn = """
        @@ system
        Darwin
        @@ self
        6001 6000
        @@ uid
        501
        @@ ps
            1     0 /sbin/launchd
          310   501 /sbin/launchd
          311   501 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome
          312   501 /usr/local/bin/node
          400   502 /usr/local/bin/node
          6001  501 /bin/sh
        @@ commands
        310 /sbin/launchd
        311 /Applications/Google Chrome.app/Contents/MacOS/Google Chrome --flag
        312 node /Users/alex/app/server.js
        """

    @Test func onlyTheSshUsersProcessesAreListedWithoutTheScriptsOwnShell() throws {
        let processes = try ProcessTools.ownProcesses(in: Self.linuxOwn, on: .ssh("pi"))
        #expect(processes == [
            RunningProcess(pid: 812, name: "node", commandLine: "node /srv/app/server.js --port 3000"),
            RunningProcess(pid: 813, name: "node", commandLine: "node /srv/other/worker.js"),
            RunningProcess(pid: 900, name: "nodemon", commandLine: "nodemon app.js"),
            RunningProcess(pid: 1200, name: "Web Content", commandLine: "/usr/lib/firefox/firefox -contentproc"),
        ], "not root's, not the script's shell (5001) nor its parent's (5000), not the ps that has quit since (5002)")
    }

    @Test func aMacNamesProcessesByTheirExecutable() throws {
        let processes = try ProcessTools.ownProcesses(in: Self.macOwn, on: .ssh("mini"))
        #expect(processes.map(\.name) == ["launchd", "Google Chrome", "node"])
        #expect(processes.map(\.pid) == [310, 311, 312], "not uid 502's")
        #expect(processes[1].commandLine == "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome --flag")
    }

    @Test func cortexIsLeftOutOnThisMacOnly() throws {
        let own = "\(getpid())"
        let output = "@@ system\nDarwin\n@@ uid\n501\n@@ ps\n  \(own)   501 /Applications/Cortex.app/Contents/MacOS/Cortex\n  7  501 /bin/zsh\n"
        #expect(try ProcessTools.ownProcesses(in: output, on: .local).map(\.pid) == [7])
        #expect(try ProcessTools.ownProcesses(in: output, on: .ssh("mini")).map(\.pid) == [getpid(), 7].sorted(),
                "another Mac's process with that number is not Cortex")
    }

    @Test func aHostWithoutTheToolsOrAKnownSystemIsAnError() {
        #expect(throws: QuickActionError("pi runs FreeBSD; only macOS and Linux hosts are read over SSH")) {
            try ProcessTools.ownProcesses(in: "@@ system\nFreeBSD\n@@ uid\n1000\n@@ ps\n 1 0 init\n", on: .ssh("pi"))
        }
        #expect(throws: QuickActionError("pi has no ps command")) {
            try ProcessTools.ownProcesses(in: "@@ system\nLinux\n@@ uid\n1000\n@@ ps\n@@ commands\n", on: .ssh("pi"))
        }
        #expect(throws: QuickActionError("pi has no id command")) {
            try ProcessTools.ownProcesses(in: "@@ system\nLinux\n@@ uid\n\n@@ ps\n 1 0 init\n", on: .ssh("pi"))
        }
        #expect(throws: QuickActionError("ps is not available")) {
            try ProcessTools.ownProcesses(in: "@@ system\nDarwin\n@@ uid\n501\n@@ ps\n", on: .local)
        }
    }

    @Test func executableNames() {
        #expect(ProcessTools.name(ofExecutable: "/usr/bin/nc") == "nc")
        #expect(ProcessTools.name(ofExecutable: "node") == "node")
        #expect(ProcessTools.name(ofExecutable: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome ") == "Google Chrome")
        #expect(ProcessTools.name(ofExecutable: "-zsh") == "-zsh")
        #expect(ProcessTools.name(ofExecutable: "/") == "/")
    }

    // MARK: - Ending

    @Test func theEndingScriptHasOneCallPerProcessWithQuotedNames() {
        let script = ProcessTools.endScript(
            [RunningProcess(pid: 812, name: "node"), RunningProcess(pid: 1200, name: "it's; rm -rf ~")], grace: .seconds(3))
        #expect(script.contains("\nterm 812 'node'\n"))
        #expect(script.contains("\nterm 1200 'it'\\''s; rm -rf ~'\n"), "what was read never reaches the shell unquoted")
        #expect(script.contains("\nforce 812 'node'\n") && script.contains("ticks=30\n"))
        #expect(ProcessTools.endScript([], grace: .milliseconds(300)).contains("ticks=3\n"))
        #expect(ProcessTools.endScript([], grace: .milliseconds(10)).contains("ticks=1\n"))
        #expect(script.contains("kill -TERM") && script.contains("kill -KILL") && !script.contains("sudo"))
    }

    @Test func everyScriptIsValidShell() async throws {
        let scripts = [
            ProcessTools.ownScript,
            PortCommand.lookupScript(port: 3000),
            Docker.stopScript([DockerContainer(id: "880fb5d67454", name: "web", image: "nginx")], grace: .seconds(3)),
            ProcessTools.script(Docker.lookupScript(port: 8642)),
            ProcessTools.endScript(
                [RunningProcess(pid: 812, name: "node"), RunningProcess(pid: 9, name: "it's")], grace: .seconds(3)),
        ]
        for script in scripts {
            let result = try await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-n", "-c", script])
            #expect(result.status == 0, "\(result.errorSummary())\n\(script)")
        }
    }

    @Test func whatTheScriptPrintedBecomesTheNotification() throws {
        let node = RunningProcess(pid: 812, name: "node")
        let worker = RunningProcess(pid: 813, name: "node")
        let ending = ProcessTools.Ending(output: "ended 812\nforced 813\ndenied 900\ngone 1\nnonsense\nended x\n")
        #expect(ending == { var e = ProcessTools.Ending(output: ""); e.ended = [812]; e.forced = [813]; e.denied = [900]; e.gone = [1]; return e }())

        func summary(_ output: String, _ processes: [RunningProcess], host: String? = nil) throws -> String? {
            try ProcessTools.Ending(output: output).summary(of: processes, location: host.map { " on \($0)" } ?? "", host: host)
        }
        #expect(try summary("ended 812", [node]) == "ended node (PID 812)")
        #expect(try summary("ended 812", [node], host: "pi") == "ended node (PID 812) on pi")
        #expect(try summary("forced 812", [node]) == "force-killed node (PID 812): it did not quit after SIGTERM")
        #expect(try summary("forced 812\nforced 813", [node, worker]) == "force-killed 2 processes: they did not quit after SIGTERM")
        #expect(try summary("ended 812\nforced 813", [node, worker]) == "ended 2 processes, 1 of them with SIGKILL")
        #expect(try summary("gone 812", [node]) == nil, "already quit")
        #expect(try summary("ended 812\ngone 813", [node, worker]) == "ended node (PID 812)")
        #expect(throws: QuickActionError("Not allowed to kill node (PID 812) on pi: it belongs to another user")) {
            try summary("denied 812", [node], host: "pi")
        }
        #expect(throws: QuickActionError("Not allowed to kill node (PID 812), node (PID 813): they belong to another user. The others were ended")) {
            try summary("denied 812\ndenied 813\nended 900", [node, worker, RunningProcess(pid: 900, name: "x")])
        }
    }

    // MARK: - Real shell

    /// Starts `sleep` under the shell's `exec`, so the PID is the sleeper's.
    private func sleeper() throws -> Process {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        return process
    }

    @Test func thisMacEndsOnlyWhatStillRunsUnderTheSameName() async throws {
        let impostor = try sleeper()
        defer { impostor.terminate() }
        let sleeping = RunningProcess(pid: impostor.processIdentifier, name: "not-sleep")
        let ending = try await ProcessTools.end([sleeping], on: .local, shell: Machine.shell, grace: .milliseconds(300))
        #expect(ending.gone == [impostor.processIdentifier], "the PID now belongs to another program")
        #expect(impostor.isRunning, "so nothing is signalled")

        let real = RunningProcess(pid: impostor.processIdentifier, name: "sleep")
        let result = try await ProcessTools.end([real], on: .local, shell: Machine.shell, grace: .seconds(3))
        #expect(result.ended == [impostor.processIdentifier])
        impostor.waitUntilExit()
        #expect(impostor.terminationStatus == SIGTERM)
    }

    @Test func thisMacListsItsOwnProcessesThroughTheScript() async throws {
        let sleeping = try sleeper()
        defer { sleeping.terminate() }
        let processes = try await ProcessTools.ownProcesses(on: .local, shell: Machine.shell)
        let found = try #require(processes.first { $0.pid == sleeping.processIdentifier })
        #expect(found.name == "sleep" && found.commandLine == "/bin/sleep 60")
        #expect(!processes.contains { $0.pid == getpid() }, "Cortex is left out")
    }
}
