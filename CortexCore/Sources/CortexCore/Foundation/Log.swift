import os

/// Logging goes through the unified logging system only, never to files.
///
/// View with Console.app or:
/// `log stream --predicate 'subsystem == "dev.jonaszell.cortex"' --level debug`
public enum Log {
    public static let subsystem = "dev.jonaszell.cortex"

    public static func logger(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static let database = logger("database")
    static let keychain = logger("keychain")
    static let sync = logger("sync")
}
