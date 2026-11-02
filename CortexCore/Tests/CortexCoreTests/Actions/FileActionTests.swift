import CoreGraphics
import Foundation
import PDFKit
import Testing
@testable import CortexCore

@Suite struct OutputPathTests {
    @Test func names() {
        let source = URL(filePath: "/x/IMG_0001.HEIC")
        #expect(OutputPath.name(for: source, pathExtension: "jpg") == "IMG_0001.jpg")
        #expect(OutputPath.name(for: source, suffix: "-small", pathExtension: "HEIC") == "IMG_0001-small.HEIC")
        #expect(OutputPath.name(for: source, pathExtension: "heic") == "IMG_0001-converted.heic", "never the source's own name")
    }

    @Test func neverReplacesAFile() throws {
        let directory = try temporaryDirectory()
        let first = try OutputPath.reserve("a.jpg", in: directory)
        let second = try OutputPath.reserve("a.jpg", in: directory)
        let third = try OutputPath.reserve("a.jpg", in: directory)
        #expect([first, second, third].map(\.lastPathComponent) == ["a.jpg", "a 2.jpg", "a 3.jpg"])
        #expect(OutputPath.unique("archive", in: directory).lastPathComponent == "archive")
    }
}

@Suite struct FFmpegProgressTests {
    @Test func followsTimeAgainstDuration() {
        var progress = FFmpegProgress()
        var changed = progress.consume("frame=   10 fps=0.0 time=00:00:01.00")
        #expect(!changed, "no duration yet")
        progress.consume("  Duration: 00:01:40.00, start: 0.000000, bitrate: 1234 kb/s")
        #expect(progress.duration == 100)
        changed = progress.consume("frame=  250 fps=50 q=28.0 size=1024kB time=00:00:25.00 bitrate=335.5kbits/s speed=2x")
        #expect(changed)
        #expect(progress.fraction == 0.25)
        changed = progress.consume("frame=  250 fps=50 time=00:00:25.00")
        #expect(!changed, "unchanged")
        progress.consume("time=00:02:00.00")
        #expect(progress.fraction == 1)
        changed = progress.consume("time=N/A")
        #expect(!changed)
    }
}

/// These run the real tools (sips, zip, zsh); they are part of macOS.
@Suite struct FileActionTests {
    let directory: URL
    let context: ActionContext

    init() throws {
        directory = try temporaryDirectory()
        context = try ActionContext.make(fallbackOutputDirectory: directory.appending(path: "Downloads"))
        try FileManager.default.createDirectory(at: context.fallbackOutputDirectory, withIntermediateDirectories: true)
    }

    func write(_ data: Data, _ name: String) throws -> URL {
        let url = directory.appending(path: name)
        try data.write(to: url)
        return url
    }

    func action(_ id: String) -> FileAction {
        FileAction.all.first { $0.id == id }!
    }

    @Test func convertsImagesNextToTheSource() async throws {
        let png = try write(makePNG(), "photo.png")
        let output = try await action("file.image.jpg").run(.files([png]), context: context)
        #expect(output == .files([directory.appending(path: "photo.jpg")]))
        let data = try Data(contentsOf: directory.appending(path: "photo.jpg"))
        #expect(data.starts(with: [0xFF, 0xD8, 0xFF]), "a JPEG")

        // Again: the first result is kept.
        let again = try await action("file.image.jpg").run(.files([png]), context: context)
        #expect(again == .files([directory.appending(path: "photo 2.jpg")]))
    }

    @Test func resizesAClipboardImageIntoTheFallbackFolder() async throws {
        let output = try await action("file.image.resize.800").run(.image(makePNG(width: 1600, height: 1000)), context: context)
        guard case .files(let urls) = output, let url = urls.first else {
            Issue.record("expected a file")
            return
        }
        #expect(url.deletingLastPathComponent().standardizedFileURL == context.fallbackOutputDirectory.standardizedFileURL)
        #expect(url.lastPathComponent.hasPrefix("Clipboard Image "))
        #expect(url.lastPathComponent.hasSuffix("-800.png"))
        let image = try #require(CGImageSourceCreateWithURL(url as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        #expect(image.width == 800 && image.height == 500)
    }

    @Test func reportsProgressPerFile() async throws {
        let files = try (1...3).map { try write(makePNG(), "p\($0).png") }
        let seen = Locked<[Double]>([])
        var context = context
        context.progress = { fraction in if let fraction { seen.withLock { $0.append(fraction) } } }
        _ = try await action("file.image.resize.800").run(.files(files), context: context)
        let fractions = seen.withLock { $0 }
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
    }

    @Test func mergesPDFs() async throws {
        let a = try write(makePDF(pages: 2), "a.pdf")
        let b = try write(makePDF(pages: 3), "b.pdf")
        let output = try await action("file.pdf.merge").run(.files([a, b]), context: context)
        #expect(output == .files([directory.appending(path: "a-merged.pdf")]))
        #expect(PDFDocument(url: directory.appending(path: "a-merged.pdf"))?.pageCount == 5)
    }

    @Test func compressesPDFs() async throws {
        let a = try write(makePDF(pages: 1), "scan.pdf")
        let output = try await action("file.pdf.compress").run(.files([a]), context: context)
        #expect(output == .files([directory.appending(path: "scan-compressed.pdf")]))
        #expect(PDFDocument(url: directory.appending(path: "scan-compressed.pdf"))?.pageCount == 1)
    }

    @Test func zipsLikeFinder() async throws {
        let a = try write(Data("a".utf8), "a.txt")
        let b = try write(Data("b".utf8), "b.txt")
        #expect(try await action("file.zip").run(.files([a]), context: context) == .files([directory.appending(path: "a.txt.zip")]))
        #expect(try await action("file.zip").run(.files([a, b]), context: context) == .files([directory.appending(path: "Archive.zip")]))
        let listing = try await ProcessRunner.run(URL(filePath: "/usr/bin/unzip"), arguments: ["-Z1", directory.appending(path: "Archive.zip").path])
        #expect(listing.outputText.split(separator: "\n").sorted() == ["a.txt", "b.txt"])
    }

    /// A file named like a zip option must be archived, not obeyed: `-m`
    /// would move (delete) the other selected files into the archive.
    @Test func zipTreatsDashNamesAsFiles() async throws {
        let a = try write(Data("a".utf8), "a.txt")
        let m = try write(Data("m".utf8), "-m")
        let t = try write(Data("t".utf8), "-T")
        #expect(try await action("file.zip").run(.files([a, m, t]), context: context) == .files([directory.appending(path: "Archive.zip")]))
        #expect(FileManager.default.fileExists(atPath: a.path))
        #expect(FileManager.default.fileExists(atPath: m.path))
        let listing = try await ProcessRunner.run(URL(filePath: "/usr/bin/unzip"), arguments: ["-Z1", directory.appending(path: "Archive.zip").path])
        #expect(listing.outputText.split(separator: "\n").sorted() == ["-T", "-m", "a.txt"])
    }

    @Test(.enabled(if: ToolLocator.find("ffmpeg") != nil, "needs ffmpeg (brew install ffmpeg)"))
    func videoToGIFAndAudioWithProgress() async throws {
        let video = directory.appending(path: "clip.mov")
        try await FileAction.runTool("ffmpeg", [
            "-nostdin", "-f", "lavfi", "-i", "testsrc=duration=20:size=640x480:rate=25",
            "-f", "lavfi", "-i", "sine=duration=20", "-shortest", "-c:v", "mpeg4", "-c:a", "aac", video.path,
        ])
        let seen = Locked<[Double]>([])
        var context = context
        context.progress = { fraction in if let fraction { seen.withLock { $0.append(fraction) } } }

        #expect(try await action("file.video.gif").run(.files([video]), context: context) == .files([directory.appending(path: "clip.gif")]))
        #expect(try Data(contentsOf: directory.appending(path: "clip.gif")).starts(with: Array("GIF89a".utf8)))
        #expect(seen.withLock { $0 }.contains { $0 > 0 && $0 < 1 }, "ffmpeg's time= lines report progress")

        #expect(try await action("file.video.audio").run(.files([video]), context: context) == .files([directory.appending(path: "clip.m4a")]))
        #expect(try await action("file.video.mp4").run(.files([video]), context: context) == .files([directory.appending(path: "clip.mp4")]))
    }

    @Test func missingToolsSayHowToInstall() {
        #expect(throws: QuickActionError("no-such-tool-xyz is not installed. Install it with: brew install xyz")) {
            try ToolLocator.require("no-such-tool-xyz", brewPackage: "xyz")
        }
    }

    // MARK: User actions

    func userAction(_ toml: String) throws -> UserAction {
        UserAction(definition: try UserActionDefinition.parse(toml), file: directory.appending(path: "test.toml"))
    }

    @Test func userTextActionUsesStdinAndStdout() async throws {
        let action = try userAction("name = 'Upper'\naccepts = ['text']\ncommand = 'tr a-z A-Z'")
        #expect(try await action.run(.text("hello it's me\n"), context: context) == .text("HELLO IT'S ME"))
        let viaFile = try userAction("name = 'Rev'\naccepts = ['text']\ncommand = 'rev < {input}'")
        #expect(try await viaFile.run(.text("abc"), context: context) == .text("cba"))
    }

    @Test func userFileActionWritesNextToEachSource() async throws {
        let a = try write(Data("one".utf8), "my file.txt")
        let b = try write(Data("two".utf8), "other's.txt")
        let action = try userAction("""
            name = 'Shout'
            accepts = ['files']
            extensions = ['txt']
            command = 'tr a-z A-Z < "{input}" > {output}'
            output_suffix = '-loud'
            """)
        let output = try await action.run(.files([a, b]), context: context)
        #expect(output == .files([directory.appending(path: "my file-loud.txt"), directory.appending(path: "other's-loud.txt")]))
        #expect(try String(contentsOf: directory.appending(path: "other's-loud.txt"), encoding: .utf8) == "TWO")
    }

    @Test func userActionWithAllInputsRunsOnce() async throws {
        let a = try write(Data("1".utf8), "a.txt")
        let b = try write(Data("2".utf8), "b.txt")
        let action = try userAction("name = 'Cat'\naccepts = ['files']\ncommand = 'cat {inputs}'\noutput = 'text'")
        #expect(try await action.run(.files([a, b]), context: context) == .text("12"))
    }

    /// File names and text are never shell source: none of these run
    /// `touch`, whatever the template does with them.
    @Test func aProcessWritingTooMuchIsStopped() async throws {
        await #expect(throws: QuickActionError.self) {
            try await ProcessRunner.run(URL(filePath: "/usr/bin/yes"), arguments: [], maxOutputBytes: 1_000_000)
        }
        let small = try await ProcessRunner.run(URL(filePath: "/bin/echo"), arguments: ["hi"], maxOutputBytes: 10)
        #expect(small.outputText == "hi\n")
    }

    @Test func hostileNamesAndTextStayOneWord() async throws {
        let marker = directory.appending(path: "PWNED")
        let names = [
            "clip{input}$(touch \(marker.lastPathComponent)).txt", "it's `touch PWNED`.txt", "-m.txt", "line\nbreak.txt",
            "\"{output}\" '{input}'.txt",
        ]
        let files = try names.enumerated().map { try write(Data("\($0.offset)".utf8), $0.element) }

        let copy = try userAction("name = 'Copy'\naccepts = ['files']\ncommand = 'cp {input} \"{output}\"'\noutput_suffix = '-copy'")
        guard case .files(let copies) = try await copy.run(.files(files), context: context) else {
            Issue.record("expected files")
            return
        }
        #expect(try copies.map { try String(contentsOf: $0, encoding: .utf8) } == ["0", "1", "2", "3", "4"])

        let all = try userAction("name = 'Cat'\naccepts = ['files']\ncommand = 'cat {inputs}'\noutput = 'text'")
        #expect(try await all.run(.files(files), context: context) == .text("01234"))

        let text = "{input}$(touch \(marker.path))'\"`touch \(marker.path)`"
        let quoted = try userAction("""
            name = 'Result'
            accepts = ['text']
            command = "printf '%s|' \\"Result: {argument}\\" {argument} \\"$1\\" \\"$CORTEX_ARGUMENT\\""
            output = 'text'
            """)
        #expect(try await quoted.run(.text(text), context: context) == .text("Result: \(text)|\(text)|\(text)|\(text)|"))

        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: context.temporaryDirectory.appending(path: "PWNED").path))
    }

    @Test func userActionFailureShowsStandardError() async throws {
        let action = try userAction("name = 'Fail'\naccepts = ['none']\ncommand = 'echo boom >&2; exit 3'")
        await #expect(throws: QuickActionError("Fail failed (exit 3): boom")) {
            try await action.run(.none, context: context)
        }
        let done = try userAction("name = 'Nothing'\naccepts = ['none']\ncommand = 'true'")
        #expect(try await done.run(.none, context: context) == .done("Nothing: done"))
    }

    @Test func homebrewIsOnThePath() async throws {
        let action = try userAction("name = 'Path'\naccepts = ['none']\ncommand = 'echo $PATH'\noutput = 'text'")
        guard case .text(let path) = try await action.run(.none, context: context) else { return }
        #expect(path.hasPrefix("/opt/homebrew/bin:/usr/local/bin:"))
    }

    /// The process may exit without reading its input; writing to the closed
    /// pipe must not kill the host with SIGPIPE.
    @Test func inputToAProcessThatNeverReadsIsNotFatal() async throws {
        let input = Data(repeating: 0x61, count: 1_000_000)
        for _ in 0..<200 {
            let result = try await ProcessRunner.run(URL(filePath: "/usr/bin/true"), arguments: [], input: input)
            #expect(result.status == 0)
        }
    }

    @Test func cancellingStopsTheProcess() async throws {
        let task = Task {
            try await ProcessRunner.run(URL(filePath: "/bin/sleep"), arguments: ["30"])
        }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date.now
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date.now.timeIntervalSince(start) < 5)
    }
}

func makePDF(pages: Int) -> Data {
    let data = NSMutableData()
    var box = CGRect(x: 0, y: 0, width: 200, height: 300)
    let consumer = CGDataConsumer(data: data)!
    let context = CGContext(consumer: consumer, mediaBox: &box, nil)!
    for _ in 0..<pages {
        context.beginPDFPage(nil)
        context.setFillColor(red: 0, green: 0, blue: 0, alpha: 1)
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
    }
    context.closePDF()
    return data as Data
}

final class Locked<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
