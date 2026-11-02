import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pieces of the panes `$disk`, `$mem`, `$cpu` and `$gpu` draw (`ReportPresenting`).
enum ReportStyle {
    /// Accent colours of the parts of a bar, in order.
    static let primary = BrandColors.violet
    static let secondary = BrandColors.orchid
    static let tertiary = BrandColors.amber

    /// How full something is: the brand colours, then orange from 80 %, red
    /// from 92 %.
    static func fullness(_ fraction: Double) -> Color {
        if fraction >= 0.92 { return .red }
        if fraction >= 0.8 { return .orange }
        return primary
    }

    static func fileSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func memorySize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .memory)
    }
}

/// One part of a `SegmentedBar`.
struct BarSegment: Identifiable {
    let id: String
    let value: Int64
    let color: Color
}

/// A rounded bar split into parts of `total`; what is left is the empty
/// track. The parts grow in from the left when it appears.
struct SegmentedBar: View {
    let segments: [BarSegment]
    let total: Int64
    var height: CGFloat = 14
    @State private var isShown = false

    var body: some View {
        GeometryReader { proxy in
            HStack(spacing: 1.5) {
                ForEach(segments.filter { $0.value > 0 }) { segment in
                    Rectangle()
                        .fill(segment.color.gradient)
                        .frame(width: max(width(of: segment, in: proxy.size.width), 2))
                }
                Spacer(minLength: 0)
            }
            .frame(width: isShown ? proxy.size.width : 0, alignment: .leading)
            .clipped()
        }
        .frame(height: height)
        .background(.quaternary)
        .clipShape(.capsule)
        .onAppear {
            withAnimation(.spring(duration: 0.6)) { isShown = true }
        }
    }

    private func width(of segment: BarSegment, in width: CGFloat) -> CGFloat {
        guard total > 0 else { return 0 }
        let gaps = CGFloat(max(segments.filter { $0.value > 0 }.count - 1, 0)) * 1.5
        return (width - gaps) * CGFloat(Double(segment.value) / Double(total))
    }
}

/// A legend entry: a dot in the part's colour, its name, its size and a
/// note after it.
struct LegendRow: View {
    let color: Color
    let title: String
    let value: String
    var note: String?
    var isIndented = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle()
                .fill(color.gradient)
                .frame(width: 8, height: 8)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(title)
                .foregroundStyle(isIndented ? .secondary : .primary)
            Spacer(minLength: 8)
            if let note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(value)
                .monospacedDigit()
                .fontWeight(.medium)
                .contentTransition(.numericText())
        }
        .padding(.leading, isIndented ? 16 : 0)
        .accessibilityElement(children: .combine)
    }
}

/// The pane's last line: that ⏎ pastes the numbers as text.
struct ReportPasteHint: View {
    var body: some View {
        Label("⏎ pastes this as a text table", systemImage: "doc.plaintext")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A small caps heading over a part of a pane.
struct ReportHeading: View {
    let title: String

    var body: some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// A process: its app's icon, its name over a bar as long as `fraction`
/// (its share of the largest), and its figure.
struct ReportProcessRow: View {
    let pid: Int32
    let name: String
    /// Its executable, where known; otherwise its name.
    var path: String?
    /// On a host: its pid means nothing here, and its path only if the
    /// same app is installed here.
    let isRemote: Bool
    let fraction: Double
    let value: String
    @State private var isShown = false

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: Self.icon(pid: pid, path: path ?? name, isRemote: isRemote))
                .resizable()
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                GeometryReader { proxy in
                    Capsule()
                        .fill(ReportStyle.primary.opacity(0.75).gradient)
                        .frame(width: max(proxy.size.width * (isShown ? min(fraction, 1) : 0), 3))
                }
                .frame(height: 3)
            }
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
                .frame(minWidth: 64, alignment: .trailing)
        }
        .help("PID \(pid)")
        .accessibilityElement(children: .combine)
        .onAppear {
            withAnimation(.spring(duration: 0.6)) { isShown = true }
        }
    }

    /// The app it belongs to (the outermost bundle, so a browser's helpers
    /// show the browser), the running app's, or a terminal's for a tool.
    static func icon(pid: Int32, path: String, isRemote: Bool) -> NSImage {
        if let range = path.range(of: ".app/") {
            let app = String(path[..<range.lowerBound]) + ".app"
            if !isRemote || FileManager.default.fileExists(atPath: app) {
                return NSWorkspace.shared.icon(forFile: app)
            }
        }
        if !isRemote, let icon = NSRunningApplication(processIdentifier: pid)?.icon {
            return icon
        }
        return NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

/// A ring filled to `fraction` (how full a volume is, how busy a GPU), its
/// last `paleFraction` paler (purgeable space), the percentage and
/// `caption` inside. It fills up when it appears.
struct UsageRing: View {
    let fraction: Double
    var paleFraction: Double = 0
    let color: Color
    var caption = "used"
    @State private var isShown = false

    private let lineWidth: CGFloat = 12

    var body: some View {
        ZStack {
            Circle()
                .stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: isShown ? fraction : 0)
                .stroke(color.opacity(0.4), style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Circle()
                .trim(from: 0, to: isShown ? max(fraction - paleFraction, 0) : 0)
                .stroke(
                    AngularGradient(colors: [color.opacity(0.75), color], center: .center, startAngle: .zero,
                                    endAngle: .degrees(360 * max(fraction, 0.01))),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((fraction * 100).rounded())) %")
                    .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text(caption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(lineWidth / 2)
        .onAppear {
            withAnimation(.spring(duration: 0.8)) { isShown = true }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(Int((fraction * 100).rounded())) percent \(caption)")
    }
}

/// A CPU's or GPU's temperature: green, orange from 70 °C, red from 80 °C.
struct TemperatureBadge: View {
    let celsius: Double

    private var color: Color {
        celsius >= 80 ? .red : celsius >= 70 ? .orange : .green
    }

    var body: some View {
        Label(String(format: "%.0f °C", celsius), systemImage: "thermometer.medium")
            .font(.caption.weight(.medium).monospacedDigit())
            .contentTransition(.numericText())
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15), in: .capsule)
            .foregroundStyle(color)
            .help("Temperature")
    }
}
