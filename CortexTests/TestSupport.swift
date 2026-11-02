import AppKit
import ImageIO
import UniformTypeIdentifiers
@testable import Cortex
import CortexCore

/// A fresh encrypted database in a temporary directory.
func makeTestDatabase() throws -> AppDatabase {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "CortexTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try AppDatabase.open(at: directory.appending(path: "test.sqlite"), key: .generate())
}

/// A clip store on a fresh encrypted database in a temporary directory.
func makeTestStore() throws -> ClipStore {
    ClipStore(database: try makeTestDatabase())
}

/// A private pasteboard, so tests never touch the user's clipboard.
@MainActor
final class TestPasteboard {
    let pasteboard = NSPasteboard.withUniqueName()

    var name: NSPasteboard.Name { pasteboard.name }

    isolated deinit {
        pasteboard.releaseGlobally()
    }

    /// Replaces the content with one item holding the given types.
    func write(_ representations: [(NSPasteboard.PasteboardType, Data)]) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        for (type, data) in representations {
            item.setData(data, forType: type)
        }
        pasteboard.writeObjects([item])
    }

    func snapshot(source: PasteboardReader.SourceApp? = .textEdit) -> ClipSnapshot? {
        PasteboardReader.snapshot(
            of: pasteboard,
            types: (pasteboard.types ?? []).map(\.rawValue),
            source: source)
    }
}

extension PasteboardReader.SourceApp {
    static let textEdit = Self(bundleID: "com.apple.TextEdit", name: "TextEdit")
    static let safari = Self(bundleID: "com.apple.Safari", name: "Safari")
}

func rtfData(_ text: String) -> Data {
    let string = NSAttributedString(string: text, attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
    return string.rtf(from: NSRange(location: 0, length: string.length), documentAttributes: [:])!
}

/// A solid-colour image in the given format (PNG, TIFF, JPEG …).
func imageData(_ type: UTType, width: Int = 40, height: Int = 30) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.9, green: 0.3, blue: 0.1, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}

let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
