import AppKit
import SwiftUI
import Testing
@testable import Cortex
import CortexCore

/// Draws the README's screenshots and the frames of its demo GIF from the
/// real palette on demo data. Skipped unless CORTEX_SCREENSHOTS names an
/// output folder: `make screenshots` (docs/DEVELOPMENT.md, "Screenshots").
@MainActor
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CORTEX_SCREENSHOTS"] != nil))
struct ReadmeScreenshots {
    let output = URL(
        filePath: ProcessInfo.processInfo.environment["CORTEX_SCREENSHOTS"] ?? "/tmp", directoryHint: .isDirectory)

    @Test func screenshots() async throws {
        let studio = try await ScreenshotStudio(output: output.appending(path: "raw"))
        defer { studio.tearDown() }
        try studio.shootIcon()

        try await studio.type("")
        try await studio.down(1)
        try studio.shoot("clipboard", dark: true)
        try studio.shoot("clipboard", dark: false)

        // The indexer reads image clips at background priority, which can
        // take long while the studio keeps the main actor busy: read the
        // screenshot's text the way it does.
        let clips = ClipStore(database: studio.database)
        for id in try await clips.unrecognizedImageIDs(limit: 10) {
            let text = try await TextRecognizer().recognize(try #require(await clips.imageData(id: id)))
            try clips.setRecognizedText(text, id: id, indexSensitive: false)
        }
        try await studio.type("failed")
        try studio.shoot("text-recognition", dark: true)
        try studio.shoot("text-recognition", dark: false)

        try await studio.type("FF5F87")
        try studio.shoot("color", dark: true)
        try studio.shoot("color", dark: false)

        try await studio.type(";")
        try await studio.down(1)
        try studio.shoot("snippets", dark: true)
        try studio.shoot("snippets", dark: false)

        try await studio.type("")
        try await studio.down(1)
        try await studio.press(.combo(.command("k")), wait: .milliseconds(900))
        try await studio.type(studio.model.query + "json", wait: .milliseconds(900))
        try studio.shoot("actions", dark: true)
        try studio.shoot("actions", dark: false)

        try await studio.type("$")
        try studio.shoot("commands", dark: true)
        try studio.shoot("commands", dark: false)

        // ⇥ opens the form with what was typed; nothing is sent before ⏎.
        try await studio.type("$ask Why does my code only work when someone is watching?")
        try await studio.press(.combo(.tab), wait: .milliseconds(900))
        try studio.shoot("ai", dark: true)
        try studio.shoot("ai", dark: false)
        studio.model.overlay = nil

        try await studio.type("+")
        try studio.shoot("reading-list", dark: true)
        try studio.shoot("reading-list", dark: false)

        try await studio.type("?pi reboot")
        try studio.shoot("knowledge", dark: true)
        try studio.shoot("knowledge", dark: false)

        try await studio.type("!")
        try studio.shoot("todos", dark: true)
        try studio.shoot("todos", dark: false)

        try await studio.type(":heart")
        try studio.shoot("emoji", dark: true)
        try studio.shoot("emoji", dark: false)

        try await studio.type("::cloud")
        try studio.shoot("symbols", dark: true)
        try studio.shoot("symbols", dark: false)

        try await studio.type("=88 mph in km/h")
        try studio.shoot("calculator", dark: true)
        try studio.shoot("calculator", dark: false)

        try await windows(studio)
        try await gif(studio)
    }

    /// A tour: the history, searching it, snippets, the calculator, emoji
    /// and a note. compose.sh turns the frames into docs/images/demo.gif.
    private func gif(_ studio: ScreenshotStudio) async throws {
        try await studio.type("")
        try studio.frame(1.6)
        try await studio.typeFrames("dock")
        try studio.frame(1.4)

        try await studio.type("")
        try await studio.typeFrames(";")
        try await studio.down(1)
        try studio.frame(0.7)
        try await studio.down(1)
        try studio.frame(1.4)

        try await studio.type("")
        try studio.frame(0.3)
        try await studio.typeFrames("=88 mph in km/h")
        try studio.frame(1.6)

        try await studio.type("")
        try studio.frame(0.3)
        try await studio.typeFrames(":party")
        try studio.frame(1.4)

        try await studio.type("")
        try studio.frame(0.3)
        try await studio.typeFrames("?pi reb")
        try studio.frame(2.0)

        try await studio.type("")
        try studio.frame(0.3)
        try await studio.typeFrames("!")
        try studio.frame(1.8)
        try studio.writeFrameList()
    }

    /// Module pages of Settings, each in a window of its own: the settings
    /// window's glass sidebar does not draw off screen.
    private func windows(_ studio: ScreenshotStudio) async throws {
        // The test host has no Accessibility grant, so Scrolling's page ends
        // in a warning: the window stops above it, as if scrolled.
        for (id, height) in [("sync", 455.0), ("scrolling", 425.0)] {
            let module = try #require(studio.host.modules.first { ModuleHost.manifest(of: $0).id.rawValue == id })
            let window = studio.makeWindow(
                size: CGSize(width: 620, height: height),
                ModuleSettingsPage(module: module, host: studio.host))
            try await Task.sleep(for: .seconds(1))
            try studio.shootWindow("settings-\(id)", window, dark: false)
            try studio.shootWindow("settings-\(id)", window, dark: true)
            window.orderOut(nil)
        }
    }
}
