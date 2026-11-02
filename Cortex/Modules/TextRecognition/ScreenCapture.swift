import Foundation
import CortexCore

/// Lets the user select a region of the screen and hands back its image.
/// Tests hand in a fake, so no crosshair appears.
@MainActor
protocol ScreenCapturing: AnyObject {
    /// PNG data of the region, or nil if the user pressed Esc.
    func capture() async throws -> Data?
}

/// The system's selection, as with ⌘⇧4: drag a region, Space for a window,
/// Esc to cancel (`screencapture -i`). The image goes through a private
/// temporary directory and is deleted as soon as it is read.
@MainActor
final class SystemScreenCapture: ScreenCapturing {
    static let tool = URL(filePath: "/usr/sbin/screencapture")

    func capture() async throws -> Data? {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "Cortex-Capture-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appending(path: "capture.png")

        // -i: select interactively, -x: no sound, -o: no window shadow.
        let result = try await ProcessRunner.run(Self.tool, arguments: ["-i", "-x", "-o", "-t", "png", file.path])
        // Esc leaves no file; that, not the exit status, means cancelled.
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard result.status == 0 else { throw QuickActionError(result.errorSummary()) }
        return try Data(contentsOf: file)
    }
}
