import Foundation
import Testing
@testable import CortexCore

/// `$sound`: `sounds.toml`, the sounds folder and picking a sound.
@Suite struct SoundCommandTests {
    let home = URL(filePath: "/Users/me")
    let standard = URL(filePath: "/Users/me/.config/cortex/sounds", directoryHint: .isDirectory)

    // MARK: - sounds.toml

    @Test func soundsOfTheFile() throws {
        let (folder, sounds) = try SoundLibrary.parse("""
            folder = "~/Music/Sounds"

            [horn]
            path = "airhorn.mp4"

            [bell]
            path = "/System/Library/Sounds/Glass.aiff"
            """, home: home, folder: standard)
        #expect(folder == URL(filePath: "/Users/me/Music/Sounds", directoryHint: .isDirectory))
        #expect(sounds == [
            Sound(name: "horn", file: URL(filePath: "/Users/me/Music/Sounds/airhorn.mp4")),
            Sound(name: "bell", file: URL(filePath: "/System/Library/Sounds/Glass.aiff")),
        ])
        #expect(try SoundLibrary.parse("", home: home, folder: standard).folder == standard)
        #expect(try SoundLibrary.parse(SoundLibrary.starter, home: home, folder: standard) == (standard, []), "all comments")
    }

    @Test func fileProblems() {
        func problem(_ text: String) -> String? {
            do {
                _ = try SoundLibrary.parse(text, home: home, folder: standard)
                return nil
            } catch {
                return "\(error)"
            }
        }
        #expect(problem("[a]") == "[a] (line 1): path is missing")
        #expect(problem("[a]\npath = 3") == "[a] (line 1): path is text in quotes")
        #expect(problem("[a]\npath = \"x\"\nvolume = \"1\"") == "[a] (line 1): unknown key “volume”: a sound has a path")
        #expect(problem("folder = \"Music\"") == "folder is a path in quotes, starting with / or ~/")
        #expect(problem("scan = []") == "unknown key “scan”: only folder comes before the sounds")
    }

    @Test func theFolderAndTheFile() throws {
        let config = FileManager.default.temporaryDirectory.appending(path: "cortex-sound-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: config) }
        let folder = SoundLibrary.defaultFolder(for: config.appending(path: "sounds.toml"))
        #expect(folder == config.appending(path: "sounds", directoryHint: .isDirectory), "next to the file")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["airhorn.mp4", "Bell.m4a", "notes.txt", ".hidden.mp4", "zap.WAV"] {
            try Data().write(to: folder.appending(path: name))
        }
        let file = config.appending(path: "sounds.toml")
        #expect(try SoundLibrary.load(file: file, home: home).sounds.map(\.name) == ["airhorn", "Bell", "zap"], "no file: the folder's")
        try "[bell]\npath = \"airhorn.mp4\"\n".write(to: file, atomically: true, encoding: .utf8)
        let contents = try SoundLibrary.load(file: file, home: home)
        #expect(contents.folder == folder)
        #expect(contents.sounds.map(\.name) == ["bell", "airhorn", "zap"], "the file's name wins over Bell.m4a")
        #expect(contents.sounds[0].file.lastPathComponent == "airhorn.mp4")
        try "[bell]\n".write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: QuickActionError("sounds.toml: [bell] (line 1): path is missing")) { try SoundLibrary.load(file: file, home: home) }
    }

    // MARK: - The command

    let library = SoundLibrary.Contents(
        folder: URL(filePath: "/s", directoryHint: .isDirectory),
        sounds: [
            Sound(name: "airhorn", file: URL(filePath: "/s/airhorn.mp4")),
            Sound(name: "applause", file: URL(filePath: "/s/applause.m4a")),
            Sound(name: "gone", file: URL(filePath: "/s/gone.mp4")),
        ])

    var command: SoundCommand {
        let library = library
        return SoundCommand(library: { library }, fileExists: { $0 != "/s/gone.mp4" })
    }

    func context() -> ActionContext {
        ActionContext(fallbackOutputDirectory: home, temporaryDirectory: home)
    }

    @Test func playsTheSoundItNames() async throws {
        #expect(try await command.resolve(.text("Airhorn")) == .open(.play(URL(filePath: "/s/airhorn.mp4"))), "the pane names it; it plays on ⏎")
        #expect(try await command.resolve(.text("appl")) == .open(.play(URL(filePath: "/s/applause.m4a"))), "the only one starting with it")
        #expect(try await command.output(.text("Airhorn"), context: context()) == .play(URL(filePath: "/s/airhorn.mp4")))
    }

    @Test func saysWhyThereIsNone() {
        #expect(throws: QuickActionError("“a” could be airhorn, applause: type more of the name")) { try command.sound(named: "a") }
        #expect(throws: QuickActionError("No sound is called “nope”. Sounds: airhorn, applause, gone")) { try command.sound(named: "nope") }
        #expect(throws: QuickActionError("“gone” is /s/gone.mp4, which is not there")) { try command.sound(named: "gone") }
        let empty = SoundCommand(library: { SoundLibrary.Contents(folder: URL(filePath: "/s"), sounds: []) })
        #expect(throws: QuickActionError("No sounds: save one with $clip, or put sound files in /s")) { try empty.sound(named: "a") }
    }

    @Test func itsArgumentIsAChoiceOfTheSounds() async throws {
        let argument = try #require(command.argument)
        #expect(argument.isRequired, "⌘E opens sounds.toml, not the command alone")
        #expect(!command.accepts(.none))
        guard case .choice(let choices) = argument.kind else {
            Issue.record("expected a choice")
            return
        }
        #expect(await choices.load().map(\.title) == ["airhorn", "applause", "gone"])
    }

    @Test func itsSettingsFileIsSoundsToml() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "cortex-sound-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cortex/sounds.toml")
        let sound = SoundCommand(library: { throw QuickActionError("not read") }, settingsFile: file)
        #expect(try sound.settingsLink() == URL(string: "vscode://file" + file.path(percentEncoded: false)))
        #expect(try String(contentsOf: file, encoding: .utf8) == SoundLibrary.starter)
    }
}
