import Foundation

/// Names for action results: next to the source, with a suffix, never
/// replacing an existing file.
public enum OutputPath {
    /// `photo.heic` → `photo.jpg`; `clip.mov` with suffix `-small` →
    /// `clip-small.mov`. When the result would have the source's own name
    /// (MP4 to MP4), `-converted` is added.
    public static func name(for source: URL, suffix: String = "", pathExtension: String) -> String {
        let base = source.deletingPathExtension().lastPathComponent
        var suffix = suffix
        if suffix.isEmpty, pathExtension.lowercased() == source.pathExtension.lowercased() {
            suffix = "-converted"
        }
        return pathExtension.isEmpty ? base + suffix : "\(base)\(suffix).\(pathExtension)"
    }

    /// `name.ext`, or `name 2.ext`, `name 3.ext` … if taken.
    public static func unique(_ fileName: String, in directory: URL, fileManager: FileManager = .default) -> URL {
        let first = directory.appending(path: fileName)
        guard fileManager.fileExists(atPath: first.path) else { return first }
        let base = (fileName as NSString).deletingPathExtension
        let pathExtension = (fileName as NSString).pathExtension
        for number in 2... {
            let candidate = directory.appending(path: pathExtension.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(pathExtension)")
            if !fileManager.fileExists(atPath: candidate.path) { return candidate }
        }
        fatalError("unreachable")
    }

    /// Creates an empty file under a free name (`O_EXCL`), so two running
    /// actions never pick the same one.
    public static func reserve(_ fileName: String, in directory: URL) throws -> URL {
        for _ in 0..<100 {
            let candidate = unique(fileName, in: directory)
            let fd = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY, 0o644)
            if fd >= 0 {
                close(fd)
                return candidate
            }
            guard errno == EEXIST else {
                throw QuickActionError("Cannot write to \(directory.path): \(String(cString: strerror(errno)))")
            }
        }
        throw QuickActionError("No free file name for \(fileName) in \(directory.path)")
    }

    /// Moves a finished result from scratch space onto its reserved name.
    public static func install(_ temporary: URL, at reserved: URL, fileManager: FileManager = .default) throws {
        do {
            _ = try fileManager.replaceItemAt(reserved, withItemAt: temporary)
        } catch {
            // Across volumes: replace the empty placeholder by hand.
            try? fileManager.removeItem(at: reserved)
            try fileManager.moveItem(at: temporary, to: reserved)
        }
    }
}
