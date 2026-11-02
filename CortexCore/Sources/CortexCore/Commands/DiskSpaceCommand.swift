#if os(macOS)
import Foundation

/// A mounted volume and its space, as `$disk` shows it.
public struct VolumeSpace: Sendable, Equatable {
    /// "Macintosh HD"; a host's alias for a host's file system.
    public var name: String
    /// nil on this Mac; otherwise the `~/.ssh/config` alias it was read from.
    public var host: String?
    /// Where it is mounted, without a trailing slash: "/", "/Volumes/Backup".
    public var path: String
    /// "APFS", "ExFAT".
    public var fileSystem: String?
    public var total: Int64
    /// Free right now.
    public var available: Int64
    /// Free once macOS purges what it can (caches, local snapshots), as
    /// Finder counts it; nil when the volume does not say.
    public var availableForImportantUsage: Int64?

    public init(
        name: String, host: String? = nil, path: String, fileSystem: String? = nil, total: Int64, available: Int64,
        availableForImportantUsage: Int64? = nil
    ) {
        self.name = name
        self.host = host
        self.path = path
        self.fileSystem = fileSystem
        self.total = total
        self.available = available
        self.availableForImportantUsage = availableForImportantUsage
    }

    public var used: Int64 { max(total - available, 0) }
    /// What macOS frees when space is needed.
    public var purgeable: Int64 { max((availableForImportantUsage ?? available) - available, 0) }
}

/// `$disk Macintosh HD`: how full a volume is, as a short table to
/// paste; the pane draws it from the `VolumeSpace`. The volume is picked
/// from the mounted ones (the startup volume first, and for no argument), by
/// name or mount point. `$disk @raspberrypi` reads a host from
/// `~/.ssh/config` (macOS or Linux) over SSH with `df`: its root file system,
/// or with an absolute path (`$disk /mnt/usb @raspberrypi`) the one that
/// path is on.
public struct DiskSpaceCommand: Command {
    public let id = "command.diskspace"
    public let name = "disk"
    public let title = "Disk Space"
    public let summary = "Shows how full a volume is, or a host's disk over SSH: total, used, free and purgeable space."
    public let symbol = "internaldrive"
    public let keywords = ["disk", "space", "free", "storage", "volume", "drive", "df", "full", "ssh", "server"]
    /// The mounted volumes, looked up when the form opens and on every run.
    let volumes: @Sendable () -> [VolumeSpace]
    let shell: MachineShell

    public init(
        volumes: @escaping @Sendable () -> [VolumeSpace] = DiskSpaceCommand.mountedVolumes,
        shell: @escaping MachineShell = Machine.shell
    ) {
        self.volumes = volumes
        self.shell = shell
    }

    public var runsOnHosts: Bool { true }

    /// A mounted volume, or none for the startup volume.
    public var argument: CommandArgument? {
        let volumes = volumes
        return CommandArgument(
            title: "Volume", placeholder: "Macintosh HD",
            kind: .choice(CommandChoices(id: "volumes") { Self.choices(volumes()) }), isRequired: false, suggestions: .choices)
    }

    /// An absolute path on a host, or none for its root file system.
    public func argument(on machine: Machine) -> CommandArgument? {
        guard machine != .local else { return argument }
        return CommandArgument(title: "Path", placeholder: "/mnt/usb", kind: .text, isRequired: false)
    }

    /// Reading the sizes is quick and changes nothing: the palette shows it.
    /// Sizes change slowly, so it is not refreshed.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let text = (invocation.input.text ?? "").trimmingCharacters(in: .whitespaces)
        let volume: VolumeSpace
        switch invocation.machine {
        case .local:
            let volumes = volumes()
            if text.isEmpty {
                guard let startup = volumes.first(where: { $0.path == "/" }) ?? volumes.first else {
                    throw QuickActionError("No volume is mounted")
                }
                volume = startup
            } else if let choice = CommandChoices.match(text, in: Self.choices(volumes)),
                      let mounted = volumes.first(where: { $0.path == choice.value }) {
                volume = mounted
            } else {
                throw QuickActionError("“\(text)” is not a mounted volume. Mounted: " + volumes.map(\.name).joined(separator: ", "))
            }
        case .ssh(let host):
            let path = text.isEmpty ? "/" : text
            guard path.hasPrefix("/") else {
                throw QuickActionError("“\(text)” is not an absolute path on \(host): start it with /, like /mnt/usb")
            }
            volume = try Self.volume(host: host, df: try await shell(.ssh(host), Self.remoteScript(path: path)))
        }
        return .value(.report(ActionReport(text: Self.table(for: volume), content: volume)))
    }

    /// One choice per volume: its name, its mount point as the value.
    static func choices(_ volumes: [VolumeSpace]) -> [ActionOption.Choice] {
        volumes.map { ActionOption.Choice($0.path, title: $0.name) }
    }

    /// `df` in POSIX format (1024-byte blocks) for the file system `path`
    /// is on, then its type: from `findmnt` on Linux, `diskutil` on a Mac
    /// (for a mount point).
    static func remoteScript(path: String) -> String {
        let path = ShellCommand.quote(path)
        return "df -kP -- \(path) && echo --- && (findmnt -no FSTYPE -T \(path) 2>/dev/null"
            + " || diskutil info \(path) 2>/dev/null | sed -n 's/^ *File System Personality: *//p')"
    }

    /// `remoteScript`'s output, read: named by the host's alias, with the
    /// mount point unless it is the root (`raspberrypi:/mnt/usb`).
    static func volume(host: String, df output: String) throws -> VolumeSpace {
        let sections = output.components(separatedBy: "\n---\n")
        let lines = sections[0].split(whereSeparator: \.isNewline)
        // Filesystem, 1024-blocks, Used, Available, Capacity, Mounted on.
        guard lines.count >= 2 else { throw QuickActionError("\(host): df gave no sizes") }
        let fields = lines[1].split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
        guard fields.count == 6, let blocks = Int64(fields[1]), let available = Int64(fields[3]) else {
            throw QuickActionError("\(host): df gave no sizes")
        }
        let fileSystem = sections.count > 1 ? sections[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let mountPoint = fields[5].trimmingCharacters(in: .whitespaces)
        return VolumeSpace(
            name: mountPoint == "/" ? host : "\(host):\(mountPoint)", host: host, path: mountPoint,
            fileSystem: fileSystem.isEmpty ? nil : fileSystem, total: blocks * 1024, available: available * 1024)
    }

    /// "Macintosh HD · APFS", then total, used, free and purgeable.
    static func table(for volume: VolumeSpace, bytes: (Int64) -> String = ReportTable.bytes) -> String {
        let percent = volume.total > 0 ? Int((Double(volume.used) / Double(volume.total) * 100).rounded()) : 0
        var rows = [
            ReportTable.Row("Total", bytes(volume.total)),
            ReportTable.Row("Used", bytes(volume.used), note: "\(percent) %"),
            ReportTable.Row("Free", bytes(volume.available)),
        ]
        if volume.purgeable > 0 {
            rows.append(ReportTable.Row("Purgeable", bytes(volume.purgeable), note: "freed when space is needed"))
        }
        let heading = ([volume.name] + [volume.fileSystem].compactMap { $0 }).joined(separator: " · ")
        return heading + "\n" + ReportTable.format(rows)
    }

    /// The startup volume first, then the others by name.
    static func sorted(_ volumes: [VolumeSpace]) -> [VolumeSpace] {
        volumes.sorted { lhs, rhs in
            if (lhs.path == "/") != (rhs.path == "/") { return lhs.path == "/" }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// The volumes Finder shows, with their sizes.
    @Sendable public static func mountedVolumes() -> [VolumeSpace] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeLocalizedFormatDescriptionKey, .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        ]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> VolumeSpace? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  let total = values.volumeTotalCapacity, total > 0 else { return nil }
            var path = url.path(percentEncoded: false)
            if path.count > 1, path.hasSuffix("/") { path.removeLast() }
            return VolumeSpace(
                name: values.volumeName ?? url.lastPathComponent, path: path,
                fileSystem: values.volumeLocalizedFormatDescription, total: Int64(total),
                available: Int64(values.volumeAvailableCapacity ?? 0),
                availableForImportantUsage: values.volumeAvailableCapacityForImportantUsage)
        }
        return sorted(volumes)
    }
}
#endif
