import SwiftUI
import CortexCore

/// The Quick Actions page's sections below its hotkeys and folder: the
/// user's action files, their problems and the tools the built-in file
/// actions need.
struct ActionsSettingsView: View {
    let actions: ActionsService

    var body: some View {
        Section("Your actions") {
            if actions.userActions.isEmpty && actions.userCommands.isEmpty && actions.problems.isEmpty {
                Text("None yet. Each is a TOML file with a name, what it accepts (a > action) or its trigger word (a $ command), and a command or url. See the README for examples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // A file with both a trigger and `accepts` is shown once, as a command.
            ForEach(actions.userActions.filter { $0.definition.trigger == nil }, id: \.file) { action in
                fileRow(title: action.title, symbol: action.symbol, file: action.file, usage: nil)
            }
            ForEach(actions.userCommands, id: \.file) { command in
                fileRow(title: command.title, symbol: command.symbol, file: command.file, usage: command.usage)
            }
            ForEach(actions.problems) { problem in
                LabeledContent {
                    Text(problem.message)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.trailing)
                } label: {
                    Label(problem.file.lastPathComponent, systemImage: "exclamationmark.triangle")
                }
            }
        }

        Section {
            LabeledContent("Tools") {
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(ActionsService.tools, id: \.name) { tool in
                        if ToolLocator.find(tool.name) != nil {
                            Label("\(tool.name) (\(tool.usedFor))", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("\(tool.name) missing: brew install \(tool.package)", systemImage: "xmark.circle")
                                .foregroundStyle(.orange)
                                .textSelection(.enabled)
                        }
                    }
                }
                .font(.caption)
            }
        }
    }

    /// `usage`: how a command is typed after `$`.
    private func fileRow(title: String, symbol: String, file: URL, usage: String?) -> some View {
        LabeledContent {
            Text(([usage.map { "$" + $0 }, file.lastPathComponent].compactMap { $0 })
                .joined(separator: " · "))
                .foregroundStyle(.secondary)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}
