import Foundation

/// `$token`, `$token 64`: a random token from the system's cryptographically
/// secure generator, 32 characters unless another length is typed. Format
/// picks the characters. Resolved as soon as it is selected, so ⏎ pastes the
/// one shown; it is a secret value, so the clip is sensitive.
public struct TokenCommand: Command {
    public let id = "command.token"
    public let name = "token"
    public let title = "Generate Token"
    public let summary = "Generates a cryptographically secure random token."
    public let symbol = "key"
    public let keywords = ["token", "secret", "random", "password", "key", "api", "generate", "hex"]
    public let argument: CommandArgument? = CommandArgument(
        title: "Length", placeholder: "\(defaultLength)", kind: .number(lengths), isRequired: false)
    public var options: [ActionOption] { [Self.format] }

    static let lengths = 8...512
    static let defaultLength = 32

    /// Which characters a token is made of.
    enum Format: String, CaseIterable {
        case alphanumeric, hex, urlSafe

        var title: String {
            switch self {
            case .alphanumeric: "Letters and digits"
            case .hex: "Hex"
            case .urlSafe: "URL-safe"
            }
        }

        var alphabet: [Character] {
            let digits = "0123456789"
            let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
            switch self {
            case .alphanumeric: return Array(letters + digits)
            case .hex: return Array(digits + "abcdef")
            case .urlSafe: return Array(letters + digits + "-_")
            }
        }
    }

    static let format = ActionOption(
        id: "format", title: "Format",
        kind: .choice(Format.allCases.map { .init($0.rawValue, title: $0.title) }),
        defaultValue: Format.alphanumeric.rawValue)

    public init() {}

    public func resolve(_ invocation: CommandInvocation) async throws -> CommandOutcome {
        let format = Format(rawValue: invocation.options[Self.format]) ?? .alphanumeric
        var generator = SystemRandomNumberGenerator()
        return .value(.secret(Self.token(length: try Self.length(of: invocation.input), alphabet: format.alphabet, using: &generator)))
    }

    /// The typed length, or the default for none.
    static func length(of input: ActionInput) throws -> Int {
        guard let text = input.text?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return defaultLength }
        guard let length = Int(text), lengths.contains(length) else {
            throw QuickActionError("Length must be a whole number from \(lengths.lowerBound) to \(lengths.upperBound)")
        }
        return length
    }

    /// Each character drawn uniformly from `alphabet` (`randomElement`
    /// rejects biased draws). `SystemRandomNumberGenerator` is the system's
    /// secure generator; tests may pass another.
    static func token(length: Int, alphabet: [Character], using generator: inout some RandomNumberGenerator) -> String {
        String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
    }
}
