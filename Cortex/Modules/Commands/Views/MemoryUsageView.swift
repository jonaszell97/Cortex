import SwiftUI
import CortexCore

extension MemoryUsageCommand: ReportPresenting {
    func reportView(for snapshot: MemorySnapshot) -> MemoryUsageView {
        MemoryUsageView(snapshot: snapshot)
    }
}

/// `$mem`'s pane: the physical memory as one bar (app memory, wired or
/// kernel, compressed, cached files, free) with the pressure beside it,
/// swap, and the largest processes with their icons and bars. A host's has
/// its name on top and no pressure.
struct MemoryUsageView: View {
    let snapshot: MemorySnapshot

    private static let app = ReportStyle.primary
    private static let wired = ReportStyle.tertiary
    private static let compressed = ReportStyle.secondary
    private static let cached = Color.secondary.opacity(0.45)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                VStack(alignment: .leading, spacing: 8) {
                    SegmentedBar(
                        segments: [
                            BarSegment(id: "app", value: snapshot.appMemory, color: Self.app),
                            BarSegment(id: "wired", value: snapshot.wired, color: Self.wired),
                            BarSegment(id: "compressed", value: snapshot.compressed, color: Self.compressed),
                            BarSegment(id: "cached", value: snapshot.cachedFiles, color: Self.cached),
                        ],
                        total: snapshot.physical, height: 18)
                    LegendRow(color: Self.app, title: "App memory", value: ReportStyle.memorySize(snapshot.appMemory))
                    LegendRow(color: Self.wired, title: snapshot.wiredTitle, value: ReportStyle.memorySize(snapshot.wired))
                    if snapshot.platform == .mac || snapshot.compressed > 0 {
                        LegendRow(color: Self.compressed, title: "Compressed", value: ReportStyle.memorySize(snapshot.compressed))
                    }
                    LegendRow(color: Self.cached, title: "Cached files", value: ReportStyle.memorySize(snapshot.cachedFiles))
                }
                if let used = snapshot.swapUsed, let total = snapshot.swapTotal {
                    swap(used: used, total: total)
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
            Image(systemName: snapshot.host == nil ? "memorychip" : "server.rack")
                .font(.system(size: 22))
                .foregroundStyle(ReportStyle.primary.gradient)
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 1) {
                if let host = snapshot.host {
                    Text("\(host) · \(snapshot.platform.title)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                Text("\(ReportStyle.memorySize(snapshot.used)) used")
                    .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("of \(ReportStyle.memorySize(snapshot.physical)) · \(ReportStyle.memorySize(snapshot.free)) free")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let pressure = snapshot.pressure {
                PressureBadge(pressure: pressure)
            }
        }
    }

    private func swap(used: Int64, total: Int64) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                ReportHeading(title: "Swap")
                Spacer()
                Text(total > 0 ? "\(ReportStyle.memorySize(used)) of \(ReportStyle.memorySize(total))" : "None")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            if total > 0 {
                SegmentedBar(
                    segments: [BarSegment(
                        id: "swap", value: used, color: ReportStyle.fullness(Double(used) / Double(total)))],
                    total: total, height: 6)
            }
        }
    }

    private var processes: some View {
        let largest = snapshot.processes.map(\.residentBytes).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            ReportHeading(title: snapshot.host == nil ? "Your largest processes" : "Largest processes")
            ForEach(snapshot.processes, id: \.pid) { process in
                ReportProcessRow(
                    pid: process.pid, name: process.name, path: process.path, isRemote: snapshot.host != nil,
                    fraction: Double(process.residentBytes) / Double(max(largest, 1)),
                    value: ReportStyle.memorySize(process.residentBytes))
            }
        }
    }
}

/// Activity Monitor's memory pressure: a dot and a word in its colour.
private struct PressureBadge: View {
    let pressure: MemoryPressure

    private var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    private var title: String {
        switch pressure {
        case .normal: "Normal"
        case .warning: "Elevated"
        case .critical: "Critical"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color.gradient)
                .frame(width: 7, height: 7)
                .shadow(color: color.opacity(0.7), radius: 3)
            Text(title)
                .font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(color.opacity(0.15), in: .capsule)
        .help("Memory pressure")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Memory pressure \(title)")
    }
}
