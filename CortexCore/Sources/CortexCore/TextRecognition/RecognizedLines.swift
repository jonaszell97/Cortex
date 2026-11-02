import CoreGraphics
import Foundation

/// One piece of recognised text and where it is in the image, in pixels
/// with the origin at the bottom left (Vision's orientation). Pixels rather
/// than Vision's 0…1, so horizontal and vertical distances compare.
public struct RecognizedBox: Sendable, Equatable {
    public var text: String
    public var bounds: CGRect

    public init(text: String, bounds: CGRect) {
        self.text = text
        self.bounds = bounds
    }
}

/// Puts recognised boxes back into reading order: top to bottom, then left
/// to right. Vision returns them in no promised order.
public enum RecognizedLines {
    /// Two boxes are on the same line when their vertical ranges overlap by
    /// at least this share of the lower one's height.
    static let sameLineOverlap: CGFloat = 0.5
    /// A horizontal gap wider than this many line heights separates columns
    /// (or table cells) and becomes a tab instead of a space.
    static let columnGap: CGFloat = 2

    /// The boxes as text: one line per row of boxes, joined with `\n`.
    public static func text(from boxes: [RecognizedBox]) -> String {
        lines(from: boxes).map(join).joined(separator: "\n")
    }

    /// Rows of boxes, top to bottom, each left to right.
    static func lines(from boxes: [RecognizedBox]) -> [[RecognizedBox]] {
        let boxes = boxes.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var lines: [[RecognizedBox]] = []
        // Top to bottom. A box joins the line whose newest box it overlaps
        // most, so the words of a slanted line chain together although its
        // first and last word do not overlap.
        for box in boxes.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            let best = lines.indices
                .map { (index: $0, overlap: overlap(lines[$0].last!.bounds, box.bounds)) }
                .filter { $0.overlap >= sameLineOverlap }
                .max { $0.overlap < $1.overlap }
            if let best {
                lines[best.index].append(box)
            } else {
                lines.append([box])
            }
        }
        return lines.map { $0.sorted { $0.bounds.minX < $1.bounds.minX } }
    }

    /// The vertical overlap of two boxes as a share of the lower one's height.
    private static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let overlap = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        let lower = min(a.height, b.height)
        return lower > 0 ? overlap / lower : 0
    }

    private static func join(_ line: [RecognizedBox]) -> String {
        var result = ""
        for (index, box) in line.enumerated() {
            if index > 0 {
                let previous = line[index - 1].bounds
                let gap = box.bounds.minX - previous.maxX
                result += gap > max(previous.height, box.bounds.height) * columnGap ? "\t" : " "
            }
            result += box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }
}
