import CoreGraphics
import Foundation
import Vision

/// Turns what `RecognizeDocumentsRequest` found into text: its paragraphs in
/// its reading order (which reads columns one after the other), each table
/// as tab-separated rows where it starts.
enum DocumentText {
    @available(macOS 26, *)
    static func text(of document: DocumentObservation.Container, joinLines: Bool) -> String {
        // Table cells are paragraphs too; they appear in their table only.
        var tables = document.tables.map { (bounds: $0.boundingRegion.boundingBox.cgRect, text: text(of: $0)) }
        var blocks: [String] = []
        for paragraph in document.paragraphs {
            let bounds = paragraph.boundingRegion.boundingBox.cgRect
            if tables.contains(where: { $0.bounds.contains(CGPoint(x: bounds.midX, y: bounds.midY)) }) { continue }
            // Tables that start above this paragraph come first (y grows
            // upwards).
            while let index = tables.firstIndex(where: { $0.bounds.maxY >= bounds.maxY }) {
                blocks.append(tables.remove(at: index).text)
            }
            blocks.append(text(of: paragraph, joinLines: joinLines))
        }
        blocks += tables.map(\.text)
        return blocks.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    @available(macOS 26, *)
    static func text(of table: DocumentObservation.Container.Table) -> String {
        table.rows
            .map { row in
                row.map { $0.content.text.transcript.replacingOccurrences(of: "\n", with: " ") }.joined(separator: "\t")
            }
            .joined(separator: "\n")
    }

    @available(macOS 26, *)
    static func text(of paragraph: DocumentObservation.Container.Text, joinLines: Bool) -> String {
        let lines = paragraph.lines.compactMap { $0.topCandidates(1).first?.string }
        guard !lines.isEmpty else { return paragraph.transcript }
        return joinLines ? join(lines) : lines.joined(separator: "\n")
    }

    /// The lines of a paragraph as one: with spaces, and without the hyphen
    /// of a word broken across lines ("recog-" "nition").
    static func join(_ lines: [String]) -> String {
        var result = ""
        for line in lines.map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
            if result.isEmpty {
                result = line
            } else if result.hasSuffix("-"), result.dropLast().last?.isLetter == true, line.first?.isLowercase == true {
                result = result.dropLast() + line
            } else {
                result += " " + line
            }
        }
        return result
    }
}
