#if os(macOS)
import Foundation

/// `$sound airhorn`: plays a sound by a short name (`SoundLibrary`: the
/// sounds of `sounds.toml` and the files of its folder, where `$clip` saves
/// clips). The name is matched like `$code`'s: exactly, ignoring case, or
/// the only name that starts with what is typed. Previewed, so the pane
/// names the file before ⏎ plays it. ⌘E opens `sounds.toml`.
public struct SoundCommand: SettingsFileCommand {
    public let id = "command.sound"
    public let name = "sound"
    public let title = "Play Sound"
    public let summary = "Plays a sound by its name: one saved with $clip, or named in sounds.toml."
    public let symbol = "speaker.wave.2"
    public let keywords = ["sound", "play", "audio", "effect", "clip", "soundboard"]
    /// The folder and sounds, read when the form opens and on every run.
    let library: @Sendable () throws -> SoundLibrary.Contents
    public let settingsFile: URL
    public var settingsStarter: String { SoundLibrary.starter }
    let fileExists: @Sendable (String) -> Bool

    public init(
        library: @escaping @Sendable () throws -> SoundLibrary.Contents = { try SoundLibrary.load() },
        settingsFile: URL = SoundLibrary.defaultFile(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.library = library
        self.settingsFile = settingsFile
        self.fileExists = fileExists
    }

    /// The form lists the sounds.
    public var argument: CommandArgument? {
        let library = library
        return CommandArgument(
            title: "Sound", placeholder: "airhorn",
            kind: .choice(CommandChoices(id: "sounds") { Self.choices((try? library().sounds) ?? []) }),
            suggestions: .choices)
    }

    /// Finding the sound only reads; it plays on ⏎.
    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        guard let text = invocation.input.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            throw QuickActionError("Needs a sound")
        }
        return .open(.play(try sound(named: text).file))
    }

    /// The sound `text` names, or why there is none.
    func sound(named text: String) throws -> Sound {
        let contents = try library()
        let choice = try CommandChoices.pick(
            text, in: Self.choices(contents.sounds), noun: "sound",
            none: "No sounds: save one with $clip, or put sound files in \(contents.folder.path(percentEncoded: false))")
        let sound = contents.sounds.first { $0.name == choice.value }!
        guard fileExists(sound.file.path(percentEncoded: false)) else {
            throw QuickActionError("“\(sound.name)” is \(sound.file.path(percentEncoded: false)), which is not there")
        }
        return sound
    }

    /// One choice per sound, by name.
    static func choices(_ sounds: [Sound]) -> [ActionOption.Choice] {
        sounds.map { ActionOption.Choice($0.name, title: $0.name) }
    }
}
#endif
