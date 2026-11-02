import AppKit
import SwiftUI
import CortexCore

/// What the Actions module offers other modules: opening `>`, and running
/// commands for another scope (`$` runs its commands through it, with the
/// same confirmations, jobs, usage counts and delivery).
@MainActor
protocol ActionsAPI: AnyObject {
    /// Opens `>` in the palette on `input`, or (nil) on the Finder selection
    /// or the clipboard.
    func showActions(on input: ResolvedActionInput?)

    /// What a command resolves to on this input, off the main thread; nil for
    /// an input it does not take. nil options: the remembered ones. `machine`
    /// is where a command that runs on hosts runs (`CommandInvocation.machine`).
    func resolve(_ command: any Command, input: ActionInput, options: ActionOptionValues?, machine: Machine) async -> CommandResolution?
    /// Carries the command out with its remembered options and delivers the
    /// result; uses `resolution`'s outcome if it is for the same input,
    /// options and machine, and resolves again otherwise. `summary` is what
    /// the progress card shows for a job ("$port 3000"). False when a paste
    /// was wanted but Accessibility is missing.
    func run(_ command: any Command, input: ActionInput, machine: Machine, resolution: CommandResolution?, delivery: ActionDelivery, summary: String?) async -> Bool
    func options(for command: any Command) -> ActionOptionValues
    func setOptions(_ values: ActionOptionValues, for command: any Command)
    /// By action ID, for ranking.
    var usage: [String: ActionUsage] { get }

    /// The user's command files (definitions with a `trigger`).
    var userCommands: [UserCommand] { get }
    /// Called whenever the actions folder changed and was read again.
    func onUserFilesChanged(_ handler: @escaping @MainActor () -> Void)

    /// The pane `$` shows for a command on an input: what it resolved to
    /// (the value, what opens, what is affected, the plan of the job, what
    /// is handed over to), why it did not, or a notice that there is nothing
    /// to do. `typed` is the command as typed (`$port 3000 @pi`), the
    /// header over the body; nil leaves it out (a `$` form shows it in its
    /// fields). `loading`: what is being loaded ("Memory Usage on pi") while
    /// there is nothing to show yet, or the resolution given is for an earlier
    /// input and is shown dimmed until the new one is there. `refreshProblem`: why the value shown
    /// could not be refreshed.
    func commandPane(for command: any Command, typed: String?, resolution: CommandResolution?, loading: String?, refreshProblem: String?) -> AnyView
}

/// The result of an instant action, computed while it is selected in the
/// palette. Running the action uses exactly this result.
struct ActionPreview {
    var actionID: String
    var input: ActionInput
    var options: ActionOptionValues
    /// Where it was computed; a run on another machine does not use it.
    var machine: Machine = .local
    var result: Result<ActionOutput, QuickActionError>
}

/// What a command resolved to while it was selected in `$`, or why it could
/// not. Running the command carries out exactly this outcome.
struct CommandResolution {
    var commandID: String
    var input: ActionInput
    var options: ActionOptionValues
    /// Where it was resolved (`$mem @pi`); a run on another machine does
    /// not use it.
    var machine: Machine = .local
    var result: Result<CommandOutcome, QuickActionError>

    /// The outcome, when the command resolved to one.
    var outcome: CommandOutcome? {
        if case .success(let outcome) = result { return outcome }
        return nil
    }

    /// Whether it was resolved for this command, input, options and machine.
    func isFor(_ command: any Command, input: ActionInput, options: ActionOptionValues, machine: Machine) -> Bool {
        commandID == command.id && self.input == input && self.options == options && self.machine == machine
    }
}

/// The pane while a command is being resolved (`$` shows it before
/// `commandPane` has a resolution to draw).
struct PreviewLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading \(title)…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A command that draws its `.report` values in the palette's pane instead
/// of showing their text (`$disk`, `$mem`). ⏎ still pastes the text.
protocol ReportPresenting: Command {
    /// What the command puts in `ActionReport.content`.
    associatedtype Content: Sendable
    associatedtype ReportView: View

    @MainActor func reportView(for content: Content) -> ReportView
}

extension ReportPresenting {
    /// The pane for `report`, or nil when its content is not this command's
    /// (then its text is shown).
    @MainActor func view(for report: ActionReport) -> AnyView? {
        (report.content as? Content).map { AnyView(reportView(for: $0)) }
    }
}

/// Where an action's text or image result goes.
enum ActionDelivery: Equatable {
    /// Paste a text or image result into this app (it was frontmost
    /// before the palette opened).
    case paste(NSRunningApplication?)
    /// Only put a text or image result on the clipboard.
    case copy
    /// Like `paste`, for text that was selected in that app: the result
    /// replaces the selection, is not recorded as a clip, and the
    /// clipboard is put back as it was.
    case replaceSelection(NSRunningApplication?)
}

/// A module that adds quick actions to `>` and to Shortcuts (AI). Asked
/// whenever the actions are listed, so the actions of a module that is
/// switched off disappear, and Quick Actions names no module. Commands come
/// through the Commands module's `CommandContributing` instead.
@MainActor
protocol ActionContributing: AnyObject {
    /// Listed after the built-ins, before the user's action files. IDs and
    /// triggers must not clash with the built-ins'.
    var contributedActions: [any QuickAction] { get }
}

/// A quick action's input together with where it came from, for the
/// palette's input pane.
struct ResolvedActionInput: Equatable {
    enum Source: Equatable {
        case clip, pasteboard, finder, dropped, service, selection
        /// Typed after a command's name (`$`).
        case typed

        var label: String {
            switch self {
            case .clip: "Selected clip"
            case .pasteboard: "Clipboard"
            case .finder: "Finder selection"
            case .dropped: "Dropped"
            case .service: "From Services"
            case .selection: "Selection"
            case .typed: "Typed"
            }
        }
    }

    var input: ActionInput
    var source: Source
    /// Why the Finder selection could not be read (Automation permission).
    var problem: String?
    /// Made from a sensitive clip or password-manager copy: results are
    /// recorded as sensitive too.
    var isSensitive = false

    /// A clip from the history (⌘K).
    static func clip(_ detail: ClipDetail) -> ResolvedActionInput {
        ResolvedActionInput(input: ActionInput(detail), source: .clip, isSensitive: detail.item.isSensitive)
    }
}
