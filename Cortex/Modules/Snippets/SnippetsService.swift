import AppKit
import CortexCore

/// Owns the snippet store and the actions on snippets: pasting, expanding,
/// editing, importing and exporting.
@MainActor
@Observable
final class SnippetsService {
    let settings: SnippetsSettings
    @ObservationIgnored let store: SnippetStore
    /// Older text clips for `{clipboard offset=n}`, by offset (1 and up);
    /// empty without the clipboard history.
    @ObservationIgnored private let clipboardHistory: @MainActor (_ maxOffset: Int) async -> [Int: String]
    @ObservationIgnored private let pasting: PasteService
    @ObservationIgnored private let log = Log.logger("snippets")

    /// Bumped after every change, so open views reload.
    private(set) var revision = 0
    /// Called with the keyword table after every change.
    @ObservationIgnored var onKeywordsChange: (([String: Int64]) -> Void)?

    init(
        database: AppDatabase,
        pasting: PasteService = PasteService(),
        settings: SnippetsSettings,
        clipboardHistory: @escaping @MainActor (_ maxOffset: Int) async -> [Int: String] = { _ in [:] }
    ) {
        self.settings = settings
        self.clipboardHistory = clipboardHistory
        self.pasting = pasting
        store = SnippetStore(database: database)
    }

    func start() {
        Task { await didChange(bumpRevision: false) }
    }

    // MARK: - Reading

    func all() async -> [Snippet] {
        await background { [store] in try await store.all() } ?? []
    }

    func snippet(id: Int64) async -> Snippet? {
        await background { [store] in try await store.snippet(id: id) } ?? nil
    }

    // MARK: - Editing

    /// Throws `SnippetStoreError` for the editor to show.
    @discardableResult
    func save(_ snippet: Snippet) async throws -> Snippet {
        let store = store
        let saved = try await Task.detached { try store.save(snippet) }.value
        await didChange()
        return saved
    }

    func delete(id: Int64) async {
        await background { [store] in try store.delete(id: id) }
        await didChange()
    }

    /// Sync changed snippets in the database: refreshes the keyword table and
    /// the open views.
    func reloadAfterSync() {
        Task { await didChange() }
    }

    private func didChange(bumpRevision: Bool = true) async {
        if bumpRevision { revision += 1 }
        let keywords = await background { [store] in try await store.keywords() } ?? [:]
        onKeywordsChange?(keywords)
    }

    // MARK: - Pasting

    /// Fills in the placeholders.
    func render(_ snippet: Snippet, fillIns: [String: String] = [:]) async -> RenderedSnippet {
        let template = snippet.template
        var clipboardTexts: [Int: String] = [:]
        if let maxOffset = template.clipboardOffsets.max() {
            clipboardTexts = await clipboardHistory(maxOffset)
            clipboardTexts[0] = NSPasteboard.general.string(forType: .string)
        }
        return template.render(in: SnippetContext(clipboard: clipboardTexts, fillIns: fillIns))
    }

    /// Pastes (or copies) a snippet into `target`, the same way a clip is
    /// pasted, and counts the use. The caller closes the palette first.
    func perform(
        _ action: PasteAction,
        snippet: Snippet,
        fillIns: [String: String] = [:],
        restoringPasteboard: Bool = false,
        into target: NSRunningApplication?
    ) async -> Bool {
        let rendered = await render(snippet, fillIns: fillIns)
        let done = await pasting.deliver(
            .text(rendered.text), action, charactersAfterCursor: rendered.charactersAfterCursor,
            restoringPasteboard: restoringPasteboard, into: target)
        if done, let id = snippet.id {
            await background { [store] in try store.markUsed(id: id) }
            revision += 1
        }
        return done
    }

    /// A keyword was typed in another app: delete it and paste the snippet in
    /// its place, keeping the clipboard as it was. Snippets with fill-ins
    /// open the palette's form instead.
    func expand(
        id: Int64,
        keyword: String,
        showFillIn: (Snippet) -> Void
    ) async {
        guard let snippet = await snippet(id: id) else { return }
        let target = NSWorkspace.shared.frontmostApplication
        // Let the keyword's last key reach the app before deleting it.
        try? await Task.sleep(for: .milliseconds(20))
        Paster.deleteBackward(count: keyword.count)
        log.debug("Expanding a keyword in \(target?.bundleIdentifier ?? "-", privacy: .public)")
        if snippet.template.fillIns.isEmpty {
            _ = await perform(.paste(.plainText), snippet: snippet, restoringPasteboard: true, into: target)
        } else {
            // The palette takes key events once it is key: let the backspaces
            // reach the target app first.
            try? await Task.sleep(for: .milliseconds(150))
            showFillIn(snippet)
        }
    }

    // MARK: - Raycast import and export

    func planRaycastImport(from url: URL) async throws -> SnippetImportPlan {
        let incoming = try await Task.detached { try RaycastSnippets.decode(Data(contentsOf: url)) }.value
        let existing = try await store.all()
        return SnippetImportPlan(incoming: incoming, existing: existing)
    }

    func applyImport(_ plan: SnippetImportPlan, replaceChanged: Bool) async throws -> SnippetImportReport {
        let store = store
        let report = try await Task.detached { try store.apply(plan, replaceChanged: replaceChanged) }.value
        await didChange()
        return report
    }

    /// Writes all snippets to `url` in Raycast's format. Returns how many.
    func exportRaycast(to url: URL) async throws -> Int {
        let snippets = try await store.all()
        let data = try RaycastSnippets.encode(snippets)
        try await Task.detached {
            try data.write(to: url, options: [.atomic])
            // Snippets hold addresses and signatures: readable only by the user.
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }.value
        log.info("Exported \(snippets.count) snippets")
        return snippets.count
    }

    /// Runs blocking store work off the main actor; logs and swallows errors.
    @discardableResult
    private func background<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async -> T? {
        do {
            return try await Task.detached(operation: work).value
        } catch {
            log.error("Snippet store operation failed: \(error, privacy: .public)")
            return nil
        }
    }
}
