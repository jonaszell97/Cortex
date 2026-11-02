import AppKit
import SwiftUI
import CortexCore

extension DiskSpaceCommand: ReportPresenting {
    func reportView(for volume: VolumeSpace) -> DiskSpaceView {
        DiskSpaceView(volume: volume)
    }
}

/// `$disk`'s pane: the volume with its icon (a server for a host's), a ring of how full it is
/// with the free space beside it, and a bar of used, purgeable and free.
struct DiskSpaceView: View {
    let volume: VolumeSpace

    private var usedFraction: Double {
        volume.total > 0 ? Double(volume.used) / Double(volume.total) : 0
    }

    /// Used without what macOS would free.
    private var occupied: Int64 { max(volume.used - volume.purgeable, 0) }
    private var color: Color { ReportStyle.fullness(usedFraction) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                HStack(spacing: 20) {
                    UsageRing(
                        fraction: usedFraction,
                        paleFraction: volume.total > 0 ? Double(volume.purgeable) / Double(volume.total) : 0,
                        color: color)
                        .frame(width: 112, height: 112)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(ReportStyle.fileSize(volume.available))
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                            .contentTransition(.numericText())
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                        Text("free of \(ReportStyle.fileSize(volume.total))")
                            .foregroundStyle(.secondary)
                        if volume.purgeable > 0 {
                            Text("\(ReportStyle.fileSize(volume.available + volume.purgeable)) once purged")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    SegmentedBar(
                        segments: [
                            BarSegment(id: "used", value: occupied, color: color),
                            BarSegment(id: "purgeable", value: volume.purgeable, color: color.opacity(0.4)),
                        ],
                        total: volume.total)
                    LegendRow(color: color, title: "Used", value: ReportStyle.fileSize(occupied))
                    if volume.purgeable > 0 {
                        LegendRow(
                            color: color.opacity(0.4), title: "Purgeable", value: ReportStyle.fileSize(volume.purgeable),
                            note: "freed when needed")
                    }
                    LegendRow(color: Color.secondary.opacity(0.3), title: "Free", value: ReportStyle.fileSize(volume.available))
                }
                ReportPasteHint()
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if volume.host == nil {
                Image(nsImage: NSWorkspace.shared.icon(forFile: volume.path))
                    .resizable()
                    .frame(width: 36, height: 36)
            } else {
                Image(systemName: "server.rack")
                    .font(.system(size: 22))
                    .foregroundStyle(ReportStyle.primary.gradient)
                    .frame(width: 36, height: 36)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(volume.name)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                Text(([volume.host.map { _ in "over SSH" }, volume.fileSystem].compactMap { $0 } + [volume.path])
                    .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
