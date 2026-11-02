import Foundation

/// A setting an action asks for, such as the length "Pad" pads to. The
/// palette shows them below the action's preview and remembers the values
/// per action.
public struct ActionOption: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        /// Free text, at most `maxLength` characters (typing more keeps the
        /// last ones, so a one-character field is overwritten by typing).
        case text(maxLength: Int? = nil)
        /// A whole number in the range.
        case number(ClosedRange<Int>)
        /// One of fixed values, shown as a segmented control.
        case choice([Choice])
    }

    public struct Choice: Sendable, Equatable {
        public let value: String
        public let title: String

        public init(_ value: String, title: String) {
            self.value = value
            self.title = title
        }
    }

    /// Stable: remembered values are stored under it.
    public let id: String
    public let title: String
    public let kind: Kind
    public let defaultValue: String

    public init(id: String, title: String, kind: Kind, defaultValue: String) {
        self.id = id
        self.title = title
        self.kind = kind
        self.defaultValue = defaultValue
    }
}

/// Option values by option ID, as entered: a number field holds text, so
/// numbers are checked when the action runs. Options without a value have
/// their default.
public struct ActionOptionValues: Sendable, Equatable {
    public var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public subscript(option: ActionOption) -> String {
        get { values[option.id] ?? option.defaultValue }
        set { values[option.id] = newValue }
    }

    /// The value of a `.number` option, or an error saying what is allowed.
    public func integer(_ option: ActionOption) throws -> Int {
        guard case .number(let range) = option.kind else {
            preconditionFailure("\(option.id) is not a number option")
        }
        guard let value = Int(self[option].trimmingCharacters(in: .whitespaces)), range.contains(value) else {
            throw QuickActionError("\(option.title) must be a whole number from \(range.lowerBound) to \(range.upperBound)")
        }
        return value
    }

    /// The value of an option that must be exactly one character.
    public func character(_ option: ActionOption) throws -> Character {
        let value = self[option]
        guard value.count == 1, let character = value.first else {
            throw QuickActionError("\(option.title): enter one character")
        }
        return character
    }
}
