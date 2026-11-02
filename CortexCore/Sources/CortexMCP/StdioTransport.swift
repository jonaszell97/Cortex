import Foundation

/// MCP's stdio transport: one JSON-RPC message per line on stdin, the
/// answers one per line on stdout. Messages may hold any character but a
/// raw newline, so lines are split on `\n` only. stderr is for logs.
public enum StdioTransport {
    /// Serves until stdin closes or stdout is gone.
    public static func run(_ server: MCPServer) async {
        // A client that quits mid-answer would otherwise kill the process
        // with SIGPIPE; the write fails and the loop ends instead.
        signal(SIGPIPE, SIG_IGN)
        var buffer = Data()
        do {
            for try await byte in FileHandle.standardInput.bytes {
                guard byte == UInt8(ascii: "\n") else {
                    buffer.append(byte)
                    continue
                }
                let line = String(decoding: buffer, as: UTF8.self)
                buffer.removeAll(keepingCapacity: true)
                for answer in await server.receive(line) {
                    try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8))
                }
            }
            if !buffer.isEmpty {
                for answer in await server.receive(String(decoding: buffer, as: UTF8.self)) {
                    try FileHandle.standardOutput.write(contentsOf: Data((answer + "\n").utf8))
                }
            }
        } catch {
            log("cortex-mcp: \(error.localizedDescription)")
        }
    }

    public static func log(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data((message + "\n").utf8))
    }
}
