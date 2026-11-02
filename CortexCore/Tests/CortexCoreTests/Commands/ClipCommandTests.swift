import Foundation
import Testing
@testable import CortexCore

/// `$clip`: what is typed, and how yt-dlp and ffmpeg are asked.
@Suite struct ClipCommandTests {
    let command = ClipCommand { URL(filePath: "/Users/me/.config/cortex/sounds", directoryHint: .isDirectory) }

    @Test func times() {
        #expect(ClipCommand.time("83") == 83)
        #expect(ClipCommand.time("83.5") == 83.5)
        #expect(ClipCommand.time("83s") == 83)
        #expect(ClipCommand.time("1:23") == 83)
        #expect(ClipCommand.time("1:02:03.5") == 3723.5)
        #expect(ClipCommand.time("90:00") == 5400, "the first part may be 60 or more")
        #expect(ClipCommand.time("1h2m3s") == 3723)
        #expect(ClipCommand.time("1m23") == 83)
        for text in ["", "airhorn", "s", "1:", ":5", "1:75", "1:2:3:4", "1x", "1..2"] {
            #expect(ClipCommand.time(text) == nil, "\(text)")
        }
    }

    @Test func whatIsTyped() throws {
        #expect(try ClipCommand.request("https://youtu.be/abc 1:23 4 air horn") == ClipCommand.Request(
            url: URL(string: "https://youtu.be/abc")!, start: 83, duration: 4, name: "air horn"))
        #expect(try ClipCommand.request("youtu.be/abc?t=83 4") == ClipCommand.Request(
            url: URL(string: "https://youtu.be/abc?t=83")!, start: 83, duration: 4, name: nil), "the link's start")
        #expect(try ClipCommand.request("https://www.youtube.com/watch?v=abc&t=1m23s 1:30 2.5").start == 90, "a typed start wins")
        #expect(try ClipCommand.request("https://www.youtube.com/watch?v=abc#t=10 2").start == 10)
    }

    @Test func whatIsWrong() {
        func problem(_ text: String) -> String? {
            do {
                _ = try ClipCommand.request(text)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(problem("") == "Type the link, the start and the duration: $clip https://youtu.be/… 1:23 4")
        #expect(problem("airhorn 1 2") == "“airhorn” is not a link to a video")
        #expect(problem("https://youtu.be/abc 4") == "Type where the clip starts and how long it is after the link: 1:23 4")
        #expect(problem("https://youtu.be/abc 1:23 horn") == "Type where the clip starts and how long it is after the link: 1:23 4")
        #expect(problem("https://youtu.be/abc 1:23 0") == "The duration is more than 0 and at most 600 seconds")
        #expect(problem("https://youtu.be/abc 1:23 601") == "The duration is more than 0 and at most 600 seconds")
    }

    /// The plan of the job the command resolves to.
    private func plan(_ text: String) async throws -> String {
        guard case .job(let plan, _) = try await command.resolve(.text(text)) else { throw QuickActionError("not a job") }
        return plan
    }

    @Test func thePlanSaysWhatAndWhere() async throws {
        #expect(try await plan("https://youtu.be/abc 1:23.5 4 horn") == """
            Cuts 0:04 from 1:23.5 of https://youtu.be/abc
            and saves it as /Users/me/.config/cortex/sounds/horn.mp4
            """)
        #expect(try await plan("https://youtu.be/abc 3723 4").contains("from 1:02:03 of"))
        #expect(try await plan("https://youtu.be/abc 1:23 4").hasSuffix("sounds/<the video's title>.mp4"))
    }

    @Test func whatIsWrongWithTheTextIsTheResolvingError() async {
        await #expect(throws: QuickActionError("Type where the clip starts and how long it is after the link: 1:23 4")) {
            try await command.resolve(.text("https://youtu.be/abc"))
        }
    }

    @Test func resolvingDownloadsNothing() async throws {
        // No yt-dlp is looked for, no folder is made: only the job does that.
        let folder = FileManager.default.temporaryDirectory.appending(path: "cortex-clip-\(UUID().uuidString)")
        let clip = ClipCommand(folder: { folder })
        _ = try await clip.resolve(.text("https://youtu.be/abc 1:23 4"))
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test func toolArguments() throws {
        let request = try ClipCommand.request("https://youtu.be/abc 1:23.25 4")
        let download = ClipCommand.downloadArguments(request, into: URL(filePath: "/tmp/d"), ffmpeg: URL(filePath: "/opt/homebrew/bin/ffmpeg"))
        #expect(download.contains("--force-keyframes-at-cuts"))
        #expect(download.firstIndex(of: "--download-sections").map { download[$0 + 1] } == "*83.250-87.250")
        #expect(download.firstIndex(of: "-o").map { download[$0 + 1] } == "/tmp/d/%(title).80B.%(ext)s")
        #expect(download.suffix(2) == ["--", "https://youtu.be/abc"], "the link is never read as an option")
        let encode = ClipCommand.encodeArguments(URL(filePath: "/tmp/d/x.mkv"), duration: 4, to: URL(filePath: "/tmp/x.mp4"))
        #expect(encode.firstIndex(of: "-t").map { encode[$0 + 1] } == "4")
        #expect(encode.last == "/tmp/x.mp4")
    }

    @Test func fileNames() {
        #expect(ClipCommand.fileName("air horn") == "air horn.mp4")
        #expect(ClipCommand.fileName("AC/DC: Live") == "AC-DC- Live.mp4")
        #expect(ClipCommand.fileName("..hidden") == "hidden.mp4")
        #expect(ClipCommand.fileName("  ") == "clip.mp4")
        #expect(ClipCommand.display(URL(filePath: "/Users/me/x/sounds/"), home: URL(filePath: "/Users/me")) == "~/x/sounds")
        #expect(ClipCommand.display(URL(filePath: "/Users/meg/x"), home: URL(filePath: "/Users/me")) == "/Users/meg/x")
    }

    @Test func itTakesTextAndSuggestsCopiedLinks() async throws {
        let argument = try #require(command.argument)
        #expect(argument.isRequired)
        #expect(try await command.resolve(.text("https://youtu.be/abc 1:23 4")).kind == .job, "it downloads")
        guard case .clips(let pattern) = argument.suggestions else {
            Issue.record("expected clip suggestions")
            return
        }
        let regex = try Regex(pattern)
        #expect(try regex.wholeMatch(in: "https://www.youtube.com/watch?v=abc") != nil)
        #expect(try regex.wholeMatch(in: "youtu.be/abc?t=4") != nil)
        #expect(try regex.wholeMatch(in: "https://example.com/abc") == nil)
    }
}
