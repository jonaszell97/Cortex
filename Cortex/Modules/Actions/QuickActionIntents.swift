import AppIntents
import Foundation
import CortexCore
import UniformTypeIdentifiers

// Quick actions for Shortcuts and Spotlight: one intent for text, one for
// files. They run in Cortex's own process (it is launched if needed) and
// use the same actions as the palette, the user's TOML actions included.

struct QuickActionEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Quick Action"
    static let defaultQuery = QuickActionQuery()

    let id: String
    let title: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }

    init(_ action: any QuickAction) {
        id = action.id
        title = action.title
    }
}

struct QuickActionQuery: EntityStringQuery {
    @Dependency private var service: ActionsService

    func entities(for identifiers: [String]) async throws -> [QuickActionEntity] {
        await MainActor.run {
            service.shortcutActions.filter { identifiers.contains($0.id) }.map(QuickActionEntity.init)
        }
    }

    func entities(matching string: String) async throws -> [QuickActionEntity] {
        await MainActor.run {
            ActionCatalog.rank(service.shortcutActions, for: .text("x"), query: string)
                .map(QuickActionEntity.init)
        }
    }

    func suggestedEntities() async throws -> [QuickActionEntity] {
        await MainActor.run { service.shortcutActions.map(QuickActionEntity.init) }
    }
}

/// Only the actions that take text, for the text intent's picker.
struct TextActionOptions: DynamicOptionsProvider {
    @Dependency private var service: ActionsService

    func results() async throws -> [QuickActionEntity] {
        await MainActor.run {
            service.shortcutActions.filter { $0.accepts(.text("x")) }.map(QuickActionEntity.init)
        }
    }
}

/// Only the actions that take files.
struct FileActionOptions: DynamicOptionsProvider {
    @Dependency private var service: ActionsService

    func results() async throws -> [QuickActionEntity] {
        await MainActor.run {
            service.shortcutActions.filter { action in
                action is FileAction || (action as? UserAction)?.definition.accepts.contains(.files) == true
            }
            .map(QuickActionEntity.init)
        }
    }
}

struct TransformTextIntent: AppIntent {
    static let title: LocalizedStringResource = "Transform Text with Cortex"
    static let description = IntentDescription("Runs a Cortex quick action on text, such as Format JSON or Base64 Decode, and returns the result.")

    @Parameter(title: "Action", optionsProvider: TextActionOptions())
    var action: QuickActionEntity

    @Parameter(title: "Text", inputOptions: String.IntentInputOptions(multiline: true))
    var text: String

    @Dependency private var service: ActionsService

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action) on \(\.$text)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let output = try await service.runForIntent(actionID: action.id, input: .text(text))
        switch output {
        case .text(let result), .done(let result):
            return .result(value: result)
        case .report(let report):
            return .result(value: report.text)
        case .open(let url):
            return .result(value: url.absoluteString)
        case .reveal(let url):
            await service.showInFinder(url)
            return .result(value: url.path(percentEncoded: false))
        case .openWith(let url, let app):
            await service.open(url, with: app)
            return .result(value: url.path(percentEncoded: false))
        case .play(let url):
            await SoundPlayer.shared.play(url)
            return .result(value: url.path(percentEncoded: false))
        case .snippet(let body):
            await service.openSnippetEditor(body: body)
            return .result(value: body)
        case .image, .files, .confirm, .saveCommand, .handled:
            throw QuickActionError("\(action.title) does not return text")
        }
    }
}

struct RunFileActionIntent: AppIntent {
    static let title: LocalizedStringResource = "Run Cortex Action on Files"
    static let description = IntentDescription("Runs a Cortex quick action, such as Convert Image to JPEG or Convert Video to GIF, on files. Results are written next to the originals.")

    @Parameter(title: "Action", optionsProvider: FileActionOptions())
    var action: QuickActionEntity

    @Parameter(title: "Files", supportedContentTypes: [.item])
    var files: [IntentFile]

    @Dependency private var service: ActionsService

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$action) on \(\.$files)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "cortex-intent-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // Files Shortcuts passes as data only (from another action) are
        // written to scratch space first; their results are moved to Downloads.
        var urls: [URL] = []
        for file in files {
            if let url = file.fileURL {
                urls.append(url)
            } else {
                try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
                let url = scratch.appending(path: file.filename)
                try file.data.write(to: url)
                urls.append(url)
            }
        }
        let output = try await service.runForIntent(actionID: action.id, input: .files(urls))
        switch output {
        case .files(var results):
            // Results of written-out files are in the scratch folder: move them to Downloads.
            let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            for (index, result) in results.enumerated() where result.path.hasPrefix(scratch.path) {
                let destination = try OutputPath.reserve(result.lastPathComponent, in: downloads)
                try OutputPath.install(result, at: destination)
                results[index] = destination
            }
            return .result(value: results.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
        case .reveal(let url):
            await service.showInFinder(url)
            return .result(value: [])
        case .play(let url):
            await SoundPlayer.shared.play(url)
            return .result(value: [])
        case .done, .text, .report, .image, .snippet, .saveCommand, .confirm, .open, .openWith, .handled:
            return .result(value: [])
        }
    }
}

extension ActionsService {
    /// Runs an action for an intent, with the options last set in the
    /// palette, and returns its result instead of pasting it.
    func runForIntent(actionID: String, input: ActionInput) async throws -> ActionOutput {
        // App Intents cannot be unregistered when the module is switched off.
        guard isRunning else {
            throw QuickActionError("Quick Actions are switched off in Cortex Settings")
        }
        guard let action = shortcutActions.first(where: { $0.id == actionID }) else {
            throw QuickActionError("The action no longer exists")
        }
        guard action.accepts(input) else {
            throw QuickActionError("\(action.title) does not work on \(input.summary.lowercased())")
        }
        let fallback = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let context = try ActionContext.make(fallbackOutputDirectory: fallback, options: options(for: action))
        defer { context.removeTemporaryDirectory() }
        return try await action.run(input, context: context)
    }
}
