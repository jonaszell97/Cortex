import Foundation
@testable import CortexCore

extension Command {
    /// What the command resolves to on `input`.
    func resolve(_ input: ActionInput, options: ActionOptionValues = ActionOptionValues(), machine: Machine = .local) async throws -> CommandOutcome {
        try await resolve(CommandInvocation(input: input, options: options, machine: machine))
    }

    /// What ⏎ yields as Quick Actions delivers it: the outcome carried out by
    /// the adapter (`CommandAction`), resolved on the context's options and
    /// machine.
    func output(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput {
        try await CommandAction(self).run(input, context: context)
    }
}

extension CommandOutcome {
    /// The secret text of a value outcome.
    var secret: String? {
        if case .value(.secret(let text), _) = self { return text }
        return nil
    }

    /// What an `act` outcome asks.
    var confirmation: ActionConfirmation? {
        if case .act(let confirmation) = self { return confirmation }
        return nil
    }
}
