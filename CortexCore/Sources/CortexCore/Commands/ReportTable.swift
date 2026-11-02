import Foundation

/// The short monospaced tables `$disk` and `$mem` paste: labels
/// left, values right-aligned, an optional note after them.
enum ReportTable {
    struct Row: Equatable {
        var label: String
        var value: String
        var note: String?

        init(_ label: String, _ value: String, note: String? = nil) {
            self.label = label
            self.value = value
            self.note = note
        }
    }

    static func format(_ rows: [Row]) -> String {
        let labelWidth = rows.map(\.label.count).max() ?? 0
        let valueWidth = rows.map(\.value.count).max() ?? 0
        return rows.map { row in
            let line = pad(row.label, to: labelWidth) + "  " + String(repeating: " ", count: valueWidth - row.value.count) + row.value
            return row.note.map { line + "  " + $0 } ?? line
        }
        .joined(separator: "\n")
    }

    /// `text` with spaces after it up to `width`.
    static func pad(_ text: String, to width: Int) -> String {
        text + String(repeating: " ", count: max(width - text.count, 0))
    }

    /// "994.7 GB", as Finder counts (powers of 1000).
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "24 GB" for 24 GiB, as Activity Monitor counts (powers of 1024).
    static func memory(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .memory)
    }
}
