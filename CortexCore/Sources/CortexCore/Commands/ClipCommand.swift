#if os(macOS)
import Foundation

/// `$clip https://youtu.be/… 1:23 4 airhorn`: cuts a few seconds out of a
/// YouTube video (or anything else yt-dlp downloads) and saves them as an
/// MP4 in the sounds folder (`SoundLibrary`), where `$sound` plays them by
/// name. yt-dlp downloads only that part, cut at the exact frame; ffmpeg
/// then makes it H.264 and AAC, which every Mac plays. Without a name the
/// clip is called after the video. A link with a start (`?t=83`) needs
/// only the duration.
public struct ClipCommand: Command {
    public let id = "command.clip"
    public let name = "clip"
    public let title = "Clip Video"
    public let summary = "Saves a part of a YouTube video as an MP4 for $sound: the link, where it starts, how long it is, and a name if you like."
    public let symbol = "film"
    public let keywords = ["clip", "youtube", "video", "sound", "cut", "download", "yt-dlp", "mp4"]
    public let argument: CommandArgument? = CommandArgument(
        title: "Link, start, duration and name", placeholder: "https://youtu.be/… 1:23 4 airhorn",
        suggestions: .clips(matching: #"^(https?://)?(www\.|m\.|music\.)?(youtube\.com|youtu\.be)/\S+$"#))

    /// The longest clip, in seconds.
    static let maxDuration: Double = 600

    /// Where clips go: read on every run, so a changed `folder` counts.
    let folder: @Sendable () throws -> URL

    public init(folder: @escaping @Sendable () throws -> URL = { try SoundLibrary.load().folder }) {
        self.folder = folder
    }

    /// What is typed: the link, then the start and the duration, then
    /// the name.
    struct Request: Equatable {
        var url: URL
        var start: Double
        var duration: Double
        /// The file's name without `.mp4`; nil for the video's title.
        var name: String?
    }

    /// Reads the link and the times, and says what the job will cut and where
    /// it goes; or what is wrong with them. Nothing is downloaded until the
    /// job runs.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let request = try Self.request(invocation.input.text ?? "")
        let folder = (try? folder()).map { Self.display($0) } ?? "the sounds folder"
        let file = folder + "/" + (request.name ?? "<the video's title>") + ".mp4"
        let plan = """
            Cuts \(Self.format(request.duration)) from \(Self.format(request.start)) of \(request.url.absoluteString)
            and saves it as \(file)
            """
        return .job(plan: plan) { [self] context in try await clip(request, context: context) }
    }

    /// Downloads the part, encodes it and saves it in the sounds folder.
    func clip(_ request: Request, context: ActionContext) async throws -> ActionOutput {
        let folder = try folder()
        let ffmpeg = try ToolLocator.require("ffmpeg")
        _ = try ToolLocator.require("yt-dlp")

        context.progress(nil)
        let download = context.temporaryDirectory.appending(path: "download-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: download, withIntermediateDirectories: true)
        do {
            try await FileAction.runTool("yt-dlp", Self.downloadArguments(request, into: download, ffmpeg: ffmpeg))
        } catch let error as QuickActionError {
            throw QuickActionError(error.message + "\nAn old yt-dlp often fails on YouTube: brew upgrade yt-dlp")
        }
        let downloaded = try FileManager.default.contentsOfDirectory(at: download, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasPrefix(".") && $0.pathExtension != "part" }
        guard let source = downloaded.first else { throw QuickActionError("yt-dlp saved nothing") }

        let name = Self.fileName(request.name ?? source.deletingPathExtension().lastPathComponent)
        let clip = context.temporaryDirectory.appending(path: name)
        let progress = ProgressBox(report: context.progress)
        try await FileAction.runTool(
            "ffmpeg", Self.encodeArguments(source, duration: request.duration, to: clip), onErrorLine: { progress.consume($0) })

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let saved = try OutputPath.reserve(name, in: folder)
        try OutputPath.install(clip, at: saved)
        return .files([saved])
    }

    /// Only the part from `start`, cut at the exact frame (yt-dlp re-encodes
    /// around the cuts), at most 720p and preferably H.264 and AAC, named
    /// after the video.
    static func downloadArguments(_ request: Request, into folder: URL, ffmpeg: URL) -> [String] {
        [
            "--no-playlist", "--no-progress", "--ffmpeg-location", ffmpeg.path(percentEncoded: false),
            "-S", "res:720,vcodec:h264,acodec:aac",
            "--download-sections", "*\(seconds(request.start))-\(seconds(request.start + request.duration))",
            "--force-keyframes-at-cuts",
            "-o", folder.appending(path: "%(title).80B.%(ext)s").path(percentEncoded: false),
            "--", request.url.absoluteString,
        ]
    }

    /// H.264 and AAC in an MP4 that starts playing before it is read to the
    /// end, no longer than asked.
    static func encodeArguments(_ source: URL, duration: Double, to clip: URL) -> [String] {
        [
            "-nostdin", "-hide_banner", "-stats_period", "0.25", "-y", "-i", source.path(percentEncoded: false),
            "-t", seconds(duration),
            "-c:v", "libx264", "-preset", "veryfast", "-crf", "23", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", clip.path(percentEncoded: false),
        ]
    }

    // MARK: - What is typed

    /// `<link> [start] <duration> [name…]`: the start may come from the
    /// link instead (`?t=83`), and a start that is typed wins.
    static func request(_ text: String) throws -> Request {
        var words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { throw QuickActionError("Type the link, the start and the duration: $clip https://youtu.be/… 1:23 4") }
        let url = try link(words.removeFirst())
        var times: [Double] = []
        while times.count < 2, let first = words.first, let time = time(first) {
            times.append(time)
            words.removeFirst()
        }
        let start: Double
        let duration: Double
        switch (times.count, startOf(url)) {
        case (2, _):
            (start, duration) = (times[0], times[1])
        case (1, let linked?):
            (start, duration) = (linked, times[0])
        default:
            throw QuickActionError("Type where the clip starts and how long it is after the link: 1:23 4")
        }
        guard duration > 0, duration <= maxDuration else {
            throw QuickActionError("The duration is more than 0 and at most \(Int(maxDuration)) seconds")
        }
        let name = words.joined(separator: " ")
        return Request(url: url, start: start, duration: duration, name: name.isEmpty ? nil : name)
    }

    /// An http(s) link; `youtu.be/…` without `https://` too.
    static func link(_ word: String) throws -> URL {
        let lowercased = word.lowercased()
        let text = lowercased.hasPrefix("http://") || lowercased.hasPrefix("https://") ? word : "https://" + word
        guard let url = URL(string: text), let host = url.host(), host.contains("."), !url.path().isEmpty || url.query() != nil else {
            throw QuickActionError("“\(word)” is not a link to a video")
        }
        return url
    }

    /// The start a shared link carries: `t=83`, `t=1m23s`, in the query or
    /// after `#`.
    static func startOf(_ url: URL) -> Double? {
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let fragment = URLComponents(string: "?" + (url.fragment() ?? ""))?.queryItems ?? []
        let value = (query + fragment).first { $0.name == "t" || $0.name == "start" }?.value
        return value.flatMap(time)
    }

    /// Seconds from `83`, `83.5`, `83s`, `1:23`, `1:02:03.5` or `1h2m3s`.
    static func time(_ text: String) -> Double? {
        if text.contains(":") {
            let parts = text.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 3, parts.allSatisfy({ !$0.isEmpty }) else { return nil }
            var total = 0.0
            for (index, part) in parts.enumerated() {
                guard let value = Double(part), value >= 0, value.isFinite else { return nil }
                // Minutes and seconds after the first part are below 60.
                if index > 0, value >= 60 { return nil }
                total = total * 60 + value
            }
            return total
        }
        var total = 0.0
        var number = ""
        for character in text.lowercased() {
            if character.isNumber || character == "." {
                number.append(character)
                continue
            }
            let unit: Double
            switch character {
            case "h": unit = 3600
            case "m": unit = 60
            case "s": unit = 1
            default: return nil
            }
            guard let value = Double(number) else { return nil }
            total += value * unit
            number = ""
        }
        if !number.isEmpty {
            guard let value = Double(number) else { return nil }
            total += value
        }
        return text.isEmpty || !total.isFinite ? nil : total
    }

    /// `83.5` as `1:23.5`, for the plan.
    static func format(_ seconds: Double) -> String {
        let whole = Int(seconds)
        let fraction = seconds - Double(whole)
        let rest = fraction > 0.0005 ? String(format: "%.3f", fraction).dropFirst().trimmingSuffix("0") : ""
        let clock = whole >= 3600
            ? String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
            : String(format: "%d:%02d", whole / 60, whole % 60)
        return clock + rest
    }

    /// `~/.config/cortex/sounds`.
    static func display(_ folder: URL, home: URL = URL.homeDirectory) -> String {
        let path = folder.path(percentEncoded: false).trimmingSuffix("/")
        let homePath = home.path(percentEncoded: false).trimmingSuffix("/")
        return path.hasPrefix(homePath + "/") ? "~" + path.dropFirst(homePath.count) : path
    }

    /// For yt-dlp and ffmpeg: `83.5`, `4`.
    static func seconds(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.3f", value)
    }

    /// `<name>.mp4`, with what a file name cannot have replaced.
    static func fileName(_ name: String) -> String {
        var name = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while name.hasPrefix(".") { name.removeFirst() }
        return (name.isEmpty ? "clip" : name) + ".mp4"
    }
}

private extension StringProtocol {
    func trimmingSuffix(_ character: Character) -> String {
        var text = String(self)
        while text.last == character { text.removeLast() }
        return text
    }
}
#endif
