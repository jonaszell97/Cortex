import Foundation

/// Where a command runs (docs/modules/COMMANDS.md, "Hosts"): this Mac, or a
/// host from `~/.ssh/config` by its alias. A command never matches aliases or
/// complains about an unknown host itself; the scope picks the machine from
/// the `@host` that was typed (`named(by:in:)`) and hands it in
/// `ActionContext.machine`.
public enum Machine: Sendable, Hashable {
    case local
    case ssh(String)

    /// "This Mac", or the host's alias.
    public var title: String {
        alias ?? "This Mac"
    }

    /// The host's alias; nil for this Mac.
    public var alias: String? {
        if case .ssh(let alias) = self { return alias }
        return nil
    }

    /// `what` for a pane or a card: "Memory Usage", or "Memory Usage on pi".
    public func describing(_ what: String) -> String {
        alias.map { "\(what) on \($0)" } ?? what
    }

    /// The machine the `@words` typed after a command's name mean
    /// (`CommandQuery.hosts`, without the `@`): this Mac for none, otherwise
    /// the one alias in `hosts` that they name, as `CommandChoices.match` reads
    /// it (ignoring case, or the only alias that starts with it). Anything
    /// else says why not, with the hosts to pick from; the text typed never
    /// becomes an ssh option or an unknown host.
    public static func named(by typed: [String], in hosts: [String]) throws -> Machine {
        guard let word = typed.first else { return .local }
        guard typed.count == 1 else {
            throw QuickActionError("One host at a time: " + typed.map { "@\($0)" }.joined(separator: " and "))
        }
        let choices = hosts.map { ActionOption.Choice($0, title: $0) }
        if let host = CommandChoices.match(word, in: choices) { return .ssh(host.value) }
        let started = CommandChoices.startingWith(word, in: choices)
        if started.count > 1 {
            throw QuickActionError("“@\(word)” could be " + started.map(\.title).joined(separator: ", ") + ": type more of the name")
        }
        throw QuickActionError("“@\(word)” is not a host in ~/.ssh/config." + (hosts.isEmpty ? "" : " Hosts: " + hosts.joined(separator: ", ")))
    }
}

#if os(macOS)
/// Runs a POSIX shell script on a machine and returns its standard output:
/// `Machine.shell` in the app, canned output in tests.
public typealias MachineShell = @Sendable (_ machine: Machine, _ script: String) async throws -> String

public extension Machine {
    /// Runs `script` with `sh` here, or on the host over SSH (`SSHHosts.run`:
    /// never asks for a password, gives up after 5 seconds without a
    /// connection), and returns what it printed.
    func run(_ script: String) async throws -> String {
        switch self {
        case .local: try await SSHHosts.runHere(script)
        case .ssh(let alias): try await SSHHosts.run(alias, script: script)
        }
    }

    /// `run` as a `MachineShell`: what the commands use unless a test hands
    /// them another.
    @Sendable static func shell(_ machine: Machine, _ script: String) async throws -> String {
        try await machine.run(script)
    }
}
#endif
