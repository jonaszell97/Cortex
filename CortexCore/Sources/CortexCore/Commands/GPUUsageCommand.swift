#if os(macOS)
import Foundation

/// A graphics processor and how busy it is.
public struct GPUDevice: Sendable, Equatable {
    /// "Apple M4 Pro", "NVIDIA GeForce RTX 4090".
    public var name: String
    public var coreCount: Int?
    /// 0 to 1.
    public var utilization: Double
    /// Apple's renderer and tiler stages, 0 to 1.
    public var renderer: Double?
    public var tiler: Double?
    public var memoryUsed: Int64?
    /// nil where it shares the system's memory (Apple silicon).
    public var memoryTotal: Int64?
    /// °C.
    public var temperature: Double?
    /// Watts.
    public var power: Double?
}

/// A process and the GPU it uses: its share of the GPU's time (on a Mac)
/// or the GPU memory it holds (NVIDIA).
public struct ProcessGPU: Sendable, Equatable {
    public var pid: Int32
    public var name: String
    /// 1 is the GPU kept busy for the whole sample.
    public var usage: Double?
    public var memory: Int64?
}

/// What `$gpu` reports, for the pane to draw.
public struct GPUSnapshot: Sendable, Equatable {
    /// nil for this Mac; otherwise the `~/.ssh/config` alias it was read from.
    public var host: String?
    public var platform: HostPlatform
    public var devices: [GPUDevice]
    /// The busiest (or the largest, by memory), first.
    public var processes: [ProcessGPU]
}

/// `$gpu`: how busy the Mac's GPU is and which processes keep it busy,
/// sampled over a second from the IOKit registry (`ioreg`, no root needed);
/// `$gpu @raspberrypi`: the same of a macOS host from `~/.ssh/config`, or
/// a Linux host's NVIDIA (`nvidia-smi`) or AMD (`amdgpu`) cards. A short
/// table to paste; the pane draws it from the `GPUSnapshot`.
public struct GPUUsageCommand: Command {
    public let id = "command.gpuuse"
    public let name = "gpu"
    public let title = "GPU Usage"
    public let summary = "Shows how busy the GPU is and the processes using it, of this Mac or a host over SSH."
    public let symbol = "square.grid.3x3"
    public let keywords = ["gpu", "graphics", "metal", "nvidia", "amd", "usage", "processes", "activity", "ssh", "server"]

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
        let snapshot = try Self.snapshot(host: machine.alias, output: try await shell(machine, Self.script))
        return .value(.report(ActionReport(text: Self.report(snapshot), content: snapshot)), refresh: .seconds(2))
    }

    /// On a Mac the GPUs and their clients twice, a second apart; on Linux
    /// what `nvidia-smi` and the `amdgpu` cards say.
    static let script = """
        s=$(uname -s); echo '@@ system'; echo "$s"
        if [ "$s" = Darwin ]; then
          echo '@@ ioreg1'; ioreg -r -w 0 -l -c IOAccelerator
          sleep 1
          echo '@@ ioreg2'; ioreg -r -w 0 -l -c IOAccelerator
        else
          echo '@@ nvidia'
          nvidia-smi --query-gpu=name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw \\
            --format=csv,noheader,nounits 2>/dev/null
          echo '@@ nvidia-apps'
          nvidia-smi --query-compute-apps=pid,process_name,used_memory --format=csv,noheader,nounits 2>/dev/null
          for d in /sys/class/drm/card*/device; do
            [ -r "$d/gpu_busy_percent" ] || continue
            echo "@@ amd $d"
            echo "busy $(cat "$d/gpu_busy_percent")"
            echo "used $(cat "$d/mem_info_vram_used" 2>/dev/null)"
            echo "total $(cat "$d/mem_info_vram_total" 2>/dev/null)"
            echo "temperature $(cat "$d"/hwmon/hwmon*/temp1_input 2>/dev/null | head -n 1)"
            echo "power $(cat "$d"/hwmon/hwmon*/power1_average 2>/dev/null | head -n 1)"
            echo "name $(cat "$d/product_name" 2>/dev/null)"
          done
        fi
        true
        """

    /// `script`'s output, read.
    static func snapshot(host: String?, output: String) throws -> GPUSnapshot {
        let sections = SSHHosts.sections(output)
        guard let platform = HostPlatform(uname: sections["system"] ?? "") else {
            throw HostPlatform.unsupported(host ?? "This Mac", uname: sections["system"])
        }
        let snapshot = switch platform {
        case .mac: mac(first: sections["ioreg1"] ?? "", second: sections["ioreg2"] ?? "")
        case .linux: linux(sections)
        }
        guard var snapshot, !snapshot.devices.isEmpty else {
            throw QuickActionError(platform == .mac
                ? "\(host ?? "This Mac") reports no GPU statistics"
                : "\(host ?? "This Mac") has no GPU Cortex can read: it reads NVIDIA cards with nvidia-smi and AMD cards with amdgpu")
        }
        snapshot.host = host
        return snapshot
    }

    // MARK: - macOS

    /// Two `ioreg -l -c IOAccelerator` samples a second apart: the GPUs as
    /// the second describes them, and each process's share of the GPU's
    /// time between them (`accumulatedGPUTime`, in nanoseconds, of all its
    /// clients).
    static func mac(first: String, second: String) -> GPUSnapshot? {
        let objects = ioregObjects(second)
        let devices = objects.filter { $0.depth == 0 }.compactMap(device)
        guard !devices.isEmpty else { return nil }
        let before = gpuTime(ioregObjects(first))
        let processes = gpuTime(objects).compactMap { pid, sample -> ProcessGPU? in
            // Less than half a percent shows as 0 %.
            guard let earlier = before[pid], sample.time >= earlier.time + 5_000_000 else { return nil }
            return ProcessGPU(pid: pid, name: sample.name, usage: min(Double(sample.time - earlier.time) / 1e9, 1), memory: nil)
        }
        return GPUSnapshot(host: nil, platform: .mac, devices: devices, processes: busiest(processes))
    }

    /// An object of `ioreg -l` output: how deep it is (0 for the
    /// accelerators, more for their clients) and its property lines.
    struct IORegObject {
        var depth: Int
        var lines: [Substring]

        /// `"key" = value`, the value as written.
        func value(_ key: String) -> Substring? {
            let prefix = "\"\(key)\" = "
            for line in lines {
                guard let range = line.range(of: prefix) else { continue }
                return line[range.upperBound...]
            }
            return nil
        }
    }

    /// Objects start with a `+-o Name  <class …>` line, indented two
    /// characters more for each level.
    static func ioregObjects(_ output: String) -> [IORegObject] {
        var objects: [IORegObject] = []
        for line in output.split(whereSeparator: \.isNewline) {
            if let marker = line.range(of: "+-o ") {
                objects.append(IORegObject(depth: line.distance(from: line.startIndex, to: marker.lowerBound) / 2, lines: []))
            } else if !objects.isEmpty {
                objects[objects.count - 1].lines.append(line)
            }
        }
        return objects
    }

    /// An accelerator: its model, core count and `PerformanceStatistics`.
    static func device(_ object: IORegObject) -> GPUDevice? {
        guard let statistics = object.value("PerformanceStatistics") else { return nil }
        var numbers: [String: Int64] = [:]
        for match in statistics.matches(of: /"([^"]+)"=(\d+)/) {
            numbers[String(match.1)] = Int64(match.2)
        }
        guard let utilization = numbers["Device Utilization %"] else { return nil }
        let name = object.value("model").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\" ")) }
        return GPUDevice(
            name: name ?? "GPU", coreCount: object.value("gpu-core-count").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) },
            utilization: Double(utilization) / 100,
            renderer: numbers["Renderer Utilization %"].map { Double($0) / 100 },
            tiler: numbers["Tiler Utilization %"].map { Double($0) / 100 },
            memoryUsed: numbers["In use system memory"], memoryTotal: nil, temperature: nil, power: nil)
    }

    /// Every client's `accumulatedGPUTime`, summed by the process that
    /// opened it (`"IOUserClientCreator" = "pid 178, WindowServer"`).
    static func gpuTime(_ objects: [IORegObject]) -> [Int32: (name: String, time: UInt64)] {
        var processes: [Int32: (name: String, time: UInt64)] = [:]
        for object in objects where object.depth > 0 {
            guard let creator = object.value("IOUserClientCreator")?.firstMatch(of: /"pid (\d+), (.*)"/),
                  let pid = Int32(creator.1) else { continue }
            let time = (object.value("AppUsage") ?? "").matches(of: /"accumulatedGPUTime"=(\d+)/)
                .reduce(UInt64(0)) { $0 + (UInt64($1.1) ?? 0) }
            processes[pid, default: (String(creator.2), 0)].time += time
        }
        return processes
    }

    // MARK: - Linux

    static func linux(_ sections: [String: String]) -> GPUSnapshot {
        var devices = nvidia(sections["nvidia"] ?? "")
        for (key, value) in sections.sorted(by: { $0.key < $1.key }) where key.hasPrefix("amd ") {
            if let device = amd(value, card: URL(filePath: String(key.dropFirst(4))).deletingLastPathComponent().lastPathComponent) {
                devices.append(device)
            }
        }
        let processes = (sections["nvidia-apps"] ?? "").split(whereSeparator: \.isNewline).compactMap { line -> ProcessGPU? in
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, let pid = Int32(fields[0]) else { return nil }
            return ProcessGPU(
                pid: pid, name: URL(filePath: fields[1]).lastPathComponent, usage: nil,
                memory: Int64(fields[2]).map { $0 * 1024 * 1024 })
        }
        return GPUSnapshot(host: nil, platform: .linux, devices: devices, processes: busiest(processes))
    }

    /// `nvidia-smi --query-gpu=name,utilization.gpu,memory.used,
    /// memory.total,temperature.gpu,power.draw --format=csv,noheader,nounits`:
    /// one card a line, memory in MiB, "[N/A]" for what a card does not say.
    static func nvidia(_ output: String) -> [GPUDevice] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 6, let utilization = Double(fields[1]) else { return nil }
            return GPUDevice(
                name: fields[0], coreCount: nil, utilization: utilization / 100, renderer: nil, tiler: nil,
                memoryUsed: Int64(fields[2]).map { $0 * 1024 * 1024 }, memoryTotal: Int64(fields[3]).map { $0 * 1024 * 1024 },
                temperature: Double(fields[4]), power: Double(fields[5]))
        }
    }

    /// The `script`'s lines for an `amdgpu` card: busy percent, VRAM in
    /// bytes, millidegrees, microwatts, and the product name where the
    /// card has one.
    static func amd(_ output: String, card: String) -> GPUDevice? {
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: " ", maxSplits: 1)
            if parts.count == 2 { values[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        guard let busy = values["busy"].flatMap(Double.init) else { return nil }
        let name = values["name"] ?? ""
        return GPUDevice(
            name: name.isEmpty ? "AMD GPU (\(card))" : name, coreCount: nil, utilization: busy / 100, renderer: nil, tiler: nil,
            memoryUsed: values["used"].flatMap { Int64($0) }, memoryTotal: values["total"].flatMap { Int64($0) },
            temperature: values["temperature"].flatMap(Double.init).map { $0 / 1000 },
            power: values["power"].flatMap(Double.init).map { $0 / 1_000_000 })
    }

    /// By share of the GPU, or by memory where there is no share; those
    /// that used none are left out.
    static func busiest(_ processes: [ProcessGPU]) -> [ProcessGPU] {
        func weight(_ process: ProcessGPU) -> Double { process.usage ?? Double(process.memory ?? 0) }
        return Array(processes.filter { weight($0) > 0 }
            .sorted { weight($0) != weight($1) ? weight($0) > weight($1) : $0.pid < $1.pid }
            .prefix(processLimit))
    }

    // MARK: - Report

    /// The host's name for a host, a table per GPU, then the processes.
    static func report(_ snapshot: GPUSnapshot) -> String {
        var parts: [String] = []
        for device in snapshot.devices {
            var rows = [ReportTable.Row("Busy", CPUUsageCommand.percent(device.utilization))]
            if let renderer = device.renderer { rows.append(ReportTable.Row("  Renderer", CPUUsageCommand.percent(renderer))) }
            if let tiler = device.tiler { rows.append(ReportTable.Row("  Tiler", CPUUsageCommand.percent(tiler))) }
            if let used = device.memoryUsed {
                rows.append(ReportTable.Row(
                    "Memory in use", ReportTable.memory(used), note: device.memoryTotal.map { "of \(ReportTable.memory($0))" }))
            }
            if let temperature = device.temperature { rows.append(ReportTable.Row("Temperature", String(format: "%.0f °C", temperature))) }
            if let power = device.power { rows.append(ReportTable.Row("Power", String(format: "%.0f W", power))) }
            let heading = [device.name, device.coreCount.map { "\($0) cores" }].compactMap { $0 }.joined(separator: " · ")
            parts.append(heading + "\n" + ReportTable.format(rows))
        }
        // A blank line between GPUs; the host's name right above the first.
        var report = (snapshot.host.map { "\($0)\n" } ?? "") + parts.joined(separator: "\n\n")
        let processes = snapshot.processes
        guard !processes.isEmpty else { return report }
        let byTime = processes.allSatisfy { $0.usage != nil }
        let pidWidth = max(processes.map { String($0.pid).count }.max() ?? 0, 3)
        let values = processes.map { process in
            process.usage.map(CPUUsageCommand.percent) ?? process.memory.map(ReportTable.memory) ?? ""
        }
        let valueWidth = max(values.map(\.count).max() ?? 0, 6)
        func line(_ pid: String, _ value: String, _ name: String) -> String {
            String(repeating: " ", count: pidWidth - pid.count) + pid + "  "
                + String(repeating: " ", count: valueWidth - value.count) + value + "  " + name
        }
        report += "\n\n\(byTime ? "Busiest processes" : "GPU memory by process")\n" + line("PID", byTime ? "GPU" : "Memory", "Name")
        for (process, value) in zip(processes, values) {
            report += "\n" + line(String(process.pid), value, process.name)
        }
        return report
    }
}
#endif
