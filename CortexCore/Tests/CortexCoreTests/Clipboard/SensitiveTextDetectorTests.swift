import Foundation
import Testing
@testable import CortexCore

/// Tokens are put together at runtime so secret scanners do not flag the
/// test sources.
@Suite struct SensitiveTextDetectorTests {
    private static func token(_ prefix: String, _ body: String) -> String { prefix + body }

    static let sensitive: [(String, SensitiveTextDetector.Reason)] = [
        (token("-----BEGIN OPENSSH ", "PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----"), .privateKey),
        (token("-----BEGIN ", "PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASC"), .privateKey),
        (token("ghp_", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5"), .knownToken),
        (token("github_pat_", "11ABCDEFG0123456789_abcdefghijklmnop"), .knownToken),
        ("export OPENAI_API_KEY=" + token("sk-proj-", "Ab3dE5fG7hJ9kL1mN3pQ5rS7tU"), .knownToken),
        (token("sk-ant-api03-", "Ab3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5"), .knownToken),
        (token("sk_live_", "4eC39HqLyjWDarjtT1zdp7dc"), .knownToken),
        (token("AKIA", "IOSFODNN7EXAMPLE"), .knownToken),
        (token("xoxb-", "1234567890-0987654321-AbCdEfGhIjKl"), .knownToken),
        (token("AIza", "SyA1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q"), .knownToken),
        ("Authorization: Bearer " + token("Ab3dE5fG7h", "J9kL1mN3pQ5rS7tU9vW1"), .knownToken),
        (token("eyJhbGciOiJIUzI1NiJ9.", "eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"), .jwt),
        ("postgres://app:Xk29fLq3@db.internal:5432/app", .credentialsInURL),
        ("q8Zr3TfL0pW7xYv2Nc5Ka9Hd", .randomToken),
        ("3q2+7wZm9K1vR/0aPx8YcL4nTe6U2fBj", .randomToken),
        ("k3j9x2m8q7w1z5v4b6n0p3r8t2y7u1i9", .randomToken),
        ("  q8Zr3TfL0pW7xYv2Nc5Ka9Hd\n", .randomToken),
        ("xK9#mP2$vL8@qR4!", .password),
        ("Tr0ub4dor&3", .password),
        ("P@ssw0rd!", .password),
        ("Summer2024!", .password),
        ("Welcome@123", .password),
        ("abcdef-Ghijk1-mnopqr", .password),
    ]

    static let ordinary: [String] = [
        "",
        "hello",
        "Hello, world!",
        "Meeting notes for Monday",
        "let x = try Foo(bar: 2)",
        "Bearer authentication is described in RFC 6750.",
        "314b5ab9c0d1e2f3a4b5c6d7e8f9a0b1c2d3e4f5",
        "E621E1F8-C36C-495A-93FC-0C247A3E6E5F",
        "https://github.com/apple/swift/pull/12345",
        "https://example.com/?token=Ab3dE5fG7hJ9kL1mN3pQ",
        "postgres://user:password@localhost:5432/db",
        "redis://default:${REDIS_PASSWORD}@cache:6379",
        "/Users/someone/Developer/Cortex2",
        "~/Library/Application Support/Cortex",
        "someone2@example.com",
        "testRecordsUTF8TextAndHTML5Content",
        "MyViewController2",
        "IMG_20241022_123456.jpeg",
        "Screenshot2024-10-22at12.00.00.png",
        "com.apple.TextEdit",
        "NSPasteboard.PasteboardType",
        "user.address2Line",
        "task-management-for-small-teams-2024",
        "sk-learn",
        "v1.2.3-beta.4",
        "12345678901234567890",
        "#FF5733",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ",
        "1Z999AA10123456784",
        "aB1aB1aB1aB1aB1aB1aB1aB1",
        "Aa1!Aa1!Aa1!",
        "hunter2",
    ]

    @Test(arguments: sensitive)
    func flagsSecrets(_ text: String, _ reason: SensitiveTextDetector.Reason) {
        #expect(SensitiveTextDetector.reason(for: text) == reason)
    }

    @Test(arguments: ordinary)
    func leavesOrdinaryTextAlone(_ text: String) {
        #expect(SensitiveTextDetector.reason(for: text) == nil)
    }

    @Test func findsStructuredSecretsInLongerText() {
        let config = """
            [server]
            host = "example.com"
            token = "\(Self.token("glpat-", "Ab3dE5fG7hJ9kL1mN3pQ"))"
            """
        #expect(SensitiveTextDetector.reason(for: config) == .knownToken)
        // Shape-based rules only look at single words.
        #expect(!SensitiveTextDetector.looksSensitive("Your code is q8Zr3TfL0pW7xYv2Nc5Ka9Hd, see you"))
    }

    @Test func skipsVeryLongText() {
        let text = String(repeating: "lorem ipsum ", count: 10_000) + Self.token("ghp_", "aB3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5")
        #expect(!SensitiveTextDetector.looksSensitive(text))
    }
}
