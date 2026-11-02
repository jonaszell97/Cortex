#if os(macOS)
import Foundation

/// `$kill node`: ends the user's own processes by name, once confirmed:
/// SIGTERM first, SIGKILL if still running after a grace period.
/// `$kill 4242` ends a PID, and `$kill :3000` is `$port 3000`.
/// `$kill node @pi` does the same on a host from `~/.ssh/config`: only the
/// SSH user's own processes, never with `sudo`. Only ever runs on what is
/// typed, never on the clipboard. No process to end is a notice, not an error.
///
/// The argument is first matched against the whole process name; if that
/// finds nothing, its first word picks the name and the other words must
/// appear in the command line (`$kill node server.js`). An exact name
/// (ignoring case) wins over names that only contain it, so `$kill node`
/// leaves `nodemon` alone, while `$kill nod` finds both.
public struct KillCommand: Command {
    public let id = "command.kill"
    public let name = "kill"
    public let title = "Kill Process"
    public let summary = "Ends your processes by name or PID, once confirmed. On this Mac or a host over SSH."
    public let symbol = "xmark.circle"
    public let keywords = ["kill", "quit", "end", "process", "pkill", "pid", "force", "ssh", "server"]
    /// A name, a PID or `:port`; nothing to suggest.
    public let argument: CommandArgument? = CommandArgument(title: "Process", placeholder: "node")
    /// How long a process has to quit after SIGTERM.
    let grace: Duration
    /// Runs the scripts on the machine.
    let shell: MachineShell

    /// Ending these logs the user out, or over SSH locks them out of the
    /// host, and why.
    static let protectedNames: [String: String] = [
        "loginwindow": "ending it logs you out",
        "launchd": "ending it logs you out",
        "systemd": "ending it logs you out",
        "sshd": "ending it can lock you out of the host",
    ]

    /// Why `process` is never offered, if it is not: by its name, and PID 1
    /// whatever it is called (`init`, `systemd`, `launchd`).
    static func protection(of process: RunningProcess) -> String? {
        if process.pid == 1 { return "it is the first process, and ending it takes the system down" }
        return protectedNames[process.name]
    }

    public init(grace: Duration = .seconds(3), shell: @escaping MachineShell = Machine.shell) {
        self.grace = grace
        self.shell = shell
    }

    public var runsOnHosts: Bool { true }

    /// Looking up is quick and changes nothing: only the confirmed step ends
    /// anything.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let argument = (invocation.input.text ?? "").trimmingCharacters(in: .whitespaces)
        if argument.hasPrefix(":") {
            return try await PortCommand(grace: grace, shell: shell).resolve(invocation)
        }
        let machine = invocation.machine
        let processes = try await ProcessTools.ownProcesses(on: machine, shell: shell)
        let matches = Self.select(argument, from: processes)
        let allowed = matches.filter { Self.protection(of: $0) == nil }
        let host = machine.alias.map { " on \($0)" } ?? ""
        guard !allowed.isEmpty else {
            if let protected = matches.first, let reason = Self.protection(of: protected) {
                throw QuickActionError.notice("\(protected.name) is not offered: \(reason)")
            }
            throw QuickActionError.notice(Int32(argument) != nil
                ? "None of your processes\(host) has PID \(argument)"
                : "None of your processes\(host) is called “\(argument)”")
        }
        return .act(confirmation(for: allowed, on: machine))
    }

    /// The processes `argument` means. The processes need their command
    /// lines for the narrowing words.
    static func select(_ argument: String, from processes: [RunningProcess]) -> [RunningProcess] {
        if let pid = Int32(argument) {
            return processes.filter { $0.pid == pid }
        }
        func named(_ text: String) -> [RunningProcess] {
            let exact = processes.filter { $0.name.lowercased() == text }
            return exact.isEmpty ? processes.filter { $0.name.lowercased().contains(text) } : exact
        }
        let words = argument.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard let first = words.first else { return [] }
        let byWholeName = named(words.joined(separator: " "))
        guard byWholeName.isEmpty, words.count > 1 else { return byWholeName }
        return named(first).filter { process in
            let commandLine = process.commandLine?.lowercased() ?? ""
            return words.dropFirst().allSatisfy(commandLine.contains)
        }
    }

    func confirmation(for processes: [RunningProcess], on machine: Machine = .local) -> ActionConfirmation {
        let single = processes.count == 1
        let host = machine.alias.map { " on \($0)" } ?? ""
        var blocks = [ProcessTools.details(of: processes), ProcessTools.endingNote(count: processes.count, grace: grace)]
        if let runtime = processes.first(where: Docker.isForwarder) {
            blocks.insert("\(runtime.name) runs the containers: killing it stops all of them. "
                + "To stop one container, use $port with its port.", at: 0)
        }
        let message = blocks.joined(separator: "\n\n")
        return ActionConfirmation(
            title: single ? "Kill \(processes[0].name)\(host)?" : "Kill \(processes.count) processes\(host)?",
            message: message,
            confirmTitle: single ? "Kill" : "Kill \(processes.count) Processes"
        ) { [grace, shell] in
            // On the machine the lookup ran on. A PID may have been reused
            // since the lookup: the script ends only processes still running
            // under the same name.
            let ending = try await ProcessTools.end(processes, on: machine, shell: shell, grace: grace)
            guard let ended = try ending.summary(of: processes, location: host, host: machine.alias) else {
                return .done((single ? "\(processes[0].label) has already quit" : "They have already quit") + host)
            }
            return .done(ended.uppercasingFirst)
        }
    }
}
#endif
