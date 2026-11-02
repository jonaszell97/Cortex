import AppKit
import SwiftUI
import CortexCore

struct ClipRowView: View {
    static let mask = "••••••••"

    let item: ClipSummary
    let shortcutNumber: Int?
    let isSelected: Bool
    let isRevealing: Bool

    private var isMasked: Bool { item.isSensitive && !isRevealing }

    var body: some View {
        HStack(spacing: 10) {
            leadingIcon
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(isMasked ? Self.mask : item.preview)
                    .lineLimit(1)
                    .truncationMode(.tail)
                HStack(spacing: 4) {
                    if let bundleID = item.sourceBundleID, let icon = AppIconCache.shared.icon(for: bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 12, height: 12)
                    }
                    Text([item.sourceAppName, RelativeTime.string(for: item.lastCopiedAt)]
                        .compactMap { $0 }
                        .joined(separator: " · "))
                }
                .font(.caption)
                .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }

            Spacer(minLength: 4)

            if item.isPinned {
                Image(systemName: "pin.fill")
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
            if let shortcutNumber {
                Text("⌘\(shortcutNumber)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .foregroundStyle(isSelected ? .white : .primary)
        .paletteSelection(isSelected)
    }

    @ViewBuilder
    private var leadingIcon: some View {
        if item.kind == .image, !isMasked, let data = item.thumbnail, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 32, height: 32)
                .clipShape(.rect(cornerRadius: 4))
        } else if !isMasked, let color = Self.color(of: item) {
            ColorSwatch(color: color)
                .frame(width: 24, height: 24)
        } else {
            Image(systemName: Self.symbol(for: item))
                .font(.title3)
                .foregroundStyle(isSelected ? .white : .secondary)
        }
    }

    /// A text clip that is nothing but a colour (`#1A2B3C`, `rgb(…)`): picked
    /// with the Color Picker or copied from a design tool or stylesheet.
    static func color(of item: ClipSummary) -> ColorValue? {
        item.kind == .text ? ColorParser.parse(item.preview) : nil
    }

    static func symbol(for item: ClipSummary) -> String {
        if item.isSensitive { return "key.fill" }
        return switch item.kind {
        case .text: "text.alignleft"
        case .richText: "doc.richtext"
        case .image: "photo"
        case .files: "doc.on.doc"
        }
    }
}

@MainActor
enum RelativeTime {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func string(for date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

/// App icons by bundle ID, looked up once per app.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var icons: [String: NSImage?] = [:]

    func icon(for bundleID: String) -> NSImage? {
        if let cached = icons[bundleID] { return cached }
        let icon = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            .map { NSWorkspace.shared.icon(forFile: $0.path) }
        icons[bundleID] = icon
        return icon
    }
}
