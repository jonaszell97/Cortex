#if os(macOS)
import Foundation

/// A running container, as `docker ps` lists it.
public struct DockerContainer: Sendable, Equatable {
    public var id: String
    public var name: String
    public var image: String
    /// "0.0.0.0:8642->8080/tcp".
    public var ports: String

    public init(id: String, name: String, image: String, ports: String = "") {
        self.id = id
        self.name = name
        self.image = image
        self.ports = ports
    }

    /// A few lines for the preview and the alert.
    var details: String {
        var lines = ["Container \(name) (\(id))", "Image \(image)"]
        if !ports.isEmpty { lines.append(ports) }
        return lines.joined(separator: "\n")
    }
}

/// On a Mac, containers run in a VM, and a published port is held by the
/// container runtime's own process on the Mac. Killing that process would
/// stop the runtime and every container, so `$port` stops the container
/// instead. On a Linux host the port is held by `docker-proxy`, which runs as
/// root and is invisible without `sudo`, so the containers are always asked.
/// Both run `docker` on the machine the port is on.
enum Docker {
    /// The processes that forward published ports from the VM: Docker
    /// Desktop (`com.docker.backend`, formerly vpnkit), OrbStack, Lima
    /// (Colima, Rancher Desktop) and Podman.
    static let forwarderNames: Set<String> = [
        "com.docker.backend", "com.docker.vpnkit", "vpnkit-bridge", "OrbStack Helper", "limactl", "gvproxy",
    ]

    static func isForwarder(_ process: RunningProcess) -> Bool {
        forwarderNames.contains(process.name)
    }

    /// Why no container was looked up on a machine without `docker`.
    static let notInstalled = QuickActionError("the docker command is not installed")

    /// `docker ps`'s columns: ID, name, image, ports.
    static let format = "{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Ports}}"

    /// The running containers `docker ps` finds for `port` (also those with
    /// it as their own port, see `publishes`), as part of a script: the list
    /// under `@@ docker`, what `docker ps` said under `@@ dockererror` when it
    /// failed, or `@@ nodocker` without the command.
    static func lookupScript(port: Int) -> String {
        #"""
        if command -v docker >/dev/null 2>&1; then
          if containers=$(docker ps --filter publish=\#(port) --format '\#(format)' 2>&1); then
            echo '@@ docker'
          else
            echo '@@ dockererror'
          fi
          printf '%s\n' "$containers"
        else
          echo '@@ nodocker'
        fi
        """#
    }

    /// The containers `lookupScript` found in a script's sections that
    /// publish `port`; nil when it was not part of the script.
    static func lookup(in sections: [String: String], port: Int) -> Result<[DockerContainer], QuickActionError>? {
        if let output = sections["docker"] {
            return .success(parse(psOutput: output).filter { publishes($0.ports, hostPort: port) })
        }
        if let output = sections["dockererror"] {
            let reason = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return .failure(QuickActionError("docker ps failed: \(reason)"))
        }
        return sections["nodocker"] == nil ? nil : .failure(notInstalled)
    }

    /// The running containers that publish `port` on the machine.
    static func containers(publishing port: Int, on machine: Machine, shell: MachineShell) async throws -> [DockerContainer] {
        let output = try await shell(machine, ProcessTools.script(lookupScript(port: port)))
        guard let result = lookup(in: SSHHosts.sections(output), port: port) else {
            throw QuickActionError("docker gave no answer")
        }
        return try result.get()
    }

    /// Whether a Ports column publishes the host port `port`. `docker ps
    /// --filter publish=` also matches a container's own port, so a container
    /// that publishes 8080 on its 80 is not the one for port 80. Entries read
    /// `0.0.0.0:8642->80/tcp`, `[::]:8642->80/tcp` or `:::8642->80/tcp`, and
    /// `0.0.0.0:3000-3005->3000-3005/tcp` for a range; `80/tcp` alone is
    /// exposed, not published.
    static func publishes(_ ports: String, hostPort port: Int) -> Bool {
        ports.split(separator: ",").contains { entry in
            let parts = entry.split(separator: "->", omittingEmptySubsequences: false)
            guard parts.count == 2, let colon = parts[0].lastIndex(of: ":") else { return false }
            let host = parts[0][parts[0].index(after: colon)...].split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            switch host.count {
            case 1: return host[0] == port
            case 2: return host[0].flatMap { low in host[1].map { (low...max(low, $0)).contains(port) } } ?? false
            default: return false
            }
        }
    }

    /// Tab-separated `docker ps` output: ID, name, image, ports.
    static func parse(psOutput output: String) -> [DockerContainer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 3, !fields[0].isEmpty else { return nil }
            return DockerContainer(id: fields[0], name: fields[1], image: fields[2], ports: fields.count > 3 ? fields[3] : "")
        }
    }

    /// `docker stop`: the container's stop signal, then SIGKILL after `grace`.
    static func stopScript(_ containers: [DockerContainer], grace: Duration) -> String {
        let seconds = max(1, Int(grace.components.seconds))
        let ids = containers.map { ShellCommand.quote($0.id) }.joined(separator: " ")
        return ProcessTools.script(#"""
            command -v docker >/dev/null 2>&1 || { echo 'the docker command is not installed' >&2; exit 127; }
            docker stop --time \#(seconds) \#(ids) >/dev/null
            """#)
    }

    static func stop(_ containers: [DockerContainer], on machine: Machine, shell: MachineShell, grace: Duration) async throws {
        do {
            _ = try await shell(machine, stopScript(containers, grace: grace))
        } catch let error as QuickActionError {
            throw QuickActionError("docker stop failed: \(error.message)")
        }
    }
}
#endif
