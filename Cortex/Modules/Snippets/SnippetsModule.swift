import SwiftUI
import CortexCore

/// `;` in the palette: saved texts with placeholders and fill-ins, pasted from
/// the palette or expanded when their keyword is typed in any app.
@MainActor
final class SnippetsModule: CortexModule, SnippetsAPI, SyncContributing {
    static let manifest = ModuleManifest(
        id: "snippets", name: "Snippets", summary: "Pastes saved texts from the palette or when you type their keyword.",
        symbol: "text.quote", trigger: .prefix(";"), placeholder: "snippets",
        requirements: [.database], permissions: [.accessibility], order: 20)

    /// nil without the database.
    let service: SnippetsService?
    let expander = KeywordExpander()
    private let editor: SnippetEditorWindowController?
    private let scope: SnippetsScope?
    private let context: ModuleContext
    /// The keyword tap's lifetime, between `start()` and `stop()`.
    private(set) var keywordExpansion: ModuleTask?
    private var isObservingRevision = false

    init(context: ModuleContext) {
        self.context = context
        let service = context.database.map { database in
            SnippetsService(
                database: database, pasting: context.pasting,
                settings: SnippetsSettings(defaults: context.defaults.store),
                clipboardHistory: { maxOffset in
                    await context.api(ClipboardAPI.self)?.recentTexts(upTo: maxOffset) ?? [:]
                })
        }
        self.service = service
        let editor = service.map(SnippetEditorWindowController.init(snippets:))
        self.editor = editor
        scope = service.map { service in
            SnippetsScope(
                load: { await service.all() },
                deliver: { snippet, action, fillIns, restoring, target in
                    await service.perform(action, snippet: snippet, fillIns: fillIns, restoringPasteboard: restoring, into: target)
                },
                edit: { request in editor?.show(request) },
                palette: { [context] in context.palette })
        }
    }

    var palette: (any PaletteScope)? { scope }

    var settingsView: AnyView? {
        guard let service else { return nil }
        return AnyView(SnippetsSettingsView(
            settings: service.settings, snippets: service, expander: expander,
            accessibility: context.accessibility, openEditor: { [weak self] in self?.showEditor() },
            requestAccessibility: { [context] in context.requestAccessibility() }))
    }

    func statusMenuItems() -> [StatusMenuItem] {
        guard editor != nil else { return [] }
        return [StatusMenuItem("Snippets…") { [weak self] in self?.showEditor() }]
    }

    func start() async {
        guard let service, let scope, keywordExpansion == nil else { return }
        let (expander, palette) = (expander, context.palette)
        service.onKeywordsChange = { keywords in expander.setKeywords(keywords) }
        expander.onMatch = { id, keyword in
            Task {
                await service.expand(id: id, keyword: keyword) { snippet in
                    // Over the app the keyword was typed in: Esc closes the
                    // palette, and pasting puts the clipboard back.
                    if palette.isVisible { palette.close() }
                    palette.show()
                    palette.present(scope.fillInOverlay(for: snippet, fromExpansion: true))
                }
            }
        }
        service.start()
        observeRevision()
        // The event tap runs exactly while keyword expansion is on.
        keywordExpansion = context.whileWanted(
            { [settings = service.settings] in settings.keywordExpansion },
            start: { expander.start() },
            stop: { expander.stop() })
    }

    func stop() {
        keywordExpansion?.cancel()
        keywordExpansion = nil
        expander.onMatch = nil
        service?.onKeywordsChange = nil
        isObservingRevision = false
        scope?.clear()
        editor?.close()
    }

    /// Edited snippets show up in the open palette.
    private func observeRevision() {
        isObservingRevision = true
        withObservationTracking {
            _ = service?.revision
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.isObservingRevision else { return }
                self.scope?.snippetsDidChange()
                self.observeRevision()
            }
        }
    }

    /// Opens the snippet editor as it was left (status menu, Settings).
    func showEditor() {
        editor?.show()
    }

    // MARK: - SnippetsAPI

    func editSnippet(_ request: SnippetEditRequest) {
        editor?.show(request)
    }

    // MARK: - SyncContributing

    var syncContributions: [SyncContribution] {
        service.map { [Self.syncContribution(for: $0)] } ?? []
    }

    /// Snippets; arriving ones refresh the keyword table and the open views.
    static func syncContribution(for service: SnippetsService) -> SyncContribution {
        SyncContribution(
            collection: .snippet, title: "Snippets", toggleKey: "syncSnippets",
            makeHandler: { SnippetSyncHandler(store: service.store) },
            didApplyRemoteChanges: { service.reloadAfterSync() })
    }
}
