import AppKit
import ImageIO
import CortexCore
import UniformTypeIdentifiers

/// Reads what is on a pasteboard as a `ClipSnapshot`: the representations
/// worth keeping, the plain text, whether it is sensitive and which app wrote
/// it. The Clipboard module records it; Quick Actions take it as input.
enum PasteboardReader {
    /// The app the content came from.
    struct SourceApp: Sendable {
        var bundleID: String?
        var name: String?

        @MainActor
        static func frontmost() -> SourceApp? {
            NSWorkspace.shared.frontmostApplication.map { SourceApp(bundleID: $0.bundleIdentifier, name: $0.localizedName) }
        }
    }

    /// Image types converted to PNG when no PNG or TIFF is present (Photos,
    /// Preview and browsers sometimes offer only these).
    private static let otherImageTypes = ["public.jpeg", "public.heic", "public.heif", "com.compuserve.gif", "public.webp"]

    static func snapshot(of pasteboard: NSPasteboard, types: [String], source: SourceApp?) -> ClipSnapshot? {
        var representations: [LoadedRepresentation] = []
        let available = Set(types)

        // The app that wrote the content, when it says so, beats the frontmost app.
        let writerBundleID = pasteboard.string(forType: Paster.sourceType)
        let bundleID = writerBundleID ?? source?.bundleID
        let appName = writerBundleID.flatMap(appName(forBundleID:)) ?? source?.name

        let fileURLs = (pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        if !fileURLs.isEmpty {
            // Finder adds an icon image and the file name as text: not worth keeping.
            representations.append(ClipSnapshot.fileURLRepresentation(fileURLs))
        } else if let png = pasteboard.data(forType: .png) {
            representations.append(LoadedRepresentation(type: ClipType.png, data: png))
        } else if let tiff = pasteboard.data(forType: .tiff) {
            // TIFF is often uncompressed and huge; keep PNG instead.
            representations.append(LoadedRepresentation(type: ClipType.png, data: convertToPNG(tiff) ?? tiff))
        } else if let type = otherImageTypes.first(where: available.contains),
                  let data = pasteboard.data(forType: .init(type)), let png = convertToPNG(data) {
            representations.append(LoadedRepresentation(type: ClipType.png, data: png))
        }

        if fileURLs.isEmpty {
            for type in [ClipType.flatRTFD, ClipType.rtf, ClipType.html] where available.contains(type) {
                if let data = pasteboard.data(forType: .init(type)), !data.isEmpty {
                    representations.append(LoadedRepresentation(type: type, data: data))
                }
            }
        }

        var plainText = pasteboard.string(forType: .string)
        if plainText == nil, let rtf = representations.first(where: { $0.type == ClipType.rtf })?.data {
            plainText = NSAttributedString(rtf: rtf, documentAttributes: nil)?.string
        }
        if let plainText, fileURLs.isEmpty {
            representations.append(LoadedRepresentation(type: ClipType.plainText, data: Data(plainText.utf8)))
        }

        let snapshot = ClipSnapshot(
            representations: representations,
            plainText: plainText,
            isSensitive: SensitivityRules.isSensitive(types: types, sourceBundleID: bundleID),
            sourceBundleID: bundleID,
            sourceAppName: appName)
        return snapshot.isEmpty ? nil : snapshot
    }

    private static func appName(forBundleID bundleID: String) -> String? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path).replacing(".app", with: "")
    }

    static func convertToPNG(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
