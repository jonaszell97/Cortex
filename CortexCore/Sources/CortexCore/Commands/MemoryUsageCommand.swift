#if os(macOS)
import Darwin
import Foundation

/// Page counts from `vm_stat`, in pages of `pageSize` bytes.
struct VMStatistics: Sendable, Equatable {
    var pageSize: Int64
    var wired: Int64
    var purgeable: Int64
    var fileBacked: Int64
    var anonymous: Int64
    /// Pages the compressor occupies (not the pages stored in it).
    var compressor: Int64

    /// App memory as Activity Monitor counts it: anonymous pages that
    /// cannot be purged.
    var appMemory: Int64 { max(anonymous - purgeable, 0) * pageSize }
    var wiredMemory: Int64 { wired * pageSize }
    var compressedMemory: Int64 { compressor * pageSize }
    var usedMemory: Int64 { appMemory + wiredMemory + compressedMemory }
    /// Files kept in memory, given back when apps need it.
    var cachedFiles: Int64 { (fileBacked + purgeable) * pageSize }

    /// nil when the output lacks the page size or a needed line.
    init?(vmStat output: String) {
        var pages: [String: Int64] = [:]
        var pageSize: Int64?
        for line in output.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: /page size of (\d+) bytes/) {
                pageSize = Int64(match.1)
                continue
            }
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let key = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            let value = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: ". "))
            pages[key] = Int64(value)
        }
        guard let pageSize, let wired = pages["Pages wired down"], let anonymous = pages["Anonymous pages"],
              let compressor = pages["Pages occupied by compressor"] else { return nil }
        self.pageSize = pageSize
        self.wired = wired
        self.purgeable = pages["Pages purgeable"] ?? 0
        self.fileBacked = pages["File-backed pages"] ?? 0
        self.anonymous = anonymous
        self.compressor = compressor
    }
}

/// One of the user's processes and its resident memory.
public struct ProcessMemory: Sendable, Equatable {
    public var pid: Int32
    /// Its executable's name: "Safari".
    public var name: String
    /// Its executable, as `ps` gives it (a bare name for some).
    public var path: String
    public var residentBytes: Int64

    init(pid: Int32, name: String, path: String? = nil, residentBytes: Int64) {
        self.pid = pid
        self.name = name
        self.path = path ?? name
        self.residentBytes = residentBytes
    }
}

/// How busy memory is, as Activity Monitor's pressure graph colours it.
public enum MemoryPressure: Sendable, Equatable {
    case normal, warning, critical

    /// From `kern.memorystatus_vm_pressure_level`; nil when it cannot be read.
    static func current() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return MemoryPressure(level: level)
    }

    /// 1 normal, 2 warning, 4 critical.
    init(level: Int32) {
        self = switch level {
        case 4: .critical
        case 2: .warning
        default: .normal
        }
    }
}

/// What `$mem` reports, for the pane to draw.
public struct MemorySnapshot: Sendable, Equatable {
    /// nil for this Mac; otherwise the `~/.ssh/config` alias it was read from.
    public var host: String?
    public var platform: HostPlatform
    public var physical: Int64
    public var appMemory: Int64
    /// Memory the kernel keeps: wired on a Mac; on Linux its slabs, stacks
    /// and page tables.
    public var wired: Int64
    public var compressed: Int64
    public var cachedFiles: Int64
    public var swapUsed: Int64?
    public var swapTotal: Int64?
    public var pressure: MemoryPressure?
    /// Largest first: the user's on this Mac, everyone's on a host.
    public var processes: [ProcessMemory]

    /// App memory, wired and compressed: Activity Monitor's "Memory Used".
    public var used: Int64 { appMemory + wired + compressed }
    /// Neither used nor caching files.
    public var free: Int64 { max(physical - used - cachedFiles, 0) }

    /// What the kernel's part is called there.
    public var wiredTitle: String { platform == .mac ? "Wired" : "Kernel" }

    init(
        physical: Int64, statistics: VMStatistics, swap: (used: Int64, total: Int64)?, pressure: MemoryPressure?,
        processes: [ProcessMemory]
    ) {
        host = nil
        platform = .mac
        self.physical = physical
        appMemory = statistics.appMemory
        wired = statistics.wiredMemory
        compressed = statistics.compressedMemory
        cachedFiles = statistics.cachedFiles
        swapUsed = swap?.used
        swapTotal = swap?.total
        self.pressure = pressure
        self.processes = processes
    }

    /// From Linux's `/proc/meminfo` (sizes in kB), counted like `free`:
    /// used is what is neither free nor buffers and page cache. nil when
    /// it lacks `MemTotal` or `MemFree`.
    init?(host: String, meminfo output: String, processes: [ProcessMemory]) {
        var kilobytes: [String: Int64] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, let value = Int64(parts[1].split(separator: " ").first ?? "") else { continue }
            kilobytes[String(parts[0])] = value
        }
        func bytes(_ key: String) -> Int64 { (kilobytes[key] ?? 0) * 1024 }
        guard kilobytes["MemTotal"] != nil, kilobytes["MemFree"] != nil else { return nil }
        self.host = host
        platform = .linux
        physical = bytes("MemTotal")
        cachedFiles = bytes("Buffers") + bytes("Cached") + bytes("SReclaimable")
        let used = max(physical - bytes("MemFree") - cachedFiles, 0)
        wired = min(bytes("SUnreclaim") + bytes("KernelStack") + bytes("PageTables"), used)
        compressed = min(bytes("Zswap"), used - wired)
        appMemory = used - wired - compressed
        if kilobytes["SwapTotal"] != nil {
            swapTotal = bytes("SwapTotal")
            swapUsed = max(bytes("SwapTotal") - bytes("SwapFree"), 0)
        }
        pressure = nil
        self.processes = processes
    }
}

/// `$mem`: how the Mac's memory is used, and the user's ten largest
/// processes; `$mem @raspberrypi`: the same of a macOS or Linux host from
/// `~/.ssh/config`, read over SSH (everyone's processes). A short table to
/// paste; the pane draws it from the `MemorySnapshot`.
public struct MemoryUsageCommand: Command {
    public let id = "command.memuse"
    public let name = "mem"
    public let title = "Memory Usage"
    public let summary = "Shows how memory is used, swap included, and the ten largest processes, of this Mac or a host over SSH."
    public let symbol = "memorychip"
    public let keywords = ["memory", "ram", "swap", "usage", "processes", "top", "activity", "ssh", "server"]

    /// How many processes are listed.
    static let processLimit = 10
    /// Runs the script of a host; this Mac is read directly.
    let shell: MachineShell

    public init(shell: @escaping MachineShell = Machine.shell) {
        self.shell = shell
    }

    public var runsOnHosts: Bool { true }

    /// The numbers are read as soon as it is selected, and again every 2
    /// seconds while it stays selected.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let snapshot: MemorySnapshot
        switch invocation.machine {
        case .local: snapshot = try await localSnapshot()
        case .ssh(let host): snapshot = try await remoteSnapshot(of: host)
        }
        return .value(.report(ActionReport(text: Self.report(snapshot), content: snapshot)), refresh: .seconds(2))
    }

    private func localSnapshot() async throws -> MemorySnapshot {
        async let vmStat = ProcessRunner.run(URL(filePath: "/usr/bin/vm_stat"), arguments: [])
        async let ps = ProcessRunner.run(URL(filePath: "/bin/ps"), arguments: ["-ax", "-o", "pid=,uid=,rss=,comm="])
        guard let statistics = VMStatistics(vmStat: try await vmStat.outputText) else {
            throw QuickActionError("vm_stat gave no memory statistics")
        }
        let processes = Self.largest(Self.parse(ps: try await ps.outputText, uid: getuid()), limit: Self.processLimit)
        return MemorySnapshot(
            physical: Int64(ProcessInfo.processInfo.physicalMemory), statistics: statistics, swap: Self.swapUsage(),
            pressure: .current(), processes: processes)
    }

    /// The system's name, what either system says about its memory, and
    /// every process, in one connection.
    static let remoteScript = """
        echo '@@ system'; uname -s
        echo '@@ meminfo'; cat /proc/meminfo 2>/dev/null
        echo '@@ memsize'; sysctl -n hw.memsize 2>/dev/null
        echo '@@ vmstat'; vm_stat 2>/dev/null
        echo '@@ swap'; sysctl -n vm.swapusage 2>/dev/null
        echo '@@ pressure'; sysctl -n kern.memorystatus_vm_pressure_level 2>/dev/null
        echo '@@ ps'; ps -A -o pid=,uid=,rss=,comm=
        true
        """

    private func remoteSnapshot(of host: String) async throws -> MemorySnapshot {
        let output = try await shell(.ssh(host), Self.remoteScript)
        return try Self.snapshot(host: host, remoteOutput: output)
    }

    /// `remoteScript`'s output, read.
    static func snapshot(host: String, remoteOutput output: String) throws -> MemorySnapshot {
        let sections = SSHHosts.sections(output)
        guard let platform = HostPlatform(uname: sections["system"] ?? "") else {
            throw HostPlatform.unsupported(host, uname: sections["system"])
        }
        let processes = largest(parse(ps: sections["ps"] ?? "", uid: nil), limit: processLimit)
        switch platform {
        case .linux:
            if let snapshot = MemorySnapshot(host: host, meminfo: sections["meminfo"] ?? "", processes: processes) {
                return snapshot
            }
        case .mac:
            if let physical = Int64(sections["memsize"] ?? ""), let statistics = VMStatistics(vmStat: sections["vmstat"] ?? "") {
                var snapshot = MemorySnapshot(
                    physical: physical, statistics: statistics, swap: swapUsage(sysctl: sections["swap"] ?? ""),
                    pressure: Int32(sections["pressure"] ?? "").map(MemoryPressure.init(level:)), processes: processes)
                snapshot.host = host
                return snapshot
            }
        }
        throw QuickActionError("\(host) gave no memory statistics")
    }

    /// `sysctl -n vm.swapusage`: "total = 2048.00M  used = 1102.75M  free = …".
    static func swapUsage(sysctl output: String) -> (used: Int64, total: Int64)? {
        func bytes(_ match: (Substring, Substring, Substring)?) -> Int64? {
            guard let match, let value = Double(match.1) else { return nil }
            let exponent: Double = ["K": 1, "M": 2, "G": 3, "T": 4][String(match.2)] ?? 0
            return Int64(value * pow(1024, exponent))
        }
        guard let used = bytes(output.firstMatch(of: /used = ([0-9.]+)([KMGT]?)/)?.output),
              let total = bytes(output.firstMatch(of: /total = ([0-9.]+)([KMGT]?)/)?.output) else { return nil }
        return (used, total)
    }

    /// `ps -o pid=,uid=,rss=,comm=` (resident size in KiB): the processes
    /// of `uid` (all for nil), named by their executable.
    static func parse(ps output: String, uid: uid_t?) -> [ProcessMemory] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let pid = Int32(fields[0]), uid.map({ fields[1] == String($0) }) ?? true,
                  let kib = Int64(fields[2])
            else { return nil }
            let path = fields[3].trimmingCharacters(in: .whitespaces)
            return ProcessMemory(pid: pid, name: URL(filePath: path).lastPathComponent, path: path, residentBytes: kib * 1024)
        }
    }

    static func largest(_ processes: [ProcessMemory], limit: Int) -> [ProcessMemory] {
        Array(processes.sorted { $0.residentBytes != $1.residentBytes ? $0.residentBytes > $1.residentBytes : $0.pid < $1.pid }
            .prefix(limit))
    }

    /// Used and total swap, from `vm.swapusage`.
    static func swapUsage() -> (used: Int64, total: Int64)? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return (Int64(usage.xsu_used), Int64(usage.xsu_total))
    }

    /// The host's name for a host, the overview, then the processes.
    static func report(_ snapshot: MemorySnapshot, bytes: (Int64) -> String = ReportTable.memory) -> String {
        var rows = [
            ReportTable.Row("Physical memory", bytes(snapshot.physical)),
            ReportTable.Row("Used", bytes(snapshot.used)),
            ReportTable.Row("  App memory", bytes(snapshot.appMemory)),
            ReportTable.Row("  " + snapshot.wiredTitle, bytes(snapshot.wired)),
        ]
        if snapshot.platform == .mac || snapshot.compressed > 0 {
            rows.append(ReportTable.Row("  Compressed", bytes(snapshot.compressed)))
        }
        rows.append(ReportTable.Row("Cached files", bytes(snapshot.cachedFiles)))
        if let used = snapshot.swapUsed, let total = snapshot.swapTotal {
            rows.append(ReportTable.Row("Swap used", bytes(used), note: "of \(bytes(total))"))
        }
        var report = (snapshot.host.map { "\($0)\n" } ?? "") + ReportTable.format(rows)
        let processes = snapshot.processes
        guard !processes.isEmpty else { return report }
        let pidWidth = max(processes.map { String($0.pid).count }.max() ?? 0, 3)
        let sizes = processes.map { bytes($0.residentBytes) }
        let sizeWidth = max(sizes.map(\.count).max() ?? 0, 6)
        func line(_ pid: String, _ size: String, _ name: String) -> String {
            String(repeating: " ", count: pidWidth - pid.count) + pid + "  "
                + String(repeating: " ", count: sizeWidth - size.count) + size + "  " + name
        }
        report += "\n\n\(snapshot.host == nil ? "Your largest processes" : "Largest processes")\n" + line("PID", "Memory", "Name")
        for (process, size) in zip(processes, sizes) {
            report += "\n" + line(String(process.pid), size, process.name)
        }
        return report
    }
}
#endif
