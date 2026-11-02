import SwiftUI
import CortexCore

/// `$` in the palette: commands that run on what is typed after their name
/// (`$port 3000`, `$kill node`, `$ask …`), never on the clipboard or a
/// selection (docs/modules/COMMANDS.md). The built-ins, other modules' commands
/// (`CommandContributing`) and the user's files with a `trigger`. Each resolves
/// to an outcome that Quick Actions carries out (`ActionsAPI`): the same
/// confirmations, jobs, usage counts and delivery.
@MainActor
final class CommandsModule: CortexModule {
    /// The palette trigger.
    static let prefix = "$"

    static let manifest = ModuleManifest(
        id: "commands", name: "Commands",
        summary: "Runs commands on what you type: $port 3000, $ask …",
        symbol: "terminal", trigger: .prefix(prefix), placeholder: "cmd",
        requirements: [.module("actions")], order: 32)

    private let scope: CommandsScope
    private let context: ModuleContext
    private var isRunning = false
    private var isObservingUserFiles = false

    init(context: ModuleContext) {
        self.context = context
        scope = CommandsScope(
            commands: { [context] in Self.commands(in: context) },
            actions: { [context] in context.api(ActionsAPI.self) },
            palette: { [context] in context.palette },
            sources: CommandSuggestionSources(
                pasteboardText: {
                    let pasteboard = ResolvedActionInput.pasteboard()
                    return pasteboard.isSensitive ? nil : pasteboard.input.text
                },
                recentTexts: { [context] limit in
                    // Without the history, only the pasteboard is suggested.
                    await context.api(ClipboardAPI.self)?.recentTexts(limit: limit) ?? []
                }))
    }

    var palette: (any PaletteScope)? { scope }

    var settingsView: AnyView? {
        AnyView(CommandsSettingsView { [context] in Self.listing(in: context) })
    }

    func start() async {
        isRunning = true
        // Once: Quick Actions keeps the handler, and it does nothing while off.
        guard !isObservingUserFiles, let actions = context.api(ActionsAPI.self) else { return }
        isObservingUserFiles = true
        actions.onUserFilesChanged { [weak self] in
            guard let self, self.isRunning else { return }
            self.scope.commandsDidChange()
        }
    }

    func stop() {
        isRunning = false
        scope.clear()
    }

    /// Every command that can be typed: the built-ins, other modules', then
    /// the user's files. One whose name an earlier one has is left out.
    static func commands(in context: ModuleContext) -> [any Command] {
        let all = listing(in: context).map(\.command)
        let clashing = Set(CommandCatalog.problems(in: all).map(\.id))
        return all.filter { !clashing.contains($0.id) }
    }

    /// The commands with where each is from, for the settings page.
    static func listing(in context: ModuleContext) -> [(command: any Command, source: String)] {
        let builtIns = CommandCatalog.builtIns.map { (command: $0, source: "Built in") }
        let contributed = context.apis(CommandContributing.self).flatMap { module in
            let name = (module as? any CortexModule).map { ModuleHost.manifest(of: $0).name } ?? "Another module"
            return module.contributedCommands.map { (command: $0, source: name) }
        }
        let user = (context.api(ActionsAPI.self)?.userCommands ?? []).map { (command: $0 as any Command, source: $0.file.lastPathComponent) }
        return builtIns + contributed + user
    }
}
