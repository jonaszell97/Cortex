#if os(macOS)
import Foundation
import PDFKit
import UniformTypeIdentifiers

/// What kind of file an action works on, by extension.
public enum FileKind: Sendable {
    case image, video, pdf, any

    public func matches(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        switch self {
        case .any:
            return true
        case .pdf:
            return pathExtension == "pdf"
        case .image:
            // sips reads these; SVG and PDF are images to UTType but not to sips.
            guard !["svg", "pdf"].contains(pathExtension), let type = UTType(filenameExtension: pathExtension) else { return false }
            return type.conforms(to: .image)
        case .video:
            if Self.extraVideoExtensions.contains(pathExtension) { return true }
            guard let type = UTType(filenameExtension: pathExtension) else { return false }
            return type.conforms(to: .movie)
        }
    }

    /// Containers ffmpeg reads that macOS has no movie type for.
    static let extraVideoExtensions: Set<String> = ["mkv", "webm", "avi", "flv", "wmv", "mts", "m2ts", "ts", "ogv"]
}

/// One source file being processed, and where its result goes.
public struct FileStep: Sendable {
    /// All files of the run; `source` is the one being processed (the first
    /// for actions that combine files).
    public var sources: [URL]
    public var source: URL
    public var outputDirectory: URL
    public var temporaryDirectory: URL
    /// Progress of this step, 0 to 1.
    public var progress: @Sendable (Double?) -> Void

    /// Lets `write` create the result at a scratch path, then moves it next
    /// to the source as `<name><suffix>.<extension>`, never replacing a file.
    public func produce(
        named fileName: String? = nil,
        suffix: String = "",
        pathExtension: String,
        write: (URL) async throws -> Void
    ) async throws -> URL {
        let name = fileName ?? OutputPath.name(for: source, suffix: suffix, pathExtension: pathExtension)
        let scratch = temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let temporary = scratch.appending(path: name)
        try await write(temporary)
        guard FileManager.default.fileExists(atPath: temporary.path) else {
            throw QuickActionError("No result was written for \(source.lastPathComponent)")
        }
        let reserved = try OutputPath.reserve(name, in: outputDirectory)
        try OutputPath.install(temporary, at: reserved)
        return reserved
    }
}

/// A built-in action on files: runs in the background, reports progress and
/// writes its results next to the sources.
public struct FileAction: QuickAction {
    public enum Mode: Sendable {
        /// One result per file.
        case eachFile(@Sendable (FileStep) async throws -> URL)
        /// One result for all files (merge, zip).
        case allFiles(@Sendable (FileStep) async throws -> URL)
    }

    public let id: String
    public let title: String
    public let symbol: String
    public let keywords: [String]
    public let fileKind: FileKind
    /// Also offered for an image on the clipboard; the result goes to the
    /// fallback directory (Downloads).
    public let acceptsClipboardImage: Bool
    public let minimumFiles: Int
    public let mode: Mode

    public init(
        id: String, title: String, symbol: String, keywords: [String] = [],
        fileKind: FileKind, acceptsClipboardImage: Bool = false, minimumFiles: Int = 1, mode: Mode
    ) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.keywords = keywords
        self.fileKind = fileKind
        self.acceptsClipboardImage = acceptsClipboardImage
        self.minimumFiles = minimumFiles
        self.mode = mode
    }

    public func accepts(_ input: ActionInput) -> Bool {
        switch input {
        case .files(let urls):
            return urls.count >= minimumFiles && urls.allSatisfy { fileKind.matches($0) && (fileKind == .any || !$0.hasDirectoryPath) }
        case .image:
            return acceptsClipboardImage
        case .text, .none:
            return false
        }
    }

    public func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        let (sources, outputDirectory) = try FileAction.materialize(input, context: context)
        switch mode {
        case .allFiles(let operation):
            let step = FileStep(
                sources: sources, source: sources[0],
                outputDirectory: outputDirectory ?? sources[0].deletingLastPathComponent(),
                temporaryDirectory: context.temporaryDirectory, progress: context.progress)
            return .files([try await operation(step)])
        case .eachFile(let operation):
            var results: [URL] = []
            for (index, source) in sources.enumerated() {
                try Task.checkCancellation()
                let count = Double(sources.count)
                context.progress(Double(index) / count)
                let step = FileStep(
                    sources: sources, source: source,
                    outputDirectory: outputDirectory ?? source.deletingLastPathComponent(),
                    temporaryDirectory: context.temporaryDirectory,
                    progress: { fraction in context.progress(fraction.map { (Double(index) + $0) / count }) })
                results.append(try await operation(step))
            }
            context.progress(1)
            return .files(results)
        }
    }

    /// The files to work on. A clipboard image is written to scratch space
    /// first, and its results go to the fallback directory.
    static func materialize(_ input: ActionInput, context: ActionContext) throws -> ([URL], URL?) {
        switch input {
        case .files(let urls) where !urls.isEmpty:
            return (urls, nil)
        case .image(let data):
            let isTIFF = data.starts(with: [0x49, 0x49]) || data.starts(with: [0x4D, 0x4D])
            let stamp = Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: false).timeSeparator(.omitted))
            let url = context.temporaryDirectory.appending(path: "Clipboard Image \(stamp).\(isTIFF ? "tiff" : "png")")
            try data.write(to: url)
            return ([url], context.fallbackOutputDirectory)
        default:
            throw QuickActionError("This action needs files")
        }
    }
}

// MARK: - The built-in file actions

public extension FileAction {
    static let all: [FileAction] = [
        convertImage(to: "jpg", format: "jpeg", title: "Convert Image to JPEG", keywords: ["jpg", "jpeg", "heic"]),
        convertImage(to: "png", format: "png", title: "Convert Image to PNG", keywords: ["png"]),
        convertImage(to: "heic", format: "heic", title: "Convert Image to HEIC", keywords: ["heic", "heif"]),
        convertImageToWebP,
        resizeImage(maxPixels: 1600),
        resizeImage(maxPixels: 800),
        compressImage,
        videoToMP4,
        videoToGIF,
        extractAudio,
        compressPDF,
        mergePDFs,
        zip,
    ]

    static func convertImage(to pathExtension: String, format: String, title: String, keywords: [String]) -> FileAction {
        FileAction(
            id: "file.image.\(pathExtension)", title: title, symbol: "photo.on.rectangle.angled",
            keywords: ["convert", "image", "photo"] + keywords,
            fileKind: .image, acceptsClipboardImage: true,
            mode: .eachFile { step in
                try await step.produce(pathExtension: pathExtension) { output in
                    var arguments = ["-s", "format", format]
                    if format == "jpeg" || format == "heic" { arguments += ["-s", "formatOptions", "85"] }
                    try await runTool("sips", arguments + [step.source.path, "--out", output.path])
                }
            })
    }

    /// sips cannot write WebP; ImageMagick can.
    static let convertImageToWebP = FileAction(
        id: "file.image.webp", title: "Convert Image to WebP", symbol: "photo.on.rectangle.angled",
        keywords: ["convert", "image", "photo", "webp"],
        fileKind: .image, acceptsClipboardImage: true,
        mode: .eachFile { step in
            try await step.produce(pathExtension: "webp") { output in
                try await runTool("magick", [step.source.path, "-quality", "85", output.path], brewPackage: "imagemagick")
            }
        })

    static func resizeImage(maxPixels: Int) -> FileAction {
        FileAction(
            id: "file.image.resize.\(maxPixels)", title: "Resize Image to \(maxPixels) px", symbol: "arrow.down.right.and.arrow.up.left",
            keywords: ["resize", "scale", "shrink", "smaller", "image", "photo"],
            fileKind: .image, acceptsClipboardImage: true,
            mode: .eachFile { step in
                try await step.produce(suffix: "-\(maxPixels)", pathExtension: step.source.pathExtension) { output in
                    try await runTool("sips", ["-Z", "\(maxPixels)", step.source.path, "--out", output.path])
                }
            })
    }

    static let compressImage = FileAction(
        id: "file.image.compress", title: "Compress Image (JPEG 70 %)", symbol: "arrow.down.circle",
        keywords: ["compress", "smaller", "jpeg", "jpg", "image", "photo", "quality"],
        fileKind: .image, acceptsClipboardImage: true,
        mode: .eachFile { step in
            try await step.produce(suffix: "-compressed", pathExtension: "jpg") { output in
                try await runTool("sips", ["-s", "format", "jpeg", "-s", "formatOptions", "70", step.source.path, "--out", output.path])
            }
        })

    static let videoToMP4 = FileAction(
        id: "file.video.mp4", title: "Convert Video to MP4", symbol: "film",
        keywords: ["convert", "video", "movie", "mp4", "h264", "mov"],
        fileKind: .video,
        mode: .eachFile { step in
            try await step.produce(pathExtension: "mp4") { output in
                try await ffmpeg(step, [
                    "-c:v", "libx264", "-preset", "medium", "-crf", "23", "-pix_fmt", "yuv420p",
                    "-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart", output.path,
                ])
            }
        })

    /// Two-pass palette for decent colours; 12 fps and at most 640 px wide
    /// keep the file small enough to share.
    static let videoToGIF = FileAction(
        id: "file.video.gif", title: "Convert Video to GIF", symbol: "photo.stack",
        keywords: ["convert", "video", "movie", "gif", "animation"],
        fileKind: .video,
        mode: .eachFile { step in
            try await step.produce(pathExtension: "gif") { output in
                try await ffmpeg(step, [
                    "-vf", "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                    "-loop", "0", output.path,
                ])
            }
        })

    static let extractAudio = FileAction(
        id: "file.video.audio", title: "Extract Audio", symbol: "waveform",
        keywords: ["audio", "sound", "m4a", "aac", "music", "video"],
        fileKind: .video,
        mode: .eachFile { step in
            try await step.produce(pathExtension: "m4a") { output in
                try await ffmpeg(step, ["-vn", "-c:a", "aac", "-b:a", "192k", output.path])
            }
        })

    static let compressPDF = FileAction(
        id: "file.pdf.compress", title: "Compress PDF", symbol: "doc.zipper",
        keywords: ["compress", "smaller", "pdf", "shrink"],
        fileKind: .pdf,
        mode: .eachFile { step in
            try await step.produce(suffix: "-compressed", pathExtension: "pdf") { output in
                try await Task.detached {
                    guard let document = PDFDocument(url: step.source) else {
                        throw QuickActionError("Cannot read \(step.source.lastPathComponent) as a PDF")
                    }
                    guard !document.isLocked else { throw QuickActionError("\(step.source.lastPathComponent) is password protected") }
                    let options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true]
                    guard document.write(to: output, withOptions: options) else {
                        throw QuickActionError("Could not write the compressed PDF")
                    }
                }.value
            }
        })

    static let mergePDFs = FileAction(
        id: "file.pdf.merge", title: "Merge PDFs", symbol: "doc.on.doc",
        keywords: ["merge", "combine", "join", "pdf"],
        fileKind: .pdf, minimumFiles: 2,
        mode: .allFiles { step in
            try await step.produce(suffix: "-merged", pathExtension: "pdf") { output in
                try await Task.detached {
                    let merged = PDFDocument()
                    for (index, url) in step.sources.enumerated() {
                        try Task.checkCancellation()
                        guard let document = PDFDocument(url: url) else {
                            throw QuickActionError("Cannot read \(url.lastPathComponent) as a PDF")
                        }
                        guard !document.isLocked else { throw QuickActionError("\(url.lastPathComponent) is password protected") }
                        for pageIndex in 0..<document.pageCount {
                            guard let page = document.page(at: pageIndex)?.copy() as? PDFPage else { continue }
                            merged.insert(page, at: merged.pageCount)
                        }
                        step.progress(Double(index + 1) / Double(step.sources.count))
                    }
                    guard merged.write(to: output) else { throw QuickActionError("Could not write the merged PDF") }
                }.value
            }
        })

    /// One file or folder → `<name>.zip`, several → `Archive.zip`, like
    /// Finder's Compress.
    static let zip = FileAction(
        id: "file.zip", title: "Compress to ZIP", symbol: "archivebox",
        keywords: ["zip", "archive", "compress"],
        fileKind: .any,
        mode: .allFiles { step in
            let name = step.sources.count == 1 ? step.source.lastPathComponent + ".zip" : "Archive.zip"
            return try await step.produce(named: name, pathExtension: "zip") { output in
                let parents = Set(step.sources.map { $0.deletingLastPathComponent().standardizedFileURL })
                let directory = parents.count == 1 ? parents.first! : URL(filePath: "/")
                // "./" keeps a name like "-m" from being read as an option;
                // zip strips it from the stored entry names.
                let paths = step.sources.map { url in
                    parents.count == 1 ? "./" + url.lastPathComponent : String(url.standardizedFileURL.path.dropFirst())
                }
                try await runTool("zip", ["-r", "-y", "-q", "-X", output.path] + paths + ["-x", "*.DS_Store"], in: directory)
            }
        })
}

// MARK: - Running tools

extension FileAction {
    @discardableResult
    static func runTool(
        _ name: String, _ arguments: [String], brewPackage: String? = nil, in directory: URL? = nil,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        let tool = try ToolLocator.require(name, brewPackage: brewPackage)
        let result = try await ProcessRunner.run(tool, arguments: arguments, currentDirectory: directory, onErrorLine: onErrorLine)
        guard result.status == 0 else {
            let detail = result.errorSummary()
            throw QuickActionError("\(name) failed (exit \(result.status))" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return result
    }

    /// ffmpeg with progress from its status lines.
    static func ffmpeg(_ step: FileStep, _ arguments: [String]) async throws {
        let progress = ProgressBox(report: step.progress)
        try await runTool(
            "ffmpeg", ["-nostdin", "-hide_banner", "-stats_period", "0.25", "-y", "-i", step.source.path] + arguments,
            onErrorLine: { progress.consume($0) })
    }
}

/// Feeds ffmpeg's lines (arriving on a reader thread) into `FFmpegProgress`.
final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var parser = FFmpegProgress()
    private let report: @Sendable (Double?) -> Void

    init(report: @escaping @Sendable (Double?) -> Void) {
        self.report = report
    }

    func consume(_ line: String) {
        lock.lock()
        let changed = parser.consume(line)
        let fraction = parser.fraction
        lock.unlock()
        if changed { report(fraction) }
    }
}
#endif
