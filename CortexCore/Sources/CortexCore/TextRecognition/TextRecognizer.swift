import CoreGraphics
import Foundation
import ImageIO
import Vision

/// Recognises the text in an image. The app's tests hand in a fake.
public protocol TextRecognizing: Sendable {
    /// The text in reading order (`RecognizedLines`), "" if there is none.
    /// Throws if the data is not an image.
    func recognize(_ image: Data) async throws -> String
    /// The text of a screen capture, read as a document where it can be:
    /// columns one after the other, tables as tab-separated rows, and with
    /// `joinLines` the lines of a paragraph joined into one.
    func recognizeCapture(_ image: Data, joinLines: Bool) async throws -> String
}

public extension TextRecognizing {
    func recognizeCapture(_ image: Data, joinLines: Bool) async throws -> String {
        try await recognize(image)
    }
}

public enum TextRecognitionError: Error, CustomStringConvertible {
    case unreadableImage

    public var description: String {
        switch self {
        case .unreadableImage: "the data is not an image ImageIO can read"
        }
    }
}

/// Text recognition with Vision (`RecognizeTextRequest`), on this device and
/// offline.
///
/// Vision scales an image down until its longer side fits its model, so on a
/// whole screenshot it loses the small text: on a 2880 × 1800 screen most
/// 16–20 px text (sidebar and menu text at 2×), on a 5K screen nearly all of
/// it. Larger images are therefore read in overlapping tiles of `tileSize`.
/// Each tile keeps the words whose centre lies in its own part of the image,
/// so a line that crosses tiles is put back together word by word, without
/// duplicates.
public struct TextRecognizer: TextRecognizing {
    /// Tiles up to this size in pixels read all text from 16 px up (1600
    /// missed some on a 5K screen, 900 found no more than 1200).
    static let tileSize = 1200
    /// Wider than nearly any word at screenshot sizes, so a word cut by one
    /// tile's edge is whole in its neighbour.
    static let tileOverlap = 300

    /// Empty: the language is detected, with the system's preferred
    /// languages as hints. Otherwise only these.
    public var languages: [Locale.Language]

    public init(languages: [Locale.Language] = []) {
        self.languages = languages
    }

    /// The languages Vision can read, for a choice in Settings.
    public static var supportedLanguages: [Locale.Language] {
        RecognizeTextRequest().supportedRecognitionLanguages
    }

    public func recognize(_ image: Data) async throws -> String {
        RecognizedLines.text(from: try await boxes(in: image))
    }

    /// A capture that fits one tile (nearly every one) is read with
    /// `RecognizeDocumentsRequest`, which knows columns, paragraphs and
    /// tables; it cannot be tiled, since a paragraph or table would be cut.
    /// A larger one is read like any image, line by line.
    public func recognizeCapture(_ image: Data, joinLines: Bool) async throws -> String {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TextRecognitionError.unreadableImage }
        guard cgImage.width <= Self.tileSize, cgImage.height <= Self.tileSize else {
            return try await recognize(image)
        }
        var request = RecognizeDocumentsRequest()
        let (automatic, languages) = recognitionLanguages(supported: request.supportedRecognitionLanguages)
        request.textRecognitionOptions.automaticallyDetectLanguage = automatic
        if !languages.isEmpty { request.textRecognitionOptions.recognitionLanguages = languages }
        request.textRecognitionOptions.useLanguageCorrection = true
        let documents = try await request.perform(on: cgImage)
        return documents
            .map { DocumentText.text(of: $0.document, joinLines: joinLines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// The recognised words in pixels, origin at the bottom left.
    public func boxes(in image: Data) async throws -> [RecognizedBox] {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { throw TextRecognitionError.unreadableImage }
        let orientation = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])?[kCGImagePropertyOrientation]
            .flatMap { $0 as? UInt32 }
            .flatMap(CGImagePropertyOrientation.init(rawValue:))

        // A rotated photo is read whole: its text is rarely small, and tiles
        // would have to be cut from the image as displayed. Normalised
        // coordinates are relative to the image as displayed, so width and
        // height swap for a quarter turn.
        if let orientation, orientation != .up {
            let quarterTurn = [.left, .leftMirrored, .right, .rightMirrored].contains(orientation)
            let size = quarterTurn
                ? CGSize(width: cgImage.height, height: cgImage.width)
                : CGSize(width: cgImage.width, height: cgImage.height)
            let observations = try await request.perform(on: cgImage, orientation: orientation)
            return Self.words(in: observations, tile: CGRect(origin: .zero, size: size), core: nil)
        }

        let width = cgImage.width, height = cgImage.height
        var boxes: [RecognizedBox] = []
        for row in Self.tiles(length: height) {
            for column in Self.tiles(length: width) {
                try Task.checkCancellation()
                // `cropping(to:)` counts from the top, boxes from the bottom.
                let crop = CGRect(x: column.start, y: row.start, width: column.length, height: row.length)
                guard let tileImage = cgImage.cropping(to: crop) else { continue }
                let bottom = CGFloat(height - row.start - row.length)
                let tile = CGRect(x: CGFloat(column.start), y: bottom, width: CGFloat(column.length), height: CGFloat(row.length))
                let core = CGRect(
                    x: CGFloat(column.coreStart), y: CGFloat(height - row.coreEnd),
                    width: CGFloat(column.coreEnd - column.coreStart), height: CGFloat(row.coreEnd - row.coreStart))
                let observations = try await request.perform(on: tileImage)
                boxes += Self.words(in: observations, tile: tile, core: core)
            }
        }
        return boxes
    }

    /// One tile along one axis, in pixels from the start: what is read, and
    /// the part whose words this tile keeps (the overlaps are split in the
    /// middle).
    struct Tile: Equatable {
        var start: Int
        var length: Int
        var coreStart: Int
        var coreEnd: Int
    }

    /// Evenly spaced tiles of at most `tileSize` that overlap by at least
    /// `tileOverlap`; one tile if the image is no longer than that.
    static func tiles(length: Int, size: Int = tileSize, overlap: Int = tileOverlap) -> [Tile] {
        guard length > size else { return [Tile(start: 0, length: length, coreStart: 0, coreEnd: length)] }
        let count = Int((Double(length - overlap) / Double(size - overlap)).rounded(.up))
        let starts = (0..<count).map { Int((Double($0) * Double(length - size) / Double(count - 1)).rounded()) }
        return starts.indices.map { index in
            let end = starts[index] + size
            let coreStart = index == 0 ? 0 : (starts[index] + starts[index - 1] + size) / 2
            let coreEnd = index == count - 1 ? length : (end + starts[index + 1]) / 2
            return Tile(start: starts[index], length: size, coreStart: coreStart, coreEnd: coreEnd)
        }
    }

    /// The words of the observations in image pixels. Vision's coordinates
    /// are normalised to `tile`; a word whose centre is outside `core` is
    /// left to the neighbouring tile.
    static func words(in observations: [RecognizedTextObservation], tile: CGRect, core: CGRect?) -> [RecognizedBox] {
        func pixels(_ corners: [NormalizedPoint]) -> CGRect {
            let xs = corners.map(\.x), ys = corners.map(\.y)
            return CGRect(
                x: tile.minX + xs.min()! * tile.width, y: tile.minY + ys.min()! * tile.height,
                width: (xs.max()! - xs.min()!) * tile.width, height: (ys.max()! - ys.min()!) * tile.height)
        }
        var boxes: [RecognizedBox] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let line = pixels([observation.topLeft, observation.topRight, observation.bottomRight, observation.bottomLeft])
            let text = candidate.string
            var index = text.startIndex
            while let start = text[index...].firstIndex(where: { !$0.isWhitespace }) {
                let end = text[start...].firstIndex(where: \.isWhitespace) ?? text.endIndex
                index = end
                // Without a box of its own, a word is placed at its line.
                let bounds = candidate.boundingBox(for: start..<end)
                    .map { pixels([$0.topLeft, $0.topRight, $0.bottomRight, $0.bottomLeft]) } ?? line
                if let core, !core.contains(CGPoint(x: bounds.midX, y: bounds.midY)) { continue }
                boxes.append(RecognizedBox(text: String(text[start..<end]), bounds: bounds))
            }
        }
        return boxes
    }

    private var request: RecognizeTextRequest {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let (automatic, languages) = recognitionLanguages(supported: request.supportedRecognitionLanguages)
        request.automaticallyDetectsLanguage = automatic
        if !languages.isEmpty { request.recognitionLanguages = languages }
        return request
    }

    /// With no languages chosen: detected, with the system's preferred
    /// languages as hints. Otherwise only the chosen ones.
    private func recognitionLanguages(supported: [Locale.Language]) -> (automatic: Bool, languages: [Locale.Language]) {
        guard languages.isEmpty else { return (false, languages) }
        // "en-DE" is not a language Vision lists; its "en-US" is.
        var hints: [Locale.Language] = []
        for identifier in Locale.preferredLanguages {
            let code = Locale.Language(identifier: identifier).languageCode
            if let match = supported.first(where: { $0.languageCode == code }), !hints.contains(match) {
                hints.append(match)
            }
        }
        return (true, hints)
    }
}
