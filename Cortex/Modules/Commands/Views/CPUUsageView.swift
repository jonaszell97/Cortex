import SwiftUI
import CortexCore

extension CPUUsageCommand: ReportPresenting {
    func reportView(for snapshot: CPUSnapshot) -> CPUUsageView {
        CPUUsageView(snapshot: snapshot)
    }
}

/// `$cpu`'s pane: how busy the CPU is with the user and system shares as
/// one bar, a column per core, the load average, the temperature where the
/// host has one, and the busiest processes.
struct CPUUsageView: View {
    let snapshot: CPUSnapshot

    private static let user = ReportStyle.primary
    private static let system = ReportStyle.secondary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 8) {
                    SegmentedBar(
                        segments: [
                            BarSegment(id: "user", value: Int64(snapshot.user * 1000), color: Self.user),
                            BarSegment(id: "system", value: Int64(snapshot.system * 1000), color: Self.system),
                        ],
                        total: 1000, height: 18)
                    LegendRow(color: Self.user, title: "User", value: CPUUsageCommand.percent(snapshot.user))
                    LegendRow(color: Self.system, title: "System", value: CPUUsageCommand.percent(snapshot.system))
                    LegendRow(color: Color.secondary.opacity(0.3), title: "Idle", value: CPUUsageCommand.percent(snapshot.idle))
                }
                if !snapshot.cores.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ReportHeading(title: "Cores")
                        CoreColumns(cores: snapshot.cores)
                    }
                }
                if snapshot.loadAverage.count == 3 {
                    loadAverage
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

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: snapshot.host == nil ? "cpu" : "server.rack")
                .font(.system(size: 22))
                .foregroundStyle(ReportStyle.primary.gradient)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                if let host = snapshot.host {
                    Text("\(host) · \(snapshot.platform.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("\(CPUUsageCommand.percent(snapshot.busy)) busy")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                    .foregroundStyle(snapshot.busy >= 0.8 ? ReportStyle.fullness(snapshot.busy) : .primary)
                let model = [snapshot.model, snapshot.coreCount > 0 ? "\(snapshot.coreCount) cores" : nil].compactMap { $0 }
                if !model.isEmpty {
                    Text(model.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let temperature = snapshot.temperature {
                TemperatureBadge(celsius: temperature)
            }
        }
    }

    /// Three chips; each turns orange, then red, as the load passes the
    /// number of cores.
    private var loadAverage: some View {
        VStack(alignment: .leading, spacing: 6) {
            ReportHeading(title: "Load average")
            HStack(spacing: 8) {
                ForEach(Array(zip(["1 min", "5 min", "15 min"], snapshot.loadAverage)), id: \.0) { label, load in
                    let pressure = snapshot.coreCount > 0 ? load / Double(snapshot.coreCount) : 0
                    let color = pressure >= 1 ? Color.red : pressure >= 0.7 ? .orange : ReportStyle.primary
                    VStack(spacing: 1) {
                        Text(String(format: "%.2f", load))
                            .font(.system(.body, design: .rounded).weight(.semibold).monospacedDigit())
                            .contentTransition(.numericText())
                        Text(label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(color.opacity(0.14), in: .rect(cornerRadius: 8))
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private var processes: some View {
        let busiest = snapshot.processes.map(\.usage).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            ReportHeading(title: "Busiest processes")
            ForEach(snapshot.processes, id: \.pid) { process in
                ReportProcessRow(
                    pid: process.pid, name: process.name, isRemote: snapshot.host != nil,
                    fraction: process.usage / max(busiest, 0.01), value: CPUUsageCommand.percent(process.usage))
            }
        }
    }
}

/// A column per core, filled from the bottom as far as it was busy, in the
/// colour of how busy. They rise when they appear.
private struct CoreColumns: View {
    let cores: [Double]
    @State private var isShown = false

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 14, maximum: 32), spacing: 4)], spacing: 6) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, busy in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.quaternary)
                    RoundedRectangle(cornerRadius: 3)
                        .fill(ReportStyle.fullness(busy).gradient)
                        .frame(height: max(36 * (isShown ? busy : 0), 2))
                }
                .frame(height: 36)
                .help("Core \(index + 1): \(CPUUsageCommand.percent(busy))")
                .accessibilityLabel("Core \(index + 1), \(CPUUsageCommand.percent(busy)) busy")
            }
        }
        .onAppear {
            withAnimation(.spring(duration: 0.7)) { isShown = true }
        }
    }
}
