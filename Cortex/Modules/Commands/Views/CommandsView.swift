import SwiftUI
import CortexCore

/// The `$` scope: the commands on the left; on the right what the selected
/// command resolved to on what was typed, or what it takes.
struct CommandsView: View {
    let scope: CommandsScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: PaletteEmptyState(
                    title: scope.searchText.isEmpty ? "No commands" : "No matching commands",
                    systemImage: "terminal",
                    description: "Type a command's name, then its input: \(CommandsModule.prefix)port 3000"),
                onActivate: { scope.choose($0) }
            ) { command, shortcutNumber, isSelected in
                CommandRowView(
                    command: command, typedArgument: scope.isNamed(command) ? scope.query.argument : nil,
                    typedHosts: scope.isNamed(command) ? scope.query.hosts : [],
                    shortcutNumber: shortcutNumber, isSelected: isSelected)
            }
        } preview: {
            pane
        }
    }

    @ViewBuilder
    private var pane: some View {
        if let command = scope.list.selected {
            if command.accepts(scope.input(for: command)), let actions = scope.actions() {
                // A command that takes nothing shows only its outcome.
                actions.commandPane(
                    for: command, typed: scope.typed(command), resolution: scope.resolution,
                    loading: scope.loading(for: command),
                    refreshProblem: scope.refresh.problem)
            } else {
                CommandPane(command: command)
            }
        } else {
            Color.clear
        }
    }
}
