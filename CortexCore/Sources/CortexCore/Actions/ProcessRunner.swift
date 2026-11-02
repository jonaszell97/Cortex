#if os(macOS)
import Foundation

/// Finds command-line tools. Apps started from Finder get a PATH without
/// Homebrew, so the usual places are searched explicitly.
public enum ToolLocator {
    public static let searchPath = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func find(_ name: String, fileManager: FileManager = .default) -> URL? {
        searchPath.lazy
            .map { URL(filePath: $0).appending(path: name) }
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    /// Like `find`, with an install hint as the error.
    public static func require(_ name: String, brewPackage: String? = nil) throws -> URL {
        guard let url = find(name) else {
            throw QuickActionError("\(name) is not installed. Install it with: brew install \(brewPackage ?? name)")
        }
        return url
    }

    /// The process environment with Homebrew on the PATH.
    public static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        environment["PATH"] = (searchPath + existing.filter { !searchPath.contains($0) }).joined(separator: ":")
        return environment
    }
}

public struct ProcessResult: Sendable {
    public var status: Int32
    public var output: Data
    /// The end of standard error (at most 16 KB).
    public var errorOutput: String

    public var outputText: String {
        String(decoding: output, as: UTF8.self)
    }

    /// The last non-empty lines of standard error, for an error message.
    public func errorSummary(lines: Int = 3) -> String {
        errorOutput.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }
}

/// Runs a process without blocking Swift concurrency's threads. Cancelling
/// the task terminates the process.
public enum ProcessRunner {
    /// Standard output kept in memory. A process that writes more is
    /// stopped and the run fails.
    public static let maxOutputBytes = 64 * 1024 * 1024

    public static func run(
        _ executable: URL,
        arguments: [String],
        input: Data? = nil,
        currentDirectory: URL? = nil,
        environment: [String: String] = ToolLocator.environment,
        maxOutputBytes: Int = maxOutputBytes,
        onErrorLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let inputPipe = input == nil ? nil : Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = inputPipe ?? FileHandle.nullDevice

        let exit = ExitStatus()
        process.terminationHandler = { exit.finish($0.terminationStatus) }
        try process.run()

        if let inputPipe, let input {
            let handle = inputPipe.fileHandleForWriting
            // Without this, writing after the process has exited raises SIGPIPE
            // and kills the host app instead of failing with EPIPE.
            _ = fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global().async {
                // The process may exit without reading; EPIPE is not an error here.
                try? handle.write(contentsOf: input)
                try? handle.close()
            }
        }
        let reference = ProcessReference(process)
        return try await withTaskCancellationHandler {
            async let output = readAll(outputPipe.fileHandleForReading, limit: maxOutputBytes, onOverflow: reference.terminate)
            async let errorOutput = readLines(errorPipe.fileHandleForReading, onLine: onErrorLine)
            let status = await exit.wait()
            let (data, overflowed) = await output
            let result = ProcessResult(status: status, output: data, errorOutput: await errorOutput)
            if Task.isCancelled { throw CancellationError() }
            if overflowed {
                let megabytes = maxOutputBytes / (1024 * 1024)
                throw QuickActionError("\(executable.lastPathComponent) wrote more than \(megabytes) MB of output and was stopped")
            }
            return result
        } onCancel: {
            reference.terminate()
        }
    }

    /// Everything the process writes, up to `limit` bytes. Past that the
    /// process is stopped, and the pipe closed in case it ignores SIGTERM.
    private static func readAll(
        _ handle: FileHandle, limit: Int, onOverflow: @escaping @Sendable () -> Void
    ) async -> (Data, overflowed: Bool) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var data = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    data.append(chunk)
                    if data.count > limit {
                        onOverflow()
                        try? handle.close()
                        continuation.resume(returning: (data.prefix(limit), true))
                        return
                    }
                }
                continuation.resume(returning: (data, false))
            }
        }
    }

    /// Splits on `\n` and `\r` (ffmpeg rewrites its status line with `\r`)
    /// and keeps the end for error messages.
    private static func readLines(_ handle: FileHandle, onLine: (@Sendable (String) -> Void)?) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var tail = Data()
                var pending = Data()
                while true {
                    let chunk = handle.availableData
                    if chunk.isEmpty { break }
                    tail.append(chunk)
                    if tail.count > 32_768 { tail = tail.suffix(16_384) }
                    guard let onLine else { continue }
                    pending.append(chunk)
                    while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                        let line = pending[pending.startIndex..<end]
                        pending = pending[(end + 1)...]
                        if !line.isEmpty { onLine(String(decoding: line, as: UTF8.self)) }
                    }
                }
                if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
                continuation.resume(returning: String(decoding: tail.suffix(16_384), as: UTF8.self))
            }
        }
    }
}

/// The exit status, whichever comes first: the process ending or someone
/// waiting for it.
private final class ExitStatus: @unchecked Sendable {
    private let lock = NSLock()
    private var status: Int32?
    private var continuation: CheckedContinuation<Int32, Never>?

    func finish(_ status: Int32) {
        lock.lock()
        if let continuation {
            self.continuation = nil
            lock.unlock()
            continuation.resume(returning: status)
        } else {
            self.status = status
            lock.unlock()
        }
    }

    func wait() async -> Int32 {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let status {
                lock.unlock()
                continuation.resume(returning: status)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

/// `Process` is thread-safe for `terminate()` but not marked `Sendable`.
private final class ProcessReference: @unchecked Sendable {
    private let process: Process

    init(_ process: Process) {
        self.process = process
    }

    func terminate() {
        if process.isRunning { process.terminate() }
    }
}
#endif
