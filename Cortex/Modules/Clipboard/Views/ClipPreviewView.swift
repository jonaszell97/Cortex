import AppKit
import SwiftUI
import CortexCore

/// Quick preview of the selected clip: full text, image or file list.
/// Sensitive clips stay hidden unless ⌥ is held.
struct ClipPreviewView: View {
    let detail: ClipDetail?
    let isRevealing: Bool

    var body: some View {
        if let detail {
            VStack(alignment: .leading, spacing: 0) {
                content(detail)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                footer(detail.item)
            }
        } else {
            Color.clear
        }
    }

    @ViewBuilder
    private func content(_ detail: ClipDetail) -> some View {
        if detail.item.isSensitive && !isRevealing {
            ContentUnavailableView(
                "Sensitive",
                systemImage: "eye.slash",
                description: Text("Hold ⌥ to reveal."))
        } else if let color = Self.color(of: detail) {
            ColorClipPreview(color: color)
        } else {
            switch Self.displayKind(detail) {
            case .image:
                if let data = detail.imageData, let image = NSImage(data: data) {
                    VStack(spacing: 0) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .padding(16)
                        if let text = detail.item.imageText {
                            Divider()
                            imageText(text)
                        }
                    }
                }
            case .files:
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(detail.fileURLs, id: \.self) { url in
                            HStack(spacing: 8) {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                    .resizable()
                                    .frame(width: 20, height: 20)
                                VStack(alignment: .leading) {
                                    Text(url.lastPathComponent)
                                    Text(url.deletingLastPathComponent().path)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .truncationMode(.middle)
                                }
                                .lineLimit(1)
                            }
                        }
                    }
                    .padding(16)
                }
            case .text, .richText:
                ScrollView {
                    Text(Self.formattedText(detail) ?? AttributedString(TextPreview.previewText(detail.item.plainText ?? "")))
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(16)
                }
            }
        }
    }

    /// The text read from the image, below it (docs/modules/TEXT_RECOGNITION.md,
    /// "In the palette").
    private func imageText(_ text: String) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                Text("Text in image")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(TextPreview.previewText(text))
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(16)
        }
        .frame(maxHeight: 160)
    }

    private func footer(_ item: ClipItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let app = item.sourceAppName {
                Text(app)
            }
            Text("\(item.lastCopiedAt.formatted(date: .abbreviated, time: .shortened)) · \(ByteCountFormatter.string(fromByteCount: Int64(item.byteSize), countStyle: .file))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    /// A text clip that is nothing but a colour.
    static func color(of detail: ClipDetail) -> ColorValue? {
        guard detail.item.kind == .text, let text = detail.item.plainText else { return nil }
        return ColorParser.parse(text)
    }

    /// Items recorded before image copies with an RTFD were classified as
    /// images were stored as rich text without any text; show their image.
    static func displayKind(_ detail: ClipDetail) -> ClipItem.Kind {
        let item = detail.item
        guard item.kind == .richText, detail.imageData != nil else { return item.kind }
        let hasText = (item.plainText ?? "").contains { !$0.isWhitespace && $0 != "\u{FFFC}" }
        return hasText ? .richText : .image
    }

    /// Rich text from the stored RTF or RTFD: fonts, bold, italic, underline.
    /// HTML-only items show as plain text (HTML import needs WebKit and is
    /// slow).
    static func formattedText(_ detail: ClipDetail) -> AttributedString? {
        guard let rich = richPreview(detail) else { return nil }
        var result = AttributedString()
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            var run = AttributedString(rich.attributedSubstring(from: range).string)
            if let font = attributes[.font] as? NSFont {
                run.font = Font(font as CTFont)
            }
            if let underline = attributes[.underlineStyle] as? Int, underline != 0 {
                run.underlineStyle = .single
            }
            if let strikethrough = attributes[.strikethroughStyle] as? Int, strikethrough != 0 {
                run.strikethroughStyle = .single
            }
            result += run
        }
        return result
    }

    /// The stored RTFD or RTF, cut to the preview limit, without text and
    /// background colours (so it reads in light and dark mode) and without
    /// attachments.
    static func richPreview(_ detail: ClipDetail) -> NSAttributedString? {
        guard detail.item.kind == .richText else { return nil }
        let maxBytes = 2_000_000
        let rich: NSAttributedString?
        if let rtfd = detail.data(for: ClipType.flatRTFD), rtfd.count < maxBytes {
            rich = NSAttributedString(rtfd: rtfd, documentAttributes: nil)
        } else if let rtf = detail.data(for: ClipType.rtf), rtf.count < maxBytes {
            rich = NSAttributedString(rtf: rtf, documentAttributes: nil)
        } else {
            rich = nil
        }
        guard let rich else { return nil }

        let text = NSMutableAttributedString(attributedString: rich.length > TextPreview.previewLimit
            ? rich.attributedSubstring(from: NSRange(location: 0, length: TextPreview.previewLimit))
            : rich)
        let all = NSRange(location: 0, length: text.length)
        text.removeAttribute(.foregroundColor, range: all)
        text.removeAttribute(.backgroundColor, range: all)
        text.removeAttribute(.attachment, range: all)
        return text
    }
}
