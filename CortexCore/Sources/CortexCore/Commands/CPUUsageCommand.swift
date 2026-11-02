#if os(macOS)
import Darwin
import Foundation

/// A process and how busy it kept the CPU over the sample.
public struct ProcessCPU: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// 1 is one core kept fully busy.
    public var usage: Double
}

/// What `$cpu` reports, for the pane to draw.
public struct CPUSnapshot: Sendable, Equatable {
    /// nil for this Mac; otherwise the `~/.ssh/config` alias it was read from.
    public var host: String?
    public var platform: HostPlatform
    /// "Apple M4 Pro", "Raspberry Pi 5 Model B Rev 1.0".
    public var model: String?
    public var coreCount: Int
    /// Shares of all cores' time over the sample, 0 to 1.
    public var user: Double
    public var system: Double
    /// How busy each core was, 0 to 1; empty where that is not known (a
    /// Mac host).
    public var cores: [Double]
    /// Over 1, 5 and 15 minutes.
    public var loadAverage: [Double]
    /// °C, where the host has a thermal zone (Linux).
    public var temperature: Double?
    /// The busiest, busiest first.
    public var processes: [ProcessCPU]

    public var busy: Double { min(user + system, 1) }
    public var idle: Double { 1 - busy }
}

/// Clock ticks a CPU (or all of them) spent, from Linux's `/proc/stat` or
/// the Mach host.
struct CPUTicks: Sendable, Equatable {
    var user: UInt64
    var system: UInt64
    var idle: UInt64

    var total: UInt64 { user + system + idle }

    /// A `/proc/stat` line: `cpu0 user nice system idle iowait irq softirq
    /// steal …`. Waiting for I/O counts as idle; guest time is already in
    /// user.
    init?(procStat line: Substring) {
        let fields = line.split(separator: " ").dropFirst().compactMap { UInt64($0) }
        guard fields.count >= 4 else { return nil }
        func field(_ index: Int) -> UInt64 { index < fields.count ? fields[index] : 0 }
        user = field(0) + field(1)
        system = field(2) + field(5) + field(6) + field(7)
        idle = field(3) + field(4)
    }

    init(user: UInt64, system: UInt64, idle: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
    }

    /// What was spent between `earlier` and this sample, as shares.
    func shares(since earlier: CPUTicks) -> (user: Double, system: Double) {
        let total = Double(total &- earlier.total)
        guard total > 0 else { return (0, 0) }
        return (Double(user &- earlier.user) / total, Double(system &- earlier.system) / total)
    }
}

/// `$cpu`: how busy the Mac's CPU is, overall and per core, its load
/// average and the busiest processes, sampled over a second;
/// `$cpu @raspberrypi`: the same of a macOS or Linux host from
/// `~/.ssh/config`, read over SSH. A short table to paste; the pane draws
/// it from the `CPUSnapshot`.
public struct CPUUsageCommand: Command {
    public let id = "command.cpuuse"
    public let name = "cpu"
    public let title = "CPU Usage"
    public let summary = "Shows how busy the CPU is, per core, its load and the ten busiest processes, of this Mac or a host over SSH."
    public let symbol = "cpu"
    public let keywords = ["cpu", "processor", "load", "usage", "cores", "processes", "top", "activity", "ssh", "server"]

    static let processLimit = 10
    let shell: MachineShell

    public init(shell: @escaping MachineShell = Machine.shell) {
        self.shell = shell
    }

    public var runsOnHosts: Bool { true }

    /// It samples for a second and changes nothing: the palette shows it
    /// when it is there, and again every 2 seconds while it stays selected.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let machine = invocation.machine
        // `top` leaves out the cores; on this Mac the Mach host has them,
        // sampled over the same second.
        let before = machine == .local ? Self.coreTicks() : nil
        var snapshot = try Self.snapshot(host: machine.alias, output: try await shell(machine, Self.script))
        if let before, let after = Self.coreTicks(), before.count == after.count {
            snapshot.cores = zip(after, before).map { after, earlier in
                let shares = after.shares(since: earlier)
                return min(shares.user + shares.system, 1)
            }
        }
        return .value(.report(ActionReport(text: Self.report(snapshot), content: snapshot)), refresh: .seconds(2))
    }

    /// Samples for a second, on a Mac with `top`, on Linux from `/proc`
    /// (every process's ticks before and after).
    static let script = """
        s=$(uname -s); echo '@@ system'; echo "$s"
        if [ "$s" = Darwin ]; then
          echo '@@ model'; sysctl -n machdep.cpu.brand_string
          echo '@@ cores'; sysctl -n hw.logicalcpu
          echo '@@ top'; top -l 2 -s 1 -n 10 -o cpu -stats pid,cpu,command
        else
          echo '@@ model'; grep -m1 -E '^(model name|Model)' /proc/cpuinfo
          echo '@@ load'; cat /proc/loadavg
          echo '@@ temperature'; cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null
          echo '@@ stat1'; grep '^cpu' /proc/stat
          echo '@@ procs1'; cat /proc/[0-9]*/stat 2>/dev/null
          sleep 1
          echo '@@ stat2'; grep '^cpu' /proc/stat
          echo '@@ procs2'; cat /proc/[0-9]*/stat 2>/dev/null
        fi
        true
        """

    /// `script`'s output, read.
    static func snapshot(host: String?, output: String) throws -> CPUSnapshot {
        let sections = SSHHosts.sections(output)
        guard let platform = HostPlatform(uname: sections["system"] ?? "") else {
            throw HostPlatform.unsupported(host ?? "This Mac", uname: sections["system"])
        }
        let model = sections["model"].map { line in
            // "model name : Intel(R) …" on Linux; the bare name from sysctl.
            (line.firstIndex(of: ":").map { line[line.index(after: $0)...] } ?? line[...])
                .trimmingCharacters(in: .whitespaces)
        }.flatMap { $0.isEmpty ? nil : $0 }
        let snapshot = switch platform {
        case .mac: mac(top: sections["top"] ?? "", cores: Int(sections["cores"] ?? ""))
        case .linux: linux(sections)
        }
        guard var snapshot else { throw QuickActionError("\(host ?? "This Mac") gave no CPU statistics") }
        snapshot.host = host
        snapshot.model = model
        return snapshot
    }

    /// `top -l 2 … -stats pid,cpu,command`: the second sample (the first
    /// has no per-process figures yet).
    static func mac(top output: String, cores: Int?) -> CPUSnapshot? {
        let lines = output.split(whereSeparator: \.isNewline)
        guard let usage = lines.last(where: { $0.hasPrefix("CPU usage:") }),
              let match = usage.firstMatch(of: /([0-9.]+)% user, ([0-9.]+)% sys/),
              let user = Double(match.1), let system = Double(match.2) else { return nil }
        let load = lines.last(where: { $0.hasPrefix("Load Avg:") })
            .map { $0.dropFirst("Load Avg:".count).split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) } } ?? []
        var processes: [ProcessCPU] = []
        if let header = lines.lastIndex(where: { $0.hasPrefix("PID") }) {
            processes = lines[(header + 1)...].compactMap { line in
                let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                let name = fields.count == 3 ? fields[2].trimmingCharacters(in: .whitespaces) : ""
                // `top` is what samples.
                guard fields.count == 3, let pid = Int32(fields[0]), let cpu = Double(fields[1]), name != "top" else { return nil }
                return ProcessCPU(pid: pid, name: name, usage: cpu / 100)
            }
        }
        return CPUSnapshot(
            host: nil, platform: .mac, model: nil, coreCount: cores ?? 0, user: user / 100, system: system / 100, cores: [],
            loadAverage: load, temperature: nil, processes: busiest(processes))
    }

    /// `/proc/stat` and every `/proc/<pid>/stat`, a second apart.
    static func linux(_ sections: [String: String]) -> CPUSnapshot? {
        func ticks(_ name: String) -> (all: CPUTicks?, cores: [CPUTicks]) {
            let lines = (sections[name] ?? "").split(whereSeparator: \.isNewline)
            return (
                lines.first { $0.hasPrefix("cpu ") }.flatMap(CPUTicks.init(procStat:)),
                lines.filter { $0.hasPrefix("cpu") && !$0.hasPrefix("cpu ") }.compactMap(CPUTicks.init(procStat:)))
        }
        let (first, second) = (ticks("stat1"), ticks("stat2"))
        guard let before = first.all, let after = second.all else { return nil }
        let overall = after.shares(since: before)
        let cores = zip(second.cores, first.cores).map { after, before in
            let shares = after.shares(since: before)
            return min(shares.user + shares.system, 1)
        }
        let coreCount = max(second.cores.count, 1)
        // A process's ticks against one core's ticks over the same time.
        let coreTicks = Double(after.total &- before.total) / Double(coreCount)
        let earlier = processTicks(sections["procs1"] ?? "")
        let processes = processTicks(sections["procs2"] ?? "").compactMap { pid, sample -> ProcessCPU? in
            guard let previous = earlier[pid], sample.ticks >= previous.ticks, coreTicks > 0 else { return nil }
            return ProcessCPU(pid: pid, name: sample.name, usage: Double(sample.ticks - previous.ticks) / coreTicks)
        }
        let load = (sections["load"] ?? "").split(separator: " ").prefix(3).compactMap { Double($0) }
        let temperature = Double(sections["temperature"] ?? "").map { $0 / 1000 }
        return CPUSnapshot(
            host: nil, platform: .linux, model: nil, coreCount: second.cores.count, user: overall.user, system: overall.system,
            cores: cores, loadAverage: load, temperature: temperature, processes: busiest(processes))
    }

    /// `/proc/<pid>/stat` lines: `pid (name) state …`, with user and system
    /// time as the 14th and 15th fields. The name may hold spaces and
    /// parentheses, so it ends at the last ")".
    static func processTicks(_ output: String) -> [Int32: (name: String, ticks: UInt64)] {
        var processes: [Int32: (name: String, ticks: UInt64)] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let open = line.firstIndex(of: "("), let close = line.lastIndex(of: ")"), open < close,
                  let pid = Int32(line[..<open].trimmingCharacters(in: .whitespaces)) else { continue }
            let fields = line[line.index(after: close)...].split(separator: " ")
            // fields[0] is the state, the 3rd field.
            guard fields.count > 12, let user = UInt64(fields[11]), let system = UInt64(fields[12]) else { continue }
            processes[pid] = (String(line[line.index(after: open)..<close]), user + system)
        }
        return processes
    }

    static func busiest(_ processes: [ProcessCPU]) -> [ProcessCPU] {
        Array(processes.filter { $0.usage > 0 }
            .sorted { $0.usage != $1.usage ? $0.usage > $1.usage : $0.pid < $1.pid }
            .prefix(processLimit))
    }

    /// Every core's ticks so far, from the Mach host.
    static func coreTicks() -> [CPUTicks]? {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return nil }
        defer {
            vm_deallocate(
                mach_task_self_, vm_address_t(UInt(bitPattern: info)), vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(count)).map { cpu in
            func ticks(_ state: Int32) -> UInt64 { UInt64(UInt32(bitPattern: info[cpu * Int(CPU_STATE_MAX) + Int(state)])) }
            return CPUTicks(
                user: ticks(CPU_STATE_USER) + ticks(CPU_STATE_NICE), system: ticks(CPU_STATE_SYSTEM), idle: ticks(CPU_STATE_IDLE))
        }
    }

    /// "43 %".
    public static func percent(_ share: Double) -> String {
        "\(Int((share * 100).rounded())) %"
    }

    /// The host's name for a host, the model, the shares, the load, the
    /// temperature, then the processes.
    static func report(_ snapshot: CPUSnapshot) -> String {
        var rows = [
            ReportTable.Row("Busy", percent(snapshot.busy)),
            ReportTable.Row("  User", percent(snapshot.user)),
            ReportTable.Row("  System", percent(snapshot.system)),
            ReportTable.Row("Idle", percent(snapshot.idle)),
        ]
        if !snapshot.loadAverage.isEmpty {
            rows.append(ReportTable.Row(
                "Load average", snapshot.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: "  "),
                note: "1, 5, 15 min"))
        }
        if let temperature = snapshot.temperature {
            rows.append(ReportTable.Row("Temperature", String(format: "%.1f °C", temperature)))
        }
        let model = [snapshot.model, snapshot.coreCount > 0 ? "\(snapshot.coreCount) cores" : nil].compactMap { $0 }
        var report = ([snapshot.host, model.isEmpty ? nil : model.joined(separator: " · ")].compactMap { $0 }
            + [ReportTable.format(rows)]).joined(separator: "\n")
        let processes = snapshot.processes
        guard !processes.isEmpty else { return report }
        let pidWidth = max(processes.map { String($0.pid).count }.max() ?? 0, 3)
        let usages = processes.map { percent($0.usage) }
        let usageWidth = max(usages.map(\.count).max() ?? 0, 3)
        func line(_ pid: String, _ usage: String, _ name: String) -> String {
            String(repeating: " ", count: pidWidth - pid.count) + pid + "  "
                + String(repeating: " ", count: usageWidth - usage.count) + usage + "  " + name
        }
        report += "\n\nBusiest processes\n" + line("PID", "CPU", "Name")
        for (process, usage) in zip(processes, usages) {
            report += "\n" + line(String(process.pid), usage, process.name)
        }
        return report
    }
}
#endif
