import Foundation
import CortexCore

extension Command {
    /// What the command resolves to on `input`.
    func resolve(_ input: ActionInput, options: ActionOptionValues = ActionOptionValues(), machine: Machine = .local) async throws -> CommandOutcome {
        try await resolve(CommandInvocation(input: input, options: options, machine: machine))
    }
}

extension CommandOutcome {
    /// The secret text of a value outcome.
    var secret: String? {
        if case .value(.secret(let text), _) = self { return text }
        return nil
    }
}
