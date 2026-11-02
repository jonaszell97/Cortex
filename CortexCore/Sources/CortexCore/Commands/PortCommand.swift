#if os(macOS)
import Foundation

/// `$port 3000`: shows what is listening on a port and, once confirmed,
/// ends it: SIGTERM first, SIGKILL if it is still running after a grace
/// period. `$port 3000 @pi` does the same on a host from `~/.ssh/config`.
/// Only TCP listeners and UDP sockets bound to the port count, never
/// clients connected to it (a browser showing localhost:3000). Only the
/// user's own processes are seen (`lsof` on a Mac, `ss` on Linux). A port
/// published by a container is held by the container runtime (`Docker`):
/// then the container is stopped instead, and the runtime is never killed.
/// `>` also offers it on a port number copied to the clipboard. Nothing to
/// end (nothing listening, only a container runtime) is a notice, not an error.
public struct PortCommand: Command {
    public let id = "command.port"
    public let name = "port"
    public let title = "Kill Process on Port"
    public let summary = "Ends what listens on a port: TCP listeners and UDP sockets, or the container publishing it. On this Mac or a host over SSH."
    public let symbol = "network.slash"
    public let keywords = ["port", "kill", "process", "listening", "lsof", "quit", "end", "docker", "container", "ssh", "server"]
    /// Typed as any text: one that is not a port is the preview's error.
    public let argument: CommandArgument? = CommandArgument(
        title: "Port", placeholder: "3000", kind: .number(1...65_535), suggestions: .clips(matching: portPattern))
    /// A copied port number: `3000` or `:3000`.
    static let portPattern = "^:?[0-9]{1,5}$"
    /// How long a process or container has to quit after SIGTERM.
    let grace: Duration
    /// Runs the scripts on the machine.
    let shell: MachineShell

    public init(grace: Duration = .seconds(3), shell: @escaping MachineShell = Machine.shell) {
        self.grace = grace
        self.shell = shell
    }

    public var runsOnHosts: Bool { true }

    /// A port number on the clipboard: `>` offers it there (always on this Mac).
    public func matches(_ input: ActionInput) -> Bool {
        guard let text = input.text else { return false }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).wholeMatch(of: /:?[0-9]{1,5}/) != nil
    }

    /// Looking up is quick and changes nothing: only the confirmed step ends
    /// anything.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let port = try Self.port(from: invocation.input.text ?? "")
        let machine = invocation.machine
        let found = try await Self.lookup(port: port, on: machine, shell: shell)
        var containers = found.containers
        // On a Mac, only a container runtime holding the port means containers.
        if containers == nil, found.listeners.contains(where: Docker.isForwarder) {
            do {
                containers = .success(try await Docker.containers(publishing: port, on: machine, shell: shell))
            } catch let error as QuickActionError {
                containers = .failure(error)
            }
        }
        return try outcome(port: port, machine: machine, listeners: found.listeners, containers: containers ?? .success([]))
    }

    /// What to ask, or why nothing is offered: a container runtime's own
    /// process is left out, and its containers on the port are offered
    /// instead.
    func outcome(
        port: Int, machine: Machine = .local, listeners: [RunningProcess], containers: Result<[DockerContainer], QuickActionError>
    ) throws -> CommandOutcome {
        let runtimes = listeners.filter(Docker.isForwarder)
        let processes = listeners.filter { !Docker.isForwarder($0) }
        let found = (try? containers.get()) ?? []
        let host = machine.alias.map { " on \($0)" } ?? ""
        if listeners.isEmpty, found.isEmpty {
            var message = "Nothing is listening on port \(port)\(host) (only your own processes are checked)"
            if case .failure(let error) = containers, error != Docker.notInstalled {
                message += ". Looking for a container failed: \(error.message)"
            }
            throw QuickActionError.notice(message)
        }
        if processes.isEmpty, found.isEmpty {
            let names = runtimes.map(\.name).joined(separator: ", ")
            let why = switch containers {
            case .failure(let error): "no container could be looked up: \(error.message)"
            case .success: "no running container publishes it"
            }
            throw QuickActionError.notice("Port \(port)\(host) is held by \(names), which forwards it from containers, but \(why). "
                + "Killing \(names) would stop every container, so it is left alone.")
        }
        return .act(confirmation(port: port, machine: machine, processes: processes, containers: found))
    }

    func confirmation(
        port: Int, machine: Machine = .local, processes: [RunningProcess], containers: [DockerContainer]
    ) -> ActionConfirmation {
        let host = machine.alias.map { " on \($0)" } ?? ""
        // "on port 3000", or "on pi (port 3000)".
        let location = machine.alias.map { " on \($0) (port \(port))" } ?? " on port \(port)"
        let (title, confirmTitle) = switch (processes.count, containers.count) {
        case (1, 0): ("Kill \(processes[0].name)\(host)?", "Kill")
        case (_, 0): ("Kill \(processes.count) processes\(location)?", "Kill \(processes.count) Processes")
        case (0, 1): ("Stop container \(containers[0].name)\(host)?", "Stop Container")
        case (0, _): ("Stop \(containers.count) containers\(location)?", "Stop \(containers.count) Containers")
        default: ("Free port \(port)\(host)?", "Stop and Kill")
        }
        var blocks = containers.map(\.details)
        if !processes.isEmpty { blocks.append(ProcessTools.details(of: processes)) }
        blocks.append(ProcessTools.endingNote(count: processes.count + containers.count, grace: grace))
        return ActionConfirmation(title: title, message: blocks.joined(separator: "\n\n"), confirmTitle: confirmTitle) { [grace, shell] in
            // On the machine the lookup ran on. A PID may have been reused
            // since the lookup: the script ends only what still runs under
            // the same name. Container IDs are never reused.
            if !containers.isEmpty {
                try await Docker.stop(containers, on: machine, shell: shell, grace: grace)
            }
            var ended: String?
            if !processes.isEmpty {
                let ending = try await ProcessTools.end(processes, on: machine, shell: shell, grace: grace)
                ended = try ending.summary(of: processes, location: location, host: machine.alias)
            }
            var parts: [String] = []
            if !containers.isEmpty {
                parts.append((containers.count == 1 ? "stopped container \(containers[0].name)" : "stopped \(containers.count) containers")
                    + (ended == nil ? location : ""))
            }
            if let ended { parts.append(ended) }
            guard !parts.isEmpty else {
                return .done("Nothing is listening on port \(port)\(host) any more")
            }
            return .done(parts.joined(separator: " and ").uppercasingFirst)
        }
    }

    // MARK: - Port

    /// `3000` or `:3000`.
    static func port(from text: String) throws -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.hasPrefix(":") ? trimmed.dropFirst() : Substring(trimmed)
        guard digits.allSatisfy(\.isASCII), let port = Int(digits), (1...65_535).contains(port) else {
            throw QuickActionError("“\(trimmed)” is not a port number (1–65535)")
        }
        return port
    }

    // MARK: - Looking up

    /// What the lookup script found.
    struct Lookup {
        /// Without Cortex itself on this Mac.
        var listeners: [RunningProcess]
        /// The containers, when the script asked `docker` (always on Linux);
        /// nil when it did not.
        var containers: Result<[DockerContainer], QuickActionError>?
    }

    /// Finds what listens on `port`: `ss` on Linux (`lsof` when it is
    /// missing), `lsof` on a Mac, then the names and command lines of those
    /// processes, and on Linux the containers publishing the port.
    static func lookupScript(port: Int) -> String {
        ProcessTools.script(#"""
            if [ "$system" = Linux ] && command -v ss >/dev/null 2>&1 && found=$(ss -Hlntup 'sport = :\#(port)' 2>/dev/null); then
              echo '@@ ss'; printf '%s\n' "$found"
            elif command -v lsof >/dev/null 2>&1; then
              # -n -P: no name lookups; +c 0: the full command name.
              found=$(lsof -nP +c 0 -iTCP:\#(port) -sTCP:LISTEN -iUDP:\#(port) -FpcLPn 2>/dev/null)
              echo '@@ lsof'; printf '%s\n' "$found"
            else
              echo '@@ nolisteners'
            fi
            pids=$(printf '%s\n' "$found" | grep -oE '^p[0-9]+|pid=[0-9]+' | grep -oE '[0-9]+' | sort -u | tr '\n' ' ')
            if [ -n "$pids" ]; then
              list=$(echo $pids | tr ' ' ,)
              echo '@@ names'; ps -o pid=,comm= -p "$list" 2>/dev/null
              echo '@@ commands'; ps -ww -o pid=,command= -p "$list" 2>/dev/null
            fi
            if [ "$system" = Linux ]; then
            \#(Docker.lookupScript(port: port))
            fi
            true
            """#)
    }

    /// The processes listening on `port` of the machine, with their command
    /// lines.
    static func listeners(on port: Int, machine: Machine = .local, shell: MachineShell = Machine.shell) async throws -> [RunningProcess] {
        try await lookup(port: port, on: machine, shell: shell).listeners
    }

    static func lookup(port: Int, on machine: Machine, shell: MachineShell) async throws -> Lookup {
        try lookup(in: try await shell(machine, lookupScript(port: port)), port: port, on: machine)
    }

    /// `lookupScript`'s output, read.
    static func lookup(in output: String, port: Int, on machine: Machine) throws -> Lookup {
        let sections = SSHHosts.sections(output)
        try ProcessTools.requireSupported(sections, on: machine)
        var listeners: [RunningProcess]
        if let ss = sections["ss"] {
            listeners = parse(ssOutput: ss, port: port)
        } else if let lsof = sections["lsof"] {
            listeners = parse(lsofOutput: lsof, port: port)
        } else {
            let linux = HostPlatform(uname: sections["system"] ?? "") == .linux
            throw ProcessTools.unavailable(linux ? "ss or lsof" : "lsof", on: machine)
        }
        // Their executable's name as `ps` gives it, which the script compares
        // when it ends them.
        let names = ProcessTools.parse(psOutput: sections["names"] ?? "")
        let commandLines = ProcessTools.parse(psOutput: sections["commands"] ?? "")
        let excluded = ProcessTools.ownPIDs(sections, on: machine)
        listeners = listeners.filter { !excluded.contains($0.pid) }.map { listener in
            var listener = listener
            if let name = names[listener.pid] { listener.name = ProcessTools.name(ofExecutable: name) }
            listener.commandLine = commandLines[listener.pid]
            return listener
        }
        return Lookup(listeners: listeners, containers: Docker.lookup(in: sections, port: port))
    }

    /// `lsof -F pcLPn` output: a `p` line starts a process, `c` and `L` name
    /// it and its user, then each socket has a `P` (protocol) and an `n`
    /// (address) line.
    static func parse(lsofOutput output: String, port: Int) -> [RunningProcess] {
        var listeners: [RunningProcess] = []
        var protocolName = ""
        for line in output.split(whereSeparator: \.isNewline) {
            guard let field = line.first else { continue }
            let value = String(line.dropFirst())
            if field == "p" {
                if let pid = Int32(value) { listeners.append(RunningProcess(pid: pid, name: "PID \(pid)")) }
                protocolName = ""
                continue
            }
            guard !listeners.isEmpty else { continue }
            switch field {
            case "c" where !value.isEmpty:
                listeners[listeners.count - 1].name = value
            case "L":
                listeners[listeners.count - 1].user = value
            case "P":
                protocolName = value
            case "n":
                // A UDP socket matches by either end; only the local one counts.
                let local = value.components(separatedBy: "->")[0]
                let endpoint = "\(protocolName) \(local)"
                if local.hasSuffix(":\(port)"), !listeners[listeners.count - 1].endpoints.contains(endpoint) {
                    listeners[listeners.count - 1].endpoints.append(endpoint)
                }
            default:
                break
            }
        }
        return listeners.filter { !$0.endpoints.isEmpty }
    }

    /// `ss -Hlntup` output, one socket a line: protocol, state, queues, local
    /// and peer address, then `users:(("node",pid=1234,fd=20))` for the
    /// processes of the user (none for a socket of another user's).
    static func parse(ssOutput output: String, port: Int) -> [RunningProcess] {
        var listeners: [RunningProcess] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 5, fields[0].hasPrefix("tcp") || fields[0].hasPrefix("udp"), fields[4].hasSuffix(":\(port)"),
                  let users = line.range(of: "users:(") else { continue }
            let endpoint = "\(fields[0].prefix(3).uppercased()) \(fields[4])"
            for match in line[users.upperBound...].matches(of: /\("(.*?)",pid=([0-9]+)/) {
                guard let pid = Int32(match.2) else { continue }
                if let index = listeners.firstIndex(where: { $0.pid == pid }) {
                    if !listeners[index].endpoints.contains(endpoint) { listeners[index].endpoints.append(endpoint) }
                } else {
                    listeners.append(RunningProcess(pid: pid, name: String(match.1), endpoints: [endpoint]))
                }
            }
        }
        return listeners
    }
}
#endif
