import Foundation

/// Best-guess detection of secrets in copied text that the copying app did
/// not mark (see `SensitivityRules`): private keys, API tokens, credentials
/// in URLs, random-looking tokens and password-shaped strings.
///
/// Tuned to miss rather than to mask ordinary text. Structured secrets (keys,
/// prefixed tokens, JWTs) are found anywhere in the text; the shape-based
/// rules only look at a clip that is a single word. Commit hashes, UUIDs and
/// other hex strings, identifiers, file names, URLs, paths and e-mail
/// addresses are left alone.
public enum SensitiveTextDetector {
    public enum Reason: String, Sendable {
        case privateKey, knownToken, jwt, credentialsInURL, randomToken, password
    }

    /// Longer text is not scanned.
    static let maxScannedLength = 64 * 1024

    public static func looksSensitive(_ text: String) -> Bool {
        reason(for: text) != nil
    }

    public static func reason(for text: String) -> Reason? {
        guard text.utf16.count <= maxScannedLength else { return nil }
        if matches(Pattern.privateKey, text) { return .privateKey }
        if matches(Pattern.knownToken, text) { return .knownToken }
        if matches(Pattern.jwt, text) { return .jwt }
        if hasCredentialsInURL(text) { return .credentialsInURL }

        let word = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !word.isEmpty, word.allSatisfy({ $0.isASCII && !$0.isWhitespace }) else { return nil }
        if isRandomToken(word) { return .randomToken }
        if isPassword(word) { return .password }
        return nil
    }

    // MARK: - Structured secrets

    private enum Pattern {
        static let privateKey = regex(#"-----BEGIN (?:[A-Z0-9]+ )*PRIVATE KEY(?: BLOCK)?-----"#)

        /// Prefixes that services put on their secrets, each with the length
        /// and alphabet of what follows, so a word that merely starts the
        /// same way does not count.
        static let knownToken = regex(
            #"(?<![A-Za-z0-9_-])(?:"#
                + [
                    #"gh[pousr]_[A-Za-z0-9]{36,}"#, // GitHub
                    #"github_pat_[A-Za-z0-9_]{22,}"#,
                    #"glpat-[A-Za-z0-9_-]{20,}"#, // GitLab
                    #"sk-(?=[A-Za-z0-9_-]*[0-9])[A-Za-z0-9_-]{20,}"#, // OpenAI, Anthropic, DeepSeek…
                    #"(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}"#, // Stripe
                    #"whsec_[A-Za-z0-9+/]{16,}"#,
                    #"xox[abposr]-[A-Za-z0-9-]{10,}"#, // Slack
                    #"xapp-[A-Za-z0-9-]{10,}"#,
                    #"(?:AKIA|ASIA)[A-Z0-9]{16}"#, // AWS access key ID
                    #"AIza[A-Za-z0-9_-]{35}"#, // Google API key
                    #"ya29\.[A-Za-z0-9_-]{20,}"#, // Google OAuth
                    #"npm_[A-Za-z0-9]{36}"#,
                    #"pypi-[A-Za-z0-9_-]{50,}"#,
                    #"hf_[A-Za-z0-9]{30,}"#, // Hugging Face
                    #"do[por]_v1_[a-f0-9]{64}"#, // DigitalOcean
                    #"shp(?:at|ca|pa|ss)_[a-fA-F0-9]{32}"#, // Shopify
                    #"SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}"#, // SendGrid
                    #"lin_api_[A-Za-z0-9]{40}"#, // Linear
                    #"(?:secret_[A-Za-z0-9]{43}|ntn_[A-Za-z0-9]{40,})"#, // Notion
                    #"tskey-[A-Za-z0-9-]{20,}"#, // Tailscale
                    #"gl(?:c|sa)_[A-Za-z0-9_=+/-]{30,}"#, // Grafana
                    #"dp\.(?:pt|st|sa|ct|scim|audit)\.[A-Za-z0-9]{40,}"#, // Doppler
                    #"AGE-SECRET-KEY-1[0-9A-Z]{58}"#, // age
                    #"[0-9]{8,10}:AA[A-Za-z0-9_-]{33}"#, // Telegram bot
                    #"(?i:bearer)\s+(?=[A-Za-z0-9._~+/-]*[0-9])[A-Za-z0-9._~+/-]{20,}=*"#,
                ].joined(separator: "|")
                + #")(?![A-Za-z0-9_-])"#)

        /// Header and payload are base64url JSON objects, so both start `eyJ`.
        static let jwt = regex(#"(?<![A-Za-z0-9_-])eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#)

        /// `scheme://user:password@host`, capturing the password.
        static let credentialsInURL = regex(#"[A-Za-z][A-Za-z0-9+.-]*://[^\s:/@]+:([^\s/@]+)@[^\s/@]+"#)

        static let email = regex(#"^[^@]+@[^@]+\.[A-Za-z]{2,}$"#)

        /// Word, digits, punctuation: `Summer2024!`, `Welcome@123`.
        static let commonPassword = regex(#"^[A-Z][a-z]{3,}(?:[0-9]{1,6}[[:punct:]]{1,3}|[[:punct:]]{1,3}[0-9]{1,6})$"#)

        /// Safari's and Passwords' generated passwords: `abcdef-Ghijk1-mnopqr`.
        static let generatedPassword = regex(#"^[A-Za-z0-9]{6}-[A-Za-z0-9]{6}-[A-Za-z0-9]{6}$"#)

        private static func regex(_ pattern: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: pattern)
        }
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// Placeholders in documentation (`postgres://user:password@localhost`)
    /// are not credentials.
    private static let placeholderPasswords: Set<String> = ["password", "passwd", "pass", "pwd", "secret", "pw"]

    private static func hasCredentialsInURL(_ text: String) -> Bool {
        let matches = Pattern.credentialsInURL.matches(in: text, range: NSRange(text.startIndex..., in: text))
        return matches.contains { match in
            guard let range = Range(match.range(at: 1), in: text) else { return false }
            let password = text[range]
            if placeholderPasswords.contains(password.lowercased()) { return false }
            if password.allSatisfy({ $0 == "*" || $0 == "x" || $0 == "X" }) { return false }
            return !["$", "<", "{", "%", "["].contains { password.hasPrefix($0) }
        }
    }

    // MARK: - Shapes of single words

    /// Base64, base62 and similar: letters and digits that change class
    /// (lower, upper, digit) often, unlike identifiers and file names, which
    /// change only between words. Hex strings are hashes or IDs more often
    /// than secrets.
    static func isRandomToken(_ word: String) -> Bool {
        let tokenPunctuation: Set<Character> = ["+", "/", "=", "_", "-", ".", "~"]
        guard word.count >= 16, word.count <= 512,
              word.allSatisfy({ $0.isLetter || $0.isNumber || tokenPunctuation.contains($0) }),
              !looksLikeAddress(word)
        else { return false }

        let classes = CharacterClasses(word)
        guard classes.hasDigit, classes.hasLower || classes.hasUpper, !classes.isHex else { return false }
        guard entropy(word) >= 3 else { return false }
        if classes.hasLower && classes.hasUpper {
            return classes.transitionRatio >= 0.4
        }
        return word.count >= 24 && classes.transitionRatio >= 0.3
    }

    /// Short, with lower and upper case, digits and punctuation mixed
    /// throughout, or one of the common layouts.
    static func isPassword(_ word: String) -> Bool {
        guard word.count >= 8, word.count <= 64, !looksLikeAddress(word) else { return false }
        if matches(Pattern.commonPassword, word) { return true }
        let classes = CharacterClasses(word)
        if matches(Pattern.generatedPassword, word) {
            return classes.hasLower && classes.hasUpper && classes.hasDigit
        }
        return classes.hasLower && classes.hasUpper && classes.hasDigit && classes.hasPunctuation
            && classes.transitionRatio >= 0.4 && entropy(word) >= 2.5
    }

    /// URLs, paths, e-mail addresses and domain names.
    private static func looksLikeAddress(_ word: String) -> Bool {
        word.contains("://") || word.hasPrefix("/") || word.hasPrefix("~") || word.hasPrefix("./")
            || word.hasPrefix("../") || word.hasPrefix("www.") || matches(Pattern.email, word)
    }

    private struct CharacterClasses {
        var hasLower = false, hasUpper = false, hasDigit = false, hasPunctuation = false
        var isHex = true
        /// How often neighbouring letters and digits differ in class, with
        /// punctuation skipped: about 0.6 for random base62, 0.1–0.3 for
        /// `camelCase2Identifiers` and `IMG_2041.jpeg`.
        var transitionRatio = 0.0

        init(_ word: String) {
            var previous: Int?
            var pairs = 0, changes = 0
            for character in word {
                let current: Int
                if character.isLowercase { current = 0; hasLower = true }
                else if character.isUppercase { current = 1; hasUpper = true }
                else if character.isNumber { current = 2; hasDigit = true }
                else { hasPunctuation = true; continue }
                if character.isLetter && !character.isHexDigit { isHex = false }
                if let previous {
                    pairs += 1
                    if previous != current { changes += 1 }
                }
                previous = current
            }
            transitionRatio = pairs > 0 ? Double(changes) / Double(pairs) : 0
            if !hasLower && !hasUpper { isHex = false }
        }
    }

    /// Shannon entropy in bits per character.
    static func entropy(_ word: String) -> Double {
        var counts: [Character: Int] = [:]
        for character in word { counts[character, default: 0] += 1 }
        let total = Double(word.count)
        return counts.values.reduce(0) { sum, count in
            let p = Double(count) / total
            return sum - p * log2(p)
        }
    }
}
