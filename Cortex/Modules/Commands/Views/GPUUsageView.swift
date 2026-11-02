import SwiftUI
import CortexCore

extension GPUUsageCommand: ReportPresenting {
    func reportView(for snapshot: GPUSnapshot) -> GPUUsageView {
        GPUUsageView(snapshot: snapshot)
    }
}

/// `$gpu`'s pane: for each GPU a ring of how busy it is, its renderer
/// and tiler stages (Apple) or memory, temperature and power (NVIDIA, AMD);
/// then the processes keeping it busy, or holding its memory.
struct GPUUsageView: View {
    let snapshot: GPUSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let host = snapshot.host {
                    Label("\(host) · \(snapshot.platform.title)", systemImage: "server.rack")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(snapshot.devices.enumerated()), id: \.offset) { _, device in
                    GPUDeviceView(device: device)
                }
                if !snapshot.processes.isEmpty {
                    processes
                }
                ReportPasteHint()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var processes: some View {
        let byTime = snapshot.processes.allSatisfy { $0.usage != nil }
        let largest = snapshot.processes.map { $0.usage ?? Double($0.memory ?? 0) }.max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            ReportHeading(title: byTime ? "Busiest processes" : "GPU memory by process")
            ForEach(snapshot.processes, id: \.pid) { process in
                let weight = process.usage ?? Double(process.memory ?? 0)
                ReportProcessRow(
                    pid: process.pid, name: process.name, isRemote: snapshot.host != nil,
                    fraction: weight / max(largest, .leastNonzeroMagnitude),
                    value: process.usage.map(CPUUsageCommand.percent) ?? process.memory.map(ReportStyle.memorySize) ?? "")
            }
        }
    }
}

/// One GPU: its name and cores over a ring of how busy it is, with what
/// else it reports beside the ring.
private struct GPUDeviceView: View {
    let device: GPUDevice

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "square.grid.3x3.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(ReportStyle.primary.gradient)
                    .frame(width: 36, height: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text(device.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    if let cores = device.coreCount {
                        Text("\(cores) GPU cores")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if let temperature = device.temperature {
                    TemperatureBadge(celsius: temperature)
                }
            }
            HStack(alignment: .center, spacing: 20) {
                UsageRing(fraction: device.utilization, color: ReportStyle.fullness(device.utilization), caption: "busy")
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 10) {
                    if let renderer = device.renderer {
                        stage("Renderer", renderer, color: ReportStyle.primary)
                    }
                    if let tiler = device.tiler {
                        stage("Tiler", tiler, color: ReportStyle.secondary)
                    }
                    if let used = device.memoryUsed {
                        memory(used: used, total: device.memoryTotal)
                    }
                    if let power = device.power {
                        LegendRow(color: ReportStyle.tertiary, title: "Power", value: String(format: "%.0f W", power))
                    }
                }
            }
        }
    }

    /// A label and percentage over a thin bar.
    private func stage(_ title: String, _ share: Double, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(CPUUsageCommand.percent(share))
                    .monospacedDigit()
                    .fontWeight(.medium)
                    .contentTransition(.numericText())
            }
            SegmentedBar(segments: [BarSegment(id: title, value: Int64(share * 1000), color: color)], total: 1000, height: 6)
        }
        .accessibilityElement(children: .combine)
    }

    /// Video memory against its size; the shared memory Apple's GPUs use as
    /// a figure only.
    @ViewBuilder
    private func memory(used: Int64, total: Int64?) -> some View {
        if let total, total > 0 {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Memory")
                    Spacer()
                    Text("\(ReportStyle.memorySize(used)) of \(ReportStyle.memorySize(total))")
                        .monospacedDigit()
                        .fontWeight(.medium)
                        .contentTransition(.numericText())
                }
                SegmentedBar(
                    segments: [BarSegment(id: "memory", value: used, color: ReportStyle.fullness(Double(used) / Double(total)))],
                    total: total, height: 6)
            }
            .accessibilityElement(children: .combine)
        } else {
            LegendRow(color: ReportStyle.tertiary, title: "Memory in use", value: ReportStyle.memorySize(used))
        }
    }
}
