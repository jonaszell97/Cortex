import SwiftUI
import CortexCore

/// Markdown blocks (`MarkdownBlock.parse`) as native views. Inline styles and
/// links come from the attributed strings; web links open in the browser.
///
/// Shared with the iOS app (project.yml), so SwiftUI only.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]
    /// The file an image refers to, if it is in the knowledge folder.
    let resolveFile: (String) -> URL?
    /// The checklist item of each tappable checkbox, by block ID
    /// (`MarkdownBlock.checklistIndices`).
    var checklistIndices: [Int: Int] = [:]
    /// Ticks or unticks a checklist item; nil leaves the boxes read-only.
    var toggleChecklistItem: ((Int) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(blocks) { block in
                BlockView(block: block, resolveFile: resolveFile, toggle: toggle(for: block))
                    .padding(.leading, CGFloat(block.quoteDepth) * 12)
                    .overlay(alignment: .leading) {
                        if block.quoteDepth > 0 {
                            Rectangle()
                                .fill(.quaternary)
                                .frame(width: 3)
                        }
                    }
            }
        }
        .environment(\.openURL, OpenURLAction { url in
            // Links between notes are not followed yet; web links are.
            ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") ? .systemAction : .discarded
        })
    }

    private func toggle(for block: MarkdownBlock) -> (() -> Void)? {
        guard let toggleChecklistItem, let index = checklistIndices[block.id] else { return nil }
        return { toggleChecklistItem(index) }
    }
}

private struct BlockView: View {
    let block: MarkdownBlock
    let resolveFile: (String) -> URL?
    /// A checkbox's tap.
    let toggle: (() -> Void)?

    var body: some View {
        switch block.kind {
        case .heading(let level, let text):
            Text(text)
                .font(Self.font(forHeading: level))
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(text)
        case .listItem(let text, let depth, let marker):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if let toggle {
                    // Only the box: the text keeps its links and selection.
                    Button(action: toggle) {
                        ListMarkerView(marker: marker)
                            .frame(minWidth: 18, minHeight: 28, alignment: .trailing)
                            .contentShape(Rectangle().inset(by: -8))
                    }
                    .buttonStyle(.plain)
                    .sensoryFeedback(.selection, trigger: marker)
                    .accessibilityLabel(String(text.characters))
                    .accessibilityValue(marker == .checkbox(isDone: true) ? "Done" : "Not done")
                } else {
                    ListMarkerView(marker: marker)
                        .frame(minWidth: 18, alignment: .trailing)
                }
                Text(text)
                    .foregroundStyle(marker == .checkbox(isDone: true) ? .secondary : .primary)
            }
            .padding(.leading, CGFloat(depth - 1) * 20)
        case .code(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        case .image(let source, let alt):
            if let url = resolveFile(source), let image = PlatformImage(contentsOfFile: url.path(percentEncoded: false)) {
                Image(platformImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .accessibilityLabel(alt)
            } else {
                Label(alt.isEmpty ? source : alt, systemImage: "photo")
                    .foregroundStyle(.secondary)
            }
        case .table(let header, let rows):
            ScrollView(.horizontal, showsIndicators: false) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                    GridRow {
                        ForEach(header.indices, id: \.self) { Text(header[$0]).bold() }
                    }
                    Divider()
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { Text(rows[row][$0]) }
                        }
                    }
                }
                .font(.callout)
            }
        case .rule:
            Divider()
        }
    }

    static func font(forHeading level: Int) -> Font {
        switch level {
        case 1: .title2.bold()
        case 2: .title3.bold()
        case 3: .headline
        default: .subheadline.bold()
        }
    }
}

private struct ListMarkerView: View {
    let marker: MarkdownBlock.ListMarker?

    var body: some View {
        switch marker {
        case .bullet?: Text("•")
        case .number(let number)?: Text("\(number).").monospacedDigit()
        case .checkbox(let isDone)?:
            Image(systemName: isDone ? "checkmark.square.fill" : "square")
                .foregroundStyle(isDone ? Color.secondary : Color.accentColor)
        case nil: Text("")
        }
    }
}

#if canImport(UIKit)
import UIKit

private typealias PlatformImage = UIImage

private extension Image {
    init(platformImage: UIImage) { self.init(uiImage: platformImage) }
}
#else
import AppKit

private typealias PlatformImage = NSImage

private extension Image {
    init(platformImage: NSImage) { self.init(nsImage: platformImage) }
}
#endif
