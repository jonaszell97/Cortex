import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import CortexCore

/// A fresh encrypted database in its own temporary directory.
func makeTestDatabase() throws -> AppDatabase {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "CortexCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return try AppDatabase.open(at: directory.appending(path: "test.sqlite"), key: .generate())
}

func textSnapshot(
    _ text: String,
    sensitive: Bool = false,
    app: String? = "TextEdit",
    at date: Date = .now
) -> ClipSnapshot {
    ClipSnapshot(
        representations: [LoadedRepresentation(type: ClipType.plainText, data: Data(text.utf8))],
        plainText: text,
        isSensitive: sensitive,
        sourceBundleID: app.map { "test.\($0)" },
        sourceAppName: app,
        copiedAt: date)
}

/// An image clip, copied from Preview unless said otherwise.
func imageSnapshot(
    _ png: Data = makePNG(),
    sensitive: Bool = false,
    app: String? = "Preview",
    at date: Date = .now
) -> ClipSnapshot {
    ClipSnapshot(
        representations: [LoadedRepresentation(type: ClipType.png, data: png)],
        plainText: nil,
        isSensitive: sensitive,
        sourceBundleID: app.map { "test.\($0)" },
        sourceAppName: app,
        copiedAt: date)
}

/// A solid-colour PNG.
func makePNG(width: Int = 64, height: Int = 48) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let output = NSMutableData()
    let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return output as Data
}
