#if os(macOS)
import Darwin
import Foundation

/// A process a command offers to end.
public struct RunningProcess: Sendable, Equatable {
    public var pid: Int32
    /// The command name ("node").
    public var name: String
    public var user: String?
    /// For `$port`, its sockets on the port: "TCP *:3000", "UDP 127.0.0.1:3000".
    public var endpoints: [String]
    /// The full command line, if `ps` could read it.
    public var commandLine: String?

    public init(pid: Int32, name: String, user: String? = nil, endpoints: [String] = [], commandLine: String? = nil) {
        self.pid = pid
        self.name = name
        self.user = user
        self.endpoints = endpoints
        self.commandLine = commandLine
    }

    /// "node (PID 4242)".
    public var label: String {
        "\(name) (PID \(pid))"
    }

    /// A few lines for the preview and the alert.
    var details: String {
        var lines = [user.map { "\(label), \($0)" } ?? label]
        lines += endpoints
        if let commandLine {
            lines.append(commandLine.count > 300 ? String(commandLine.prefix(300)) + "…" : commandLine)
        }
        return lines.joined(separator: "\n")
    }
}

/// Listing the user's processes and ending them, for `$kill` and `$port`, on
/// this Mac or a host: everything runs as a POSIX `sh` script through a
/// `MachineShell` and is read by the same code, whichever machine answered.
enum ProcessTools {
    /// How many processes the preview and the alert describe one by one.
    static let detailLimit = 8

    /// `body` as a script of its own. It starts with a PATH that finds `lsof`,
    /// `ss` and `docker` on a host whose shell has a short one, then prints the
    /// system's name (`uname`) and the PIDs of the script's own shell and its
    /// parent, which are never offered.
    static func script(_ body: String) -> String {
        """
        PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/usr/sbin:/sbin:$HOME/.orbstack/bin:$HOME/.docker/bin"
        system=$(uname -s)
        echo '@@ system'; echo "$system"
        echo '@@ self'; echo "$$ $PPID"
        """ + "\n" + body
    }

    // MARK: - Listing

    /// Who the user is, every process with its owner and executable, and the
    /// command lines of the user's own: one connection.
    static let ownScript = script(#"""
        uid=$(id -u)
        echo '@@ uid'; echo "$uid"
        echo '@@ ps'; ps -A -o pid=,uid=,comm=
        echo '@@ commands'; ps -ww -A -o pid=,uid=,command= | grep -E "^ *[0-9]+ +$uid +" | sed -E 's/^ *([0-9]+) +[0-9]+ +/\1 /'
        true
        """#)

    /// The processes running as the user, with their command lines (as far as
    /// `ps` could read them), by PID. Cortex itself is left out on this Mac,
    /// and on a host the shell that ran the script.
    static func ownProcesses(on machine: Machine, shell: MachineShell) async throws -> [RunningProcess] {
        try ownProcesses(in: try await shell(machine, ownScript), on: machine)
    }

    /// `ownScript`'s output, read. `ps -x` would miss some processes
    /// (loginwindow), so all are listed and filtered by user ID.
    static func ownProcesses(in output: String, on machine: Machine) throws -> [RunningProcess] {
        let sections = SSHHosts.sections(output)
        try requireSupported(sections, on: machine)
        guard let uid = sections["uid"]?.trimmingCharacters(in: .whitespacesAndNewlines), !uid.isEmpty else {
            throw unavailable("id", on: machine)
        }
        guard let listing = sections["ps"], !listing.isEmpty else {
            throw unavailable("ps", on: machine)
        }
        let commandLines = parse(psOutput: sections["commands"] ?? "")
        let excluded = ownPIDs(sections, on: machine)
        return listing.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int32(fields[0]), fields[1] == uid, !excluded.contains(pid) else { return nil }
            // The command lines are read a moment later: a process missing
            // there has quit since (like the `ps` that listed them).
            guard commandLines.isEmpty || commandLines[pid] != nil else { return nil }
            return RunningProcess(pid: pid, name: name(ofExecutable: String(fields[2])), commandLine: commandLines[pid])
        }
        .sorted { $0.pid < $1.pid }
    }

    /// The executable's name: `ps` gives a path on a Mac (`/usr/bin/nc`), a
    /// bare name on Linux. The script compares with the same rule.
    static func name(ofExecutable comm: String) -> String {
        let path = comm.trimmingCharacters(in: .whitespaces)
        let name = path.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? path
        return name.isEmpty ? path : name
    }

    /// The system must be one of the two `HostPlatform`s.
    static func requireSupported(_ sections: [String: String], on machine: Machine) throws {
        guard HostPlatform(uname: sections["system"] ?? "") != nil else {
            throw HostPlatform.unsupported(machine.title, uname: sections["system"])
        }
    }

    /// "pi has no ps command", or "ps is not available" for this Mac.
    static func unavailable(_ tools: String, on machine: Machine) -> QuickActionError {
        QuickActionError(machine.alias.map { "\($0) has no \(tools) command" } ?? "\(tools) is not available")
    }

    /// The PIDs never offered: the script's shell and its parent, and Cortex on
    /// this Mac.
    static func ownPIDs(_ sections: [String: String], on machine: Machine) -> Set<Int32> {
        var pids = Set((sections["self"] ?? "").split(whereSeparator: \.isWhitespace).compactMap { Int32($0) })
        if machine == .local { pids.insert(getpid()) }
        return pids
    }

    /// `ps -o pid=,…=` output with one more column, by PID.
    static func parse(psOutput output: String) -> [Int32: String] {
        var values: [Int32: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.drop { $0 == " " }.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            values[pid] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return values
    }

    /// The processes, described one by one up to `detailLimit`.
    static func details(of processes: [RunningProcess]) -> String {
        var blocks = processes.prefix(detailLimit).map(\.details)
        if processes.count > detailLimit {
            blocks.append("and \(processes.count - detailLimit) more")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// "It gets SIGTERM, and SIGKILL if still running after 3 seconds."
    static func endingNote(count: Int, grace: Duration) -> String {
        let graceText = grace.formatted(.units(allowed: [.seconds, .milliseconds], width: .wide))
        return "\(count == 1 ? "It gets" : "They get") SIGTERM, and SIGKILL if still running after \(graceText)."
    }

    // MARK: - Ending

    /// What `endScript` printed: the PIDs by what became of them.
    struct Ending: Sendable, Equatable {
        /// Quit after SIGTERM.
        var ended: [Int32] = []
        /// Needed SIGKILL.
        var forced: [Int32] = []
        /// Could not be signalled: they belong to another user.
        var denied: [Int32] = []
        /// No longer running under that name when the script got to them.
        var gone: [Int32] = []

        /// One `ended 4242`, `forced 4242`, `denied 4242` or `gone 4242` per line.
        init(output: String) {
            for line in output.split(whereSeparator: \.isNewline) {
                let fields = line.split(separator: " ")
                guard fields.count == 2, let pid = Int32(fields[1]) else { continue }
                switch fields[0] {
                case "ended": ended.append(pid)
                case "forced": forced.append(pid)
                case "denied": denied.append(pid)
                case "gone": gone.append(pid)
                default: break
                }
            }
        }

        /// What happened, for the notification: "ended node (PID 4242) on port
        /// 3000", in lower case so it can follow other parts; `location` goes
        /// after the processes. nil when none of them was running any more.
        /// Throws when one could not be signalled; `host` is named then.
        func summary(of processes: [RunningProcess], location: String = "", host: String? = nil) throws -> String? {
            let handled = processes.filter { ended.contains($0.pid) || forced.contains($0.pid) }
            let refused = processes.filter { denied.contains($0.pid) }
            if !refused.isEmpty {
                let names = refused.map(\.label).joined(separator: ", ")
                throw QuickActionError("Not allowed to kill \(names)\(host.map { " on \($0)" } ?? ""): "
                    + (refused.count == 1 ? "it belongs" : "they belong") + " to another user"
                    + (handled.isEmpty ? "" : ". The others were ended"))
            }
            guard !handled.isEmpty else { return nil }
            let what = (handled.count == 1 ? handled[0].label : "\(handled.count) processes") + location
            if forced.isEmpty {
                return "ended \(what)"
            }
            if ended.isEmpty {
                return "force-killed \(what): \(handled.count == 1 ? "it" : "they") did not quit after SIGTERM"
            }
            return "ended \(what), \(forced.count) of them with SIGKILL"
        }
    }

    /// Sends SIGTERM to each process that still runs under the name it had
    /// when it was looked up (a PID may have been reused since), waits up to
    /// `grace` for them to exit, then sends SIGKILL to those still running
    /// under that name. Prints one line for each (`Ending`).
    static func endScript(_ processes: [RunningProcess], grace: Duration) -> String {
        let seconds = Double(grace.components.seconds) + Double(grace.components.attoseconds) / 1e18
        let ticks = max(1, Int((seconds * 10).rounded(.up)))
        // One call for each process; the PID is a number and the name quoted.
        let terms = processes.map { "term \($0.pid) \(ShellCommand.quote($0.name))" }.joined(separator: "\n")
        let forces = processes.map { "force \($0.pid) \(ShellCommand.quote($0.name))" }.joined(separator: "\n")
        return script(#"""
            named() {
              current=$(ps -o comm= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
              current=${current##*/}
              [ -n "$current" ] && [ "$current" = "$2" ]
            }
            pending=""
            term() {
              if ! named "$1" "$2"; then echo "gone $1"
              elif kill -TERM "$1" 2>/dev/null; then pending="$pending $1"
              elif named "$1" "$2"; then echo "denied $1"
              else echo "gone $1"
              fi
            }
            force() {
              case " $pending " in *" $1 "*) ;; *) return ;; esac
              if ! named "$1" "$2"; then echo "ended $1"
              elif kill -KILL "$1" 2>/dev/null; then echo "forced $1"
              else echo "denied $1"
              fi
            }
            echo '@@ ending'
            \#(terms)
            tick=0.1; ticks=\#(ticks)
            sleep "$tick" 2>/dev/null || { tick=1; ticks=$(( (ticks + 9) / 10 )); }
            while [ -n "$pending" ] && [ "$ticks" -gt 0 ]; do
              sleep "$tick"
              alive=""
              for pid in $pending; do
                if kill -0 "$pid" 2>/dev/null; then alive="$alive $pid"; else echo "ended $pid"; fi
              done
              pending=$alive
              ticks=$((ticks - 1))
            done
            \#(forces)
            true
            """#)
    }

    /// Ends `processes` on `machine`, as `endScript` does.
    static func end(_ processes: [RunningProcess], on machine: Machine, shell: MachineShell, grace: Duration) async throws -> Ending {
        let output = try await shell(machine, endScript(processes, grace: grace))
        return Ending(output: SSHHosts.sections(output)["ending"] ?? "")
    }
}

extension String {
    /// "ended node" → "Ended node".
    var uppercasingFirst: String {
        prefix(1).uppercased() + dropFirst()
    }
}
#endif
