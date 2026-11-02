import Foundation
import SwiftUI
import CortexCore

/// Keeps a shown value fresh (docs/modules/COMMANDS.md, "Live refresh"): while
/// a command's outcome is `.value(_, refresh: d)` (`$mem`, `$cpu`,
/// `$gpu`: every 2 seconds), the command is resolved again `d` after the
/// last lookup finished, never two at once, and the new value replaces the
/// old one without a loading state, animated so bars and numbers glide. A lookup that fails leaves the last good
/// value in place and says why in `problem`; the next one tries again.
///
/// The owner (the scope, a form) calls `stop` whenever what is shown stops
/// being the value (another command, text, host or field), and `follow` with
/// every resolution it has just made.
@MainActor
@Observable
final class CommandRefresh {
    /// Why the last lookup failed; nil once one worked again, or none ran.
    private(set) var problem: String?
    /// Replaces how often the value asks to be refreshed (tests make it
    /// short); nil: the value's own.
    @ObservationIgnored var interval: Duration?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// Whether it is waiting for, or doing, the next lookup.
    var isRunning: Bool { task != nil }

    /// Starts refreshing `resolution` if its outcome asks for it, and stops
    /// any earlier one. `replace` is given each new resolution.
    func follow(
        _ resolution: CommandResolution, of command: any Command, using actions: any ActionsAPI,
        replace: @escaping @MainActor (CommandResolution) -> Void
    ) {
        stop()
        guard case .value(_, let refresh?) = resolution.outcome else { return }
        task = Task { [weak self] in
            var shown = resolution
            while !Task.isCancelled, case .value(_, let refresh?) = shown.outcome {
                guard let wait = self.map({ $0.interval ?? refresh }) else { return }
                try? await Task.sleep(for: wait)
                guard !Task.isCancelled else { return }
                let next = await actions.resolve(command, input: shown.input, options: shown.options, machine: shown.machine)
                guard !Task.isCancelled, let self else { return }
                guard let next else { break }
                if case .failure(let error) = next.result {
                    problem = error.message
                    continue
                }
                problem = nil
                shown = next
                withAnimation(.smooth(duration: 0.6)) { replace(next) }
            }
            if !Task.isCancelled { self?.task = nil }
        }
    }

    /// Nothing more is looked up, and an earlier problem is forgotten.
    func stop() {
        task?.cancel()
        task = nil
        problem = nil
    }
}
