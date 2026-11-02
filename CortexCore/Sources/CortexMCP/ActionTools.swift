import CortexCore
import Foundation

/// `list_actions` and `create_action`: the action files of Quick Actions
/// (docs/modules/ACTIONS.md), which the app's folder watcher reloads.
extension MCPServer {
    /// The names of the commands the app's modules add (AI, Knowledge, Text
    /// Recognition, Colour Picker), which this process cannot load. A file
    /// with one of them as its trigger would be a problem in the app.
    static let moduleCommandNames = ["ask", "img", "note", "todo", "tidy", "ocr", "color"]

    func listActions() -> JSONValue {
        let contents = UserActionLibrary.load(from: actionsDirectory)
        var files: [String: UserActionDefinition] = [:]
        for action in contents.actions { files[action.file.lastPathComponent] = action.definition }
        for command in contents.commands { files[command.file.lastPathComponent] = command.definition }
        let listed = files.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }.map { file, definition in
            JSONValue.compact([
                "file": .string(file), "name": .string(definition.name), "trigger": definition.trigger.map(JSONValue.string),
                "accepts": definition.takesContext ? .array(definition.accepts.map(\.rawValue).sorted().map(JSONValue.string)) : nil,
                "url": definition.target.url.map(JSONValue.string), "command": definition.target.command.map(JSONValue.string),
            ])
        }
        let taken = CommandCatalog.builtIns.map(\.name) + Self.moduleCommandNames + contents.commands.compactMap(\.definition.trigger)
        return .compact([
            "folder": .string(Self.abbreviated(actionsDirectory)),
            "files": .array(listed),
            "problems": contents.problems.isEmpty ? nil : .array(contents.problems.map {
                ["file": .string($0.file.lastPathComponent), "message": .string($0.message)]
            }),
            "taken_triggers": .array(taken.map(JSONValue.string)),
        ])
    }

    func createAction(_ arguments: Arguments) throws -> JSONValue {
        var values: [String: UserActionFile.Value] = [:]
        for key in ["name", "trigger", "argument", "url", "command", "output", "output_extension", "output_suffix", "example", "matches", "symbol"] {
            if let value = try arguments.string(key) { values[key] = .string(value) }
        }
        for key in ["accepts", "extensions", "keywords"] {
            if let value = try arguments.strings(key) { values[key] = .strings(value) }
        }
        if try arguments.bool("confirm") { values["confirm"] = .bool(true) }
        try checkSensitive([try arguments.string("command"), try arguments.string("url")], arguments)
        if let trigger = try arguments.string("trigger")?.trimmingCharacters(in: CharacterSet(charactersIn: " $>")),
           Self.moduleCommandNames.contains(where: { SnippetSearch.fold($0) == SnippetSearch.fold(trigger) }) {
            throw ToolError("Nothing was written: “\(trigger)” is the name of one of the app's commands; pick another trigger.")
        }
        let file: UserActionFile
        do {
            file = try UserActionFile(values: values, fileName: try arguments.string("file"), directory: actionsDirectory)
            try file.write()
        } catch let error as QuickActionError {
            throw ToolError("Nothing was written: \(error.message).")
        }
        let definition = file.definition
        let usage = definition.trigger.map { definition.accepts.contains(.text) ? "$\($0) …" : "$\($0)" }
        return .compact([
            "path": .string(Self.abbreviated(file.file)),
            "kind": .string(definition.trigger == nil ? "action" : definition.takesContext ? "command and action" : "command"),
            "usage": usage.map(JSONValue.string),
            "accepts": .array(definition.accepts.map(\.rawValue).sorted().map(JSONValue.string)),
            "contents": .string(file.contents),
        ])
    }

    private static func abbreviated(_ url: URL) -> String {
        (url.path(percentEncoded: false) as NSString).abbreviatingWithTildeInPath
    }
}

private extension UserActionDefinition.Target {
    var url: String? {
        if case .url(let url) = self { url } else { nil }
    }

    var command: String? {
        if case .shell(let command) = self { command } else { nil }
    }
}
