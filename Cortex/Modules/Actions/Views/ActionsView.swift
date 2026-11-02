import SwiftUI
import CortexCore

/// The `>` scope: the actions on the left; on the right the input, the
/// selected action's result and its options.
struct ActionsView: View {
    let scope: ActionsScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: PaletteEmptyState(
                    title: scope.searchText.isEmpty ? "No actions for this input" : "No matching actions",
                    systemImage: "bolt.slash",
                    description: scope.searchText.isEmpty
                        ? "Select files in Finder, drop files here, or copy some text."
                        : "Search looks at action names and keywords. To type an input, use $ commands."),
                onActivate: { scope.run($0) }
            ) { action, shortcutNumber, isSelected in
                ActionRowView(action: action, shortcutNumber: shortcutNumber, isSelected: isSelected)
            }
        } preview: {
            VStack(spacing: 0) {
                if let action = scope.list.selected, let input = scope.input {
                    ActionPane(action: action, input: input, preview: scope.preview)
                } else {
                    ActionPreviewView(input: scope.context, action: nil, preview: nil)
                }
                if let action = scope.list.selected, !action.options.isEmpty {
                    Divider()
                    ActionOptionsView(options: action.options, values: scope.options) { option, value in
                        scope.setOption(option, to: value)
                    }
                }
            }
        }
    }
}

/// What an action does with its input: its preview or result, or for one
/// that is not previewed, what ⏎ will run.
struct ActionPane: View {
    let action: any QuickAction
    let input: ResolvedActionInput
    let preview: ActionPreview?

    var body: some View {
        if !action.isInstant, let plan = action.plan(for: input.input) {
            PlanView(symbol: action.symbol, plan: plan)
        } else {
            ActionPreviewView(input: input, action: action, preview: preview)
        }
    }
}

/// For a job: what ⏎ will run or do.
struct PlanView: View {
    let symbol: String
    let plan: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("⏎ runs in the background; its output is pasted or shown in a notification", systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(plan)
                .font(.body.monospaced())
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The pane `$` shows for a command (docs/modules/COMMANDS.md, "The pane"),
/// one layout for every outcome: the command as typed with its host, then the
/// body, drawn by the kind of outcome: the value, what opens or plays, what is
/// affected, the plan of the job, what is handed over to. Or a loading state,
/// the error, or the notice that there is nothing to do. While a new argument
/// is resolved, the body of the previous one stays, dimmed, with a small
/// progress indicator.
struct CommandOutcomeView: View {
    let command: any Command
    /// The command as typed (`$port 3000 @pi`); nil where a form shows it.
    let typed: String?
    let resolution: CommandResolution?
    /// What is loading: the loading state while there is no resolution to
    /// show, otherwise the resolution shown is for an earlier input.
    var loading: String?
    /// Why the value could not be refreshed; the last good one stays.
    var refreshProblem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let typed {
                CommandPaneHeader(typed: typed, host: resolution?.commandID == command.id ? resolution?.machine.alias : nil)
                Divider()
            }
            result
                .opacity(isStale ? 0.4 : 1)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            if let refreshProblem {
                Label("Couldn't refresh: \(refreshProblem)", systemImage: "exclamationmark.arrow.circlepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isStale {
                ProgressView()
                    .controlSize(.small)
                    .padding(typed == nil ? 12 : 10)
            }
        }
    }

    /// The body is for an earlier input than the header shows.
    private var isStale: Bool {
        loading != nil && resolution?.commandID == command.id
    }

    @ViewBuilder
    private var result: some View {
        if let resolution, resolution.commandID == command.id {
            switch resolution.result {
            case .failure(let error):
                if error.isNotice {
                    ActionNoticeView(message: error.message)
                } else {
                    ActionErrorView(message: error.message)
                }
            case .success(.value(let value, _)):
                ActionOutputView(output: value.output, presenter: command as? any ReportPresenting)
            case .success(.open(let target)):
                ActionOutputView(output: target.output)
            case .success(.act(let confirmation)):
                ActionOutputView(output: .confirm(confirmation))
            case .success(.job(let plan, _)):
                PlanView(symbol: command.symbol, plan: plan)
            case .success(.handoff(let description, _)):
                ContentUnavailableView(command.title, systemImage: command.symbol, description: Text(description))
            }
        } else if let loading {
            PreviewLoadingView(title: loading)
        } else {
            Color.clear
        }
    }
}

/// The first line of the pane: the command as typed, in monospace, and the
/// host it runs on.
struct CommandPaneHeader: View {
    let typed: String
    /// The host's alias; nil on this Mac.
    let host: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(typed)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if let host {
                TintedTag(title: "on \(host)", symbol: "server.rack", tint: .secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
