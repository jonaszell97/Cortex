import Foundation

/// Where the app keeps its data.
///
/// On macOS (not sandboxed) this is `~/Library/Application Support/Cortex/`.
/// It is outside iCloud Desktop & Documents sync and included in Time Machine
/// on purpose: the database is encrypted.
///
/// On iOS it is `Library/Application Support/Cortex/` in the App Group
/// container, so the app's extensions reach it, and it is excluded from iCloud
/// backup: the phone holds a replica of what the Macs have (plans/IOS.md, §2).
public enum AppPaths {
    public static let directoryName = "Cortex"

    public static func dataDirectory(fileManager: FileManager = .default) throws -> URL {
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true)
        return try prepare(base.appending(path: directoryName, directoryHint: .isDirectory), fileManager: fileManager)
    }

    public static func databaseURL(fileManager: FileManager = .default) throws -> URL {
        try dataDirectory(fileManager: fileManager).appending(path: "Cortex.sqlite")
    }

    #if os(iOS)
    public enum ContainerError: Error, CustomStringConvertible {
        case noAppGroup(String)

        public var description: String {
            switch self {
            case .noAppGroup(let group): "The App Group \(group) isn't available to this app."
            }
        }
    }

    /// The data directory in the App Group container, excluded from backup.
    public static func dataDirectory(appGroup: String, fileManager: FileManager = .default) throws -> URL {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw ContainerError.noAppGroup(appGroup)
        }
        var directory = try prepare(
            container.appending(path: "Library/Application Support/\(directoryName)", directoryHint: .isDirectory),
            fileManager: fileManager)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        return directory
    }
    #endif

    private static func prepare(_ directory: URL, fileManager: FileManager) throws -> URL {
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return directory
    }
}
