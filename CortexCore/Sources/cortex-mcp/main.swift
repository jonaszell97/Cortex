import CortexCore
import CortexMCP
import Foundation

// cortex-mcp: the knowledge base over MCP (stdio). Started by an MCP client:
//   claude mcp add --scope user cortex /Applications/Cortex.app/Contents/MacOS/cortex-mcp
// --folder (or CORTEX_KNOWLEDGE_FOLDER) points it at another folder than
// ~/.config/cortex/knowledge, --actions at another than ~/.config/cortex/actions.

let usage = """
    usage: cortex-mcp [--folder <path>] [--actions <path>]

    Serves the Cortex knowledge base and the action files over the Model
    Context Protocol on stdin and stdout. Started by an MCP client, e.g.:
      claude mcp add --scope user cortex \(CommandLine.arguments[0])
    """

var folderPath = ProcessInfo.processInfo.environment["CORTEX_KNOWLEDGE_FOLDER"].flatMap { $0.isEmpty ? nil : $0 }
var actionsPath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--folder":
        guard let path = arguments.popFirst() else {
            StdioTransport.log("cortex-mcp: --folder needs a path\n\n\(usage)")
            exit(64)
        }
        folderPath = path
    case "--actions":
        guard let path = arguments.popFirst() else {
            StdioTransport.log("cortex-mcp: --actions needs a path\n\n\(usage)")
            exit(64)
        }
        actionsPath = path
    case "--version":
        print("cortex-mcp \(MCPServer.version)")
        exit(0)
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        StdioTransport.log("cortex-mcp: unknown argument \(argument)\n\n\(usage)")
        exit(64)
    }
}

func directory(_ path: String) -> URL {
    URL(filePath: (path as NSString).expandingTildeInPath, directoryHint: .isDirectory)
}

let folder = KnowledgeFolder(root: folderPath.map(directory) ?? KnowledgeFolder.defaultDirectory())

do {
    try folder.prepare()
    let server = try MCPServer(
        folder: folder, actionsDirectory: actionsPath.map(directory) ?? UserActionLibrary.defaultDirectory(),
        workingDirectory: FileManager.default.currentDirectoryPath)
    await StdioTransport.run(server)
} catch {
    StdioTransport.log("cortex-mcp: \(error.localizedDescription)")
    exit(1)
}
