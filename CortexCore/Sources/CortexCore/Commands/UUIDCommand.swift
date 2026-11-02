import Foundation

/// `$uuid`: a new random UUID. Resolved as soon as it is selected, so ⏎
/// pastes the one shown; like any text value it stays on the clipboard, and
/// ⌥⏎ only copies it.
public struct UUIDCommand: Command {
    public let id = "command.uuid"
    public let name = "uuid"
    public let title = "Generate UUID"
    public let summary = "Generates a random UUID and copies it."
    public let symbol = "number.square"
    public let keywords = ["uuid", "guid", "random", "id", "generate"]

    public init() {}

    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        .value(.text(UUID().uuidString))
    }
}
