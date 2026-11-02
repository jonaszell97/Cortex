import AppKit

/// The system alert sound, for a key that does nothing (⏎ on a failed
/// preview, an empty required field). Silent while the app only hosts the
/// unit tests: they press such keys on purpose, and would otherwise beep in
/// bursts whenever the tests run in the background.
enum Beep {
    static func play() {
        guard !isHostingTests else { return }
        NSSound.beep()
    }

    private static let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
