import Foundation

/// A command as a quick action (docs/modules/COMMANDS.md, "Running through
/// Actions"): the adapter that lets Quick Actions run, preview, count and
/// deliver commands as it does its own actions. It keeps the command's `id`, so
/// usage counts and remembered options carry over, and maps the outcome to the
/// output a quick action returns:
///
/// - a value is `.text`, `.report` or `.image`; a secret is text too, recorded
///   as a sensitive clip (`hasSensitiveResult`);
/// - open is `.open`, `.reveal`, `.openWith` or `.play`;
/// - act is `.confirm`;
/// - a job is what its `run` returns, in the background (not `isInstant`);
/// - a handoff is `.handled`, once it has handed over.
///
/// Made with the outcome the palette showed, it runs exactly that one. Made
/// without (`>` offers a command through `matches`), it resolves when it is
/// run, and a job then runs where it stands, without a progress card. A
/// notice it resolves to ("Nothing is listening on port 3000") is `.done` with
/// that sentence.
public struct CommandAction: QuickAction {
    public let command: any Command
    /// What the command resolved to when it was selected; nil: resolve now.
    public let outcome: CommandOutcome?

    public init(_ command: any Command, outcome: CommandOutcome? = nil) {
        self.command = command
        self.outcome = outcome
    }

    public var id: String { command.id }
    public var title: String { command.title }
    public var symbol: String { command.symbol }
    public var keywords: [String] { command.keywords }
    public var options: [ActionOption] { command.options }
    public var isRemote: Bool { command.isRemote }

    /// Everything but a job it was made with: that one runs in the
    /// background.
    public var isInstant: Bool {
        if case .job = outcome { return false }
        return true
    }

    /// Its outcome is a secret (`$token`).
    public var hasSensitiveResult: Bool {
        if case .value(let value, _) = outcome { return value.isSecret }
        return false
    }

    public func accepts(_ input: ActionInput) -> Bool { command.accepts(input) }
    public func matches(_ input: ActionInput) -> Bool { command.matches(input) }

    public func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        if let outcome { return try await Self.perform(outcome, context: context) }
        let resolved: CommandOutcome
        do {
            resolved = try await command.resolve(CommandInvocation(input: input, options: context.options, machine: context.machine))
        } catch let notice as QuickActionError where notice.isNotice {
            // Nothing to do is not a failure: `>` posts the sentence.
            return .done(notice.message)
        }
        return try await Self.perform(resolved, context: context)
    }

    /// The step ⏎ takes for `outcome`, as the output a quick action returns.
    public static func perform(_ outcome: CommandOutcome, context: ActionContext) async throws -> ActionOutput {
        switch outcome {
        case .value(let value, _):
            return value.output
        case .open(let target):
            return target.output
        case .act(let confirmation):
            return .confirm(confirmation)
        case .job(_, let run):
            return try await run(context)
        case .handoff(_, let run):
            try await run()
            return .handled
        }
    }
}
