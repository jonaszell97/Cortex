#if os(macOS)
import Foundation

/// What a host (or this Mac) runs, as `uname -s` names it.
public enum HostPlatform: Sendable, Equatable {
    case mac, linux

    init?(uname: String) {
        switch uname.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "Darwin": self = .mac
        case "Linux": self = .linux
        default: return nil
        }
    }

    /// "macOS".
    public var title: String {
        switch self {
        case .mac: "macOS"
        case .linux: "Linux"
        }
    }

    /// The error for a host that runs neither.
    static func unsupported(_ host: String, uname: String?) -> QuickActionError {
        let system = uname?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return QuickActionError("\(host) runs \(system.isEmpty ? "an unknown system" : system); only macOS and Linux hosts are read over SSH")
    }
}

/// The hosts `$mem @pi`, `$cpu`, `$gpu` and `$disk` read over SSH: the
/// aliases of `~/.ssh/config`. Only those are taken, so what is typed never becomes an
/// ssh option or an unknown host.
public enum SSHHosts {
    /// Git hosting takes SSH keys but runs no shell.
    static let gitHosts: Set<String> = ["github.com", "gitlab.com", "bitbucket.org", "ssh.dev.azure.com"]

    /// The aliases in `~/.ssh/config`, in its order.
    @Sendable public static func configured() -> [String] {
        let url = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".ssh/config")
        guard let config = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return aliases(config: config)
    }

    /// Every `Host` alias that names one host (no `*`, `?` or `!`), except
    /// those for git hosting (by alias or `HostName`).
    static func aliases(config: String) -> [String] {
        var aliases: [String] = []
        var block: [String] = []
        var hostName: String?
        func finish() {
            let hostNames = Set((block + [hostName].compactMap { $0 }).map { $0.lowercased() })
            if hostNames.isDisjoint(with: gitHosts) {
                aliases += block.filter { !aliases.contains($0) }
            }
            block = []
            hostName = nil
        }
        for line in config.split(whereSeparator: \.isNewline) {
            // `Keyword value…` or `Keyword=value…`.
            let line = line.drop { $0 == " " || $0 == "\t" }
            guard let end = line.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }), !line.hasPrefix("#") else { continue }
            var rest = line[end...].drop { $0 == " " || $0 == "\t" }
            if rest.first == "=" { rest = rest.dropFirst() }
            let values = rest.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            switch line[..<end].lowercased() {
            case "host":
                finish()
                block = values.filter { word in
                    !word.contains(where: { "*?!".contains($0) }) && !word.hasPrefix("-")
                }
            case "match":
                finish()
            case "hostname":
                hostName = values.first
            default:
                break
            }
        }
        finish()
        return aliases
    }

    /// Runs `script` with `sh` on `host` (whatever its login shell): never
    /// asks for a password and gives up after 5 seconds without a connection.
    @Sendable public static func run(_ host: String, script: String) async throws -> String {
        let result = try await ProcessRunner.run(
            URL(filePath: "/usr/bin/ssh"),
            arguments: ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-T", "--", host, "sh -c " + ShellCommand.quote(script)])
        guard result.status == 0 else {
            let summary = result.errorSummary(lines: 2)
            throw QuickActionError("\(host): " + (summary.isEmpty ? "ssh ended with status \(result.status)" : summary))
        }
        return result.outputText
    }

    /// Runs `script` with `sh` on this Mac, like `run` on a host (`Machine.run`
    /// picks one).
    static func runHere(_ script: String) async throws -> String {
        let result = try await ProcessRunner.run(URL(filePath: "/bin/sh"), arguments: ["-c", script])
        guard result.status == 0 else {
            throw QuickActionError(result.errorSummary(lines: 2).isEmpty ? "sh ended with status \(result.status)" : result.errorSummary(lines: 2))
        }
        return result.outputText
    }

    /// The parts of a script's output that starts each with a line
    /// `@@ name`, by name; what comes before the first is dropped.
    static func sections(_ output: String) -> [String: String] {
        var sections: [String: [Substring]] = [:]
        var current: String?
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@ ") {
                let name = line.dropFirst(3).trimmingCharacters(in: .whitespaces)
                current = name
                sections[name] = []
            } else if let current {
                sections[current, default: []].append(line)
            }
        }
        return sections.mapValues { $0.joined(separator: "\n").trimmingCharacters(in: .newlines) }
    }
}
#endif
