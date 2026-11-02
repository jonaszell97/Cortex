import Foundation
import Testing
@testable import CortexCore

/// Kill Process and Kill Process on Port: the built-in commands.
@Suite struct BuiltInCommandTests {
    @Test func namesAndArguments() throws {
        let port = PortCommand()
        #expect(port.name == "port")
        #expect(port.usage == "port 3000")
        #expect(!port.summary.isEmpty)
        let argument = try #require(port.argument)
        #expect(argument.title == "Port")
        #expect(argument.kind == .number(1...65_535))
        #expect(argument.isRequired)
        #expect(argument.suggestions == .clips(matching: "^:?[0-9]{1,5}$"))

        let kill = KillCommand()
        #expect(kill.name == "kill")
        #expect(kill.usage == "kill node")
        #expect(kill.argument?.kind == .text)
        #expect(kill.argument?.suggestions == CommandSuggestions.none, "a process name is never suggested")
    }

    @Test func onlyTheHostCommandsRunOnHosts() {
        let hosted = CommandCatalog.builtIns.filter(\.runsOnHosts).map(\.name)
        #expect(hosted == ["kill", "port", "disk", "mem", "cpu", "gpu"])
        #expect(CommandCatalog.builtIns.filter { $0.argument(on: .ssh("pi")) != $0.argument }.map(\.name) == ["disk"])
    }

    @Test func theyNeedTheirArgument() {
        let port = PortCommand()
        #expect(!port.accepts(.none), "⏎ opens the form instead")
        #expect(!port.accepts(.text("  ")))
        #expect(!port.accepts(.files([URL(filePath: "/tmp/a")])))
        #expect(port.accepts(.text("3000")))
        #expect(port.accepts(.text("abc")), "the preview says what is wrong")
        #expect(!KillCommand().accepts(.none))
        #expect(KillCommand().accepts(.text("node")))
    }

    @Test func typedTextIsTheirInput() {
        #expect(PortCommand().input(typed: " 3000 ") == .text("3000"))
        #expect(PortCommand().input(typed: nil) == .none)
        #expect(PortCommand().input(typed: "  ") == .none)
    }

    @Test func uuidTakesNothingAndMakesANewOneEachRun() async throws {
        let uuid = UUIDCommand()
        #expect(uuid.usage == "uuid")
        #expect(uuid.accepts(.none), "runs on ⏎ at once")
        #expect(!uuid.accepts(.text("x")))
        #expect(!uuid.matches(.none), "never offered in >")
        guard case .value(.text(let first), nil) = try await uuid.resolve(.none),
              case .value(.text(let second), nil) = try await uuid.resolve(.none) else { throw QuickActionError("not a plain value") }
        #expect(UUID(uuidString: first) != nil)
        #expect(first != second)
    }

    @Test func tokenTakesAnOptionalLength() async throws {
        let token = TokenCommand()
        #expect(token.usage == "token 32")
        #expect(token.accepts(.none), "runs on ⏎ at once")
        #expect(token.accepts(.text("64")))
        #expect(!token.matches(.text("64")), "never offered in >")
        #expect(try TokenCommand.length(of: .none) == 32)
        #expect(try TokenCommand.length(of: .text(" 64 ")) == 64)
        #expect(throws: QuickActionError.self) { try TokenCommand.length(of: .text("4")) }
        #expect(throws: QuickActionError.self) { try TokenCommand.length(of: .text("abc")) }

        guard case .value(.secret(let first), nil) = try await token.resolve(.none),
              case .value(.secret(let second), nil) = try await token.resolve(.none) else { throw QuickActionError("not a secret") }
        #expect(first.count == 32)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) })
        #expect(first != second)
    }

    @Test func tokenFormatsPickTheCharacters() async throws {
        let options = ActionOptionValues([TokenCommand.format.id: "hex"])
        let hex = try #require(try await TokenCommand().resolve(.text("100"), options: options).secret)
        #expect(hex.count == 100)
        #expect(hex.allSatisfy { "0123456789abcdef".contains($0) })

        // Every character of the alphabet turns up, and nothing else.
        let alphabet = TokenCommand.Format.urlSafe.alphabet
        #expect(alphabet.count == 64)
        var generator = SystemRandomNumberGenerator()
        let long = TokenCommand.token(length: 5_000, alphabet: alphabet, using: &generator)
        #expect(Set(long) == Set(alphabet))
    }

    @Test func killIsNeverOfferedInActions() {
        #expect(!KillCommand().matches(.text("node")))
    }

    @Test func portIsOfferedOnACopiedPortNumber() {
        let port = PortCommand()
        #expect(port.matches(.text("3000")))
        #expect(port.matches(.text(":8080\n")))
        #expect(!port.matches(.text("3000 4000")))
        #expect(!port.matches(.text("hello")))
        #expect(!port.matches(.none))
    }

    @Test func idsAndNamesAreUnique() {
        let ids = ActionCatalog.builtIns.map(\.id) + CommandCatalog.builtIns.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(CommandCatalog.builtIns.map(\.name) == ["kill", "port", "disk", "mem", "cpu", "gpu", "open", "code", "term", "clip", "sound", "uuid", "token"])
        #expect(CommandCatalog.builtIns.allSatisfy { $0.id.hasPrefix("command.") })
        #expect(CommandCatalog.problems(in: CommandCatalog.builtIns).isEmpty)
        #expect(!ActionCatalog.builtIns.contains { $0 is CommandAction }, "actions only")
    }
}

@Suite struct OpenCommandTests {
    let home = URL(filePath: "/Users/me")
    let existing: Set<String> = ["/tmp/a.txt", "/Users/me/My Folder", "/Users/me/Downloads"]

    func location(_ input: ActionInput) throws -> URL {
        let existing = existing
        return try OpenCommand.location(of: input, home: home) { existing.contains($0) }
    }

    @Test func nameAndArgument() throws {
        let open = OpenCommand()
        #expect(open.usage == "open ~/Downloads")
        let argument = try #require(open.argument)
        #expect(argument.kind == .path)
        #expect(argument.isRequired)
        #expect(argument.suggestions == .clips(matching: "^(/|~/)[^\\n]*$"))
    }

    @Test func findsTheOnePath() throws {
        #expect(try location(.text("/tmp/a.txt")) == URL(filePath: "/tmp/a.txt"))
        #expect(try location(.text(" ~/Downloads\n")) == URL(filePath: "/Users/me/Downloads"))
        #expect(try location(.text("~/My Folder")) == URL(filePath: "/Users/me/My Folder"), "a copied path, spaces unquoted")
        #expect(try location(.text("'/Users/me/My Folder'")) == URL(filePath: "/Users/me/My Folder"))
        #expect(try location(.files([URL(filePath: "/tmp/a.txt")])) == URL(filePath: "/tmp/a.txt"), "a copied file")
    }

    @Test func saysWhatIsWrong() {
        #expect(throws: QuickActionError("No file or folder at /tmp/missing")) { try location(.text("/tmp/missing")) }
        #expect(throws: QuickActionError("“Downloads” is not a path: start it with / or ~/")) { try location(.text("Downloads")) }
        #expect(throws: QuickActionError("Opens one file or folder at a time")) { try location(.text("/tmp/a.txt ~/Downloads")) }
        #expect(throws: QuickActionError("“gone.txt” is no longer there")) { try location(.files([URL(filePath: "/tmp/gone.txt")])) }
    }

    @Test func acceptsTextAndOneFile() {
        let open = OpenCommand()
        #expect(!open.accepts(.none), "⏎ opens the form instead")
        #expect(open.accepts(.text("Downloads")), "the preview says what is wrong")
        #expect(open.accepts(.files([URL(filePath: "/tmp")])))
        #expect(!open.accepts(.files([URL(filePath: "/tmp"), URL(filePath: "/usr")])))
        #expect(OpenCommand().input(typed: "/tmp") == .files([URL(filePath: "/tmp")]))
    }

    @Test func offeredOnACopiedPath() {
        let open = OpenCommand()
        #expect(open.matches(.text("/tmp\n")))
        #expect(open.matches(.files([URL(filePath: "/tmp")])))
        #expect(!open.matches(.text("/no/such/path")))
        #expect(!open.matches(.text("hello")))
        #expect(!open.matches(.none))
    }

    @Test func itRevealsIt() async throws {
        let context = try ActionContext.make(fallbackOutputDirectory: FileManager.default.temporaryDirectory)
        defer { context.removeTemporaryDirectory() }
        let folder = context.temporaryDirectory.path(percentEncoded: false)
        #expect(try await OpenCommand().resolve(.text(folder)) == .open(.reveal(URL(filePath: folder))))
        #expect(try await OpenCommand().output(.text(folder), context: context) == .reveal(URL(filePath: folder)))
    }
}

@Suite struct PortCommandTests {
    @Test func portNumbers() throws {
        #expect(try PortCommand.port(from: "3000") == 3000)
        #expect(try PortCommand.port(from: ":8080") == 8080)
        #expect(try PortCommand.port(from: " 1 ") == 1)
        for bad in ["", "abc", "0", "65536", "30 00", "-1"] {
            #expect(throws: QuickActionError.self, "\(bad)") { try PortCommand.port(from: bad) }
        }
        #expect(throws: QuickActionError("“http” is not a port number (1–65535)")) { try PortCommand.port(from: "http") }
    }

    @Test func parsesLsof() {
        let output = """
            p4242
            cnode
            Lalex
            f20
            PTCP
            n*:3000
            f21
            PTCP
            n[::1]:3000
            f22
            PTCP
            n*:3000
            p99
            cDNS Helper
            Lalex
            f5
            PUDP
            n192.168.1.2:51000->10.0.0.1:3000
            p100
            cudp-server
            f6
            PUDP
            n127.0.0.1:3000
            """
        let listeners = PortCommand.parse(lsofOutput: output, port: 3000)
        #expect(listeners == [
            RunningProcess(pid: 4242, name: "node", user: "alex", endpoints: ["TCP *:3000", "TCP [::1]:3000"]),
            RunningProcess(pid: 100, name: "udp-server", endpoints: ["UDP 127.0.0.1:3000"]),
        ], "a socket whose other end is the port does not count")
        #expect(PortCommand.parse(lsofOutput: "p1\ncx\nPTCP\nn*:30000", port: 3000).isEmpty, "the whole port, not a prefix")
        #expect(PortCommand.parse(lsofOutput: "", port: 3000).isEmpty)
    }

    @Test func parsesPs() {
        let output = "  162 /usr/local/bin/node  server.js --port 3000\n10018 /System/Library/ControlCenter\n"
        #expect(ProcessTools.parse(psOutput: output) == [
            162: "/usr/local/bin/node  server.js --port 3000",
            10018: "/System/Library/ControlCenter",
        ])
    }

    @Test func confirmationDescribesTheProcesses() {
        let command = PortCommand()
        let node = RunningProcess(pid: 1, name: "node", user: "alex", endpoints: ["TCP *:3000"], commandLine: "node server.js")
        let one = command.confirmation(port: 3000, processes: [node], containers: [])
        #expect(one.title == "Kill node?")
        #expect(one.confirmTitle == "Kill")
        #expect(one.message == "node (PID 1), alex\nTCP *:3000\nnode server.js\n\nIt gets SIGTERM, and SIGKILL if still running after 3 seconds.")

        let two = command.confirmation(
            port: 3000, processes: [node, RunningProcess(pid: 2, name: "python3", endpoints: ["UDP *:3000"])], containers: [])
        #expect(two.title == "Kill 2 processes on port 3000?")
        #expect(two.confirmTitle == "Kill 2 Processes")
        #expect(two.message.contains("\n\npython3 (PID 2)\nUDP *:3000\n\nThey get SIGTERM"))
    }

    // MARK: - Docker

    let backend = RunningProcess(pid: 10628, name: "com.docker.backend", user: "alex", endpoints: ["TCP *:8642"])
    let web = DockerContainer(id: "880fb5d67454", name: "web", image: "nginx:latest", ports: "0.0.0.0:8642->80/tcp")

    @Test func parsesDockerPs() {
        let output = "880fb5d67454\tweb\tnginx:latest\t0.0.0.0:8642->80/tcp, [::]:8642->80/tcp\ne72ae3f1f9df\tredis\tredis:7\t\n\n"
        #expect(Docker.parse(psOutput: output) == [
            DockerContainer(id: "880fb5d67454", name: "web", image: "nginx:latest", ports: "0.0.0.0:8642->80/tcp, [::]:8642->80/tcp"),
            DockerContainer(id: "e72ae3f1f9df", name: "redis", image: "redis:7"),
        ])
    }

    @Test func onlyAContainerPublishingTheHostPortIsTheOneForThePort() {
        let ports = "0.0.0.0:8080->80/tcp, [::]:8080->80/tcp"
        #expect(Docker.publishes(ports, hostPort: 8080))
        #expect(!Docker.publishes(ports, hostPort: 80), "docker ps --filter publish=80 also finds the container's own port")
        #expect(Docker.publishes(":::8642->8080/tcp", hostPort: 8642))
        #expect(Docker.publishes("127.0.0.1:5432->5432/tcp", hostPort: 5432))
        #expect(Docker.publishes("0.0.0.0:53->53/udp, 0.0.0.0:53->53/tcp", hostPort: 53))
        #expect(!Docker.publishes("0.0.0.0:8080->80/tcp, 0.0.0.0:8443->443/tcp", hostPort: 443))
        #expect(!Docker.publishes("8080/tcp", hostPort: 8080), "exposed, not published")
        #expect(!Docker.publishes("", hostPort: 80))
        #expect(!Docker.publishes("0.0.0.0:8080->80/tcp", hostPort: 808), "not a prefix")
    }

    @Test func aPublishedRangeIncludesItsPorts() {
        let ports = "0.0.0.0:3000-3005->3000-3005/tcp, [::]:3000-3005->3000-3005/tcp"
        #expect(Docker.publishes(ports, hostPort: 3000))
        #expect(Docker.publishes(ports, hostPort: 3003))
        #expect(Docker.publishes(ports, hostPort: 3005))
        #expect(!Docker.publishes(ports, hostPort: 2999))
        #expect(!Docker.publishes(ports, hostPort: 3006))
    }

    @Test func dockerPsContainersAreKeptByTheirHostPort() throws {
        let output = "880fb5d67454\tweb\tnginx:latest\t0.0.0.0:8080->80/tcp, [::]:8080->80/tcp\n"
            + "a1b2c3d4e5f6\tdb\tpostgres:16\t0.0.0.0:80->5432/tcp\n"
            + "e72ae3f1f9df\tredis\tredis:7\t6379/tcp\n"
        let sections = ["docker": output]
        func names(_ port: Int) throws -> [String]? {
            try Docker.lookup(in: sections, port: port)?.get().map(\.name)
        }
        #expect(try names(80) == ["db"], "not web, whose own port is 80")
        #expect(try names(8080) == ["web"])
        #expect(try names(6379) == [], "exposed only")
        #expect(try names(5432) == [])
    }

    @Test func aContainerIsStoppedInsteadOfTheRuntime() throws {
        let output = try PortCommand().outcome(port: 8642, listeners: [backend], containers: .success([web]))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(confirmation.title == "Stop container web?")
        #expect(confirmation.confirmTitle == "Stop Container")
        #expect(confirmation.message == """
            Container web (880fb5d67454)
            Image nginx:latest
            0.0.0.0:8642->80/tcp

            It gets SIGTERM, and SIGKILL if still running after 3 seconds.
            """)
        #expect(!confirmation.message.contains("com.docker.backend"))
    }

    @Test func theRuntimeIsNeverKilled() {
        #expect(throws: QuickActionError.notice("Port 8642 is held by com.docker.backend, which forwards it from containers, but no running container publishes it. Killing com.docker.backend would stop every container, so it is left alone.")) {
            try PortCommand().outcome(port: 8642, listeners: [backend], containers: .success([]))
        }
        #expect(throws: QuickActionError.notice("Port 8642 is held by com.docker.backend, which forwards it from containers, but no container could be looked up: the docker command is not installed. Killing com.docker.backend would stop every container, so it is left alone.")) {
            try PortCommand().outcome(port: 8642, listeners: [backend], containers: .failure(QuickActionError("the docker command is not installed")))
        }
    }

    @Test func containersAndProcessesTogether() throws {
        let node = RunningProcess(pid: 1, name: "node", endpoints: ["TCP [::1]:8642"])
        let output = try PortCommand().outcome(port: 8642, listeners: [backend, node], containers: .success([web]))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(confirmation.title == "Free port 8642?")
        #expect(confirmation.confirmTitle == "Stop and Kill")
        #expect(confirmation.message.hasPrefix("Container web (880fb5d67454)\nImage nginx:latest\n0.0.0.0:8642->80/tcp\n\nnode (PID 1)\nTCP [::1]:8642\n\nThey get"))

        let withoutContainers = try PortCommand().outcome(port: 8642, listeners: [backend, node], containers: .success([]))
        guard case .act(let processOnly) = withoutContainers else {
            Issue.record("expected a confirmation")
            return
        }
        #expect(processOnly.title == "Kill node?")
    }

    // MARK: - Real processes

    @Test func nothingListening() async throws {
        let port = try freePort()
        await #expect(throws: QuickActionError.notice("Nothing is listening on port \(port) (only your own processes are checked)")) {
            try await PortCommand().resolve(.text(String(port)))
        }
    }

    @Test func findsAndEndsAListener() async throws {
        let port = try freePort()
        let server = try await listen(on: port)
        defer { server.terminate() }

        let output = try await PortCommand().resolve(.text(String(port)))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(confirmation.title == "Kill nc?")
        #expect(confirmation.message.contains("nc (PID \(server.processIdentifier))"))
        #expect(confirmation.message.contains("TCP 127.0.0.1:\(port)"))
        #expect(confirmation.message.contains("/usr/bin/nc -d -l 127.0.0.1 \(port)"), "the command line from ps")
        #expect(server.isRunning, "looking up ends nothing")

        let result = try await confirmation.perform()
        #expect(result == .done("Ended nc (PID \(server.processIdentifier)) on port \(port)"))
        server.waitUntilExit()
        #expect(server.terminationReason == .uncaughtSignal)
        #expect(server.terminationStatus == SIGTERM)
    }

    @Test func killWithAColonIsPort() async throws {
        let port = try freePort()
        let server = try await listen(on: port)
        defer { server.terminate() }
        let output = try await KillCommand().resolve(.text(":\(port)"))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(confirmation.message.contains("TCP 127.0.0.1:\(port)"))
    }

    @Test func killsByNameNarrowedByTheCommandLine() async throws {
        let port = try freePort()
        let server = try await listen(on: port)
        defer { server.terminate() }

        let output = try await KillCommand().resolve(.text("nc \(port)"))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(confirmation.title == "Kill nc?")
        #expect(confirmation.message.hasPrefix("nc (PID \(server.processIdentifier))\n/usr/bin/nc -d -l 127.0.0.1 \(port)"))
        #expect(try await confirmation.perform() == .done("Ended nc (PID \(server.processIdentifier))"))
        server.waitUntilExit()
        #expect(server.terminationStatus == SIGTERM)

        // Confirming again: it is gone.
        #expect(try await confirmation.perform() == .done("nc (PID \(server.processIdentifier)) has already quit"))
    }

    @Test func killsByPID() async throws {
        let port = try freePort()
        let server = try await listen(on: port)
        defer { server.terminate() }
        let output = try await KillCommand().resolve(.text(String(server.processIdentifier)))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(confirmation.title == "Kill nc?")
    }

    @Test func killFindsNothingOrNothingAllowed() async throws {
        do {
            _ = try await KillCommand().resolve(.text("no-such-process-\(UUID().uuidString)"))
            Issue.record("expected an error")
        } catch let error as QuickActionError {
            #expect(error.message.hasPrefix("None of your processes is called “no-such-process-"))
            #expect(error.isNotice)
        }
        await #expect(throws: QuickActionError.notice("loginwindow is not offered: ending it logs you out")) {
            try await KillCommand().resolve(.text("loginwindow"))
        }
    }

    @Test func killsWhatIgnoresSIGTERM() async throws {
        let port = try freePort()
        // An ignored signal stays ignored across exec.
        let server = try await listen(on: port, shell: "trap '' TERM; exec /usr/bin/nc -d -l 127.0.0.1 \(port)")
        defer { server.terminate() }

        let output = try await PortCommand(grace: .milliseconds(300)).resolve(.text(String(port)))
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        let result = try await confirmation.perform()
        #expect(result == .done("Force-killed nc (PID \(server.processIdentifier)) on port \(port): it did not quit after SIGTERM"))
        server.waitUntilExit()
        #expect(server.terminationStatus == SIGKILL)
    }

    @Test func confirmingLateEndsOnlyWhatStillListens() async throws {
        let port = try freePort()
        let server = try await listen(on: port)
        let output = try await PortCommand().resolve(.text(String(port)))
        server.terminate()
        server.waitUntilExit()
        guard case .act(let confirmation) = output else {
            Issue.record("expected a confirmation, got \(output)")
            return
        }
        #expect(try await confirmation.perform() == .done("Nothing is listening on port \(port) any more"))
    }

    /// A port nothing listens on.
    private func freePort() throws -> Int {
        for _ in 0..<20 {
            let port = Int.random(in: 49_152...65_000)
            let probe = Process()
            probe.executableURL = URL(filePath: "/usr/sbin/lsof")
            probe.arguments = ["-nP", "-i:\(port)"]
            probe.standardOutput = FileHandle.nullDevice
            probe.standardError = FileHandle.nullDevice
            try probe.run()
            probe.waitUntilExit()
            if probe.terminationStatus == 1 { return port }
        }
        throw QuickActionError("no free port")
    }

    /// Starts `nc` listening on `port` (optionally through a shell command)
    /// and waits until it does.
    private func listen(on port: Int, shell: String? = nil) async throws -> Process {
        let process = Process()
        if let shell {
            process.executableURL = URL(filePath: "/bin/sh")
            process.arguments = ["-c", shell]
        } else {
            process.executableURL = URL(filePath: "/usr/bin/nc")
            process.arguments = ["-d", "-l", "127.0.0.1", String(port)]
        }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<50 {
            if try await !PortCommand.listeners(on: port).isEmpty { return process }
            try await Task.sleep(for: .milliseconds(50))
        }
        process.terminate()
        throw QuickActionError("nc did not start listening on \(port)")
    }
}

@Suite struct KillCommandTests {
    let processes = [
        RunningProcess(pid: 1, name: "node", commandLine: "node /app/server.js --port 3000"),
        RunningProcess(pid: 2, name: "node", commandLine: "node /Users/x/.vscode-server/server.bundle.js"),
        RunningProcess(pid: 3, name: "nodemon", commandLine: "nodemon app.js"),
        RunningProcess(pid: 4, name: "Google Chrome", commandLine: "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
        RunningProcess(pid: 5, name: "Google Chrome Helper", commandLine: "Google Chrome Helper --type=renderer"),
    ]

    func select(_ argument: String) -> [Int32] {
        KillCommand.select(argument, from: processes).map(\.pid)
    }

    @Test func exactNamesWin() {
        #expect(select("node") == [1, 2], "not nodemon")
        #expect(select("NODE") == [1, 2])
        #expect(select("nod") == [1, 2, 3], "without an exact name, every name containing it")
        #expect(select("google chrome") == [4])
        #expect(select("chrome") == [4, 5])
    }

    @Test func moreWordsNarrowByTheCommandLine() {
        #expect(select("node server.js") == [1])
        #expect(select("node 3000 app") == [1])
        #expect(select("node nothing").isEmpty)
    }

    @Test func numbersArePIDs() {
        #expect(select("3") == [3])
        #expect(select("42").isEmpty)
    }

    @Test func confirmationListsAtMostEight() {
        let many = (1...10).map { RunningProcess(pid: Int32($0), name: "worker") }
        let confirmation = KillCommand().confirmation(for: many)
        #expect(confirmation.title == "Kill 10 processes?")
        #expect(confirmation.confirmTitle == "Kill 10 Processes")
        #expect(confirmation.message.contains("worker (PID 8)\n\nand 2 more\n\nThey get SIGTERM"))
        #expect(!confirmation.message.contains("PID 9"))
    }

    @Test func killingTheContainerRuntimeWarns() {
        let backend = RunningProcess(pid: 7, name: "com.docker.backend")
        let message = KillCommand().confirmation(for: [backend]).message
        #expect(message.hasPrefix("com.docker.backend runs the containers: killing it stops all of them. To stop one container, use $port with its port.\n\ncom.docker.backend (PID 7)"))
        #expect(!KillCommand().confirmation(for: [processes[0]]).message.contains("containers"))
    }
}
