import Foundation

/// What a quick action works on: the selected clip, the pasteboard, the
/// Finder selection or files dropped onto Cortex.
public enum ActionInput: Sendable, Equatable {
    case none
    case text(String)
    /// PNG or TIFF data, from the clipboard.
    case image(Data)
    case files([URL])

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case none, text, image, files
    }

    public var kind: Kind {
        switch self {
        case .none: .none
        case .text: .text
        case .image: .image
        case .files: .files
        }
    }

    public var text: String? {
        if case .text(let text) = self { return text }
        return nil
    }

    public var fileURLs: [URL] {
        if case .files(let urls) = self { return urls }
        return []
    }

    /// One line for the palette: "3 files", "Text, 120 characters".
    public var summary: String {
        switch self {
        case .none:
            return "Nothing"
        case .text(let text):
            return text.count == 1 ? "Text, 1 character" : "Text, \(text.count) characters"
        case .image(let data):
            return "Image, \(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))"
        case .files(let urls):
            return urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        }
    }
}

/// What a quick action produces.
public enum ActionOutput: Sendable, Equatable {
    /// Pasted or copied, like a snippet.
    case text(String)
    /// Text pasted or copied like `.text`, which the palette may draw as a
    /// view of its own instead of showing the text (`$disk`, `$mem`).
    case report(ActionReport)
    /// PNG data, pasted or copied.
    case image(Data)
    /// Written next to the source (or to the fallback directory); shown in
    /// Finder from a notification.
    case files([URL])
    /// Nothing to paste: the message is shown as a notification.
    case done(String)
    /// Opens the snippet editor on a new snippet with this text as its
    /// body; nothing is pasted or copied.
    case snippet(String)
    /// Asks what to call this shell command and saves it as a `$` command
    /// file (`CommandFile`); nothing is pasted or copied.
    case saveCommand(String)
    /// Asks first, then runs the confirmed step and delivers its output.
    case confirm(ActionConfirmation)
    /// Opens a URL (web page, app link) with its default app.
    case open(URL)
    /// Shows a file or folder in Finder (`$open`): a folder opens in a
    /// window, anything else (a file, an app or another package) is
    /// selected in its folder.
    case reveal(URL)
    /// Opens a file or folder with this app (`$term`: a new terminal window
    /// in a folder); nothing is pasted or copied.
    case openWith(URL, app: URL)
    /// Plays a sound or movie file's sound (`$sound`); nothing is pasted
    /// or copied.
    case play(URL)
    /// The action delivers its result itself (`$color` hands over to the
    /// eyedropper, which copies the picked colour): nothing to paste, copy
    /// or show.
    case handled

    /// What is pasted or copied: the text of `.text` and `.report`.
    public var text: String? {
        switch self {
        case .text(let text): text
        case .report(let report): report.text
        default: nil
        }
    }
}

/// A result that is text to paste, and data the palette draws its own view
/// from (an app-side `ReportPresenting` command): `$disk` returns its
/// table with the `VolumeSpace` it was made from.
public struct ActionReport: Sendable, Equatable {
    /// What is pasted or copied, and shown where no view is drawn.
    public var text: String
    /// What the view is drawn from.
    public var content: any Sendable

    public init(text: String, content: any Sendable) {
        self.text = text
        self.content = content
    }

    /// Equal when they read the same; the content is what the text was
    /// made from and cannot be compared.
    public static func == (lhs: ActionReport, rhs: ActionReport) -> Bool {
        lhs.text == rhs.text
    }
}

/// A question asked before an action does something that cannot be undone,
/// such as ending a process (`$port`). The palette previews it; running the
/// action shows it in an alert, and only a confirmation runs `perform`,
/// whose output is delivered like any other.
public struct ActionConfirmation: Sendable, Equatable {
    /// The alert's headline: "Kill node?".
    public var title: String
    /// What exactly is affected.
    public var message: String
    /// The confirming button: "Kill".
    public var confirmTitle: String
    /// The confirming button is marked destructive ("Kill"), not when it
    /// only adds something ("Save").
    public var isDestructive: Bool
    public var perform: @Sendable () async throws -> ActionOutput

    public init(
        title: String, message: String, confirmTitle: String, isDestructive: Bool = true,
        perform: @escaping @Sendable () async throws -> ActionOutput
    ) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.isDestructive = isDestructive
        self.perform = perform
    }

    /// Equal when they ask the same; `perform` cannot be compared.
    public static func == (lhs: ActionConfirmation, rhs: ActionConfirmation) -> Bool {
        lhs.title == rhs.title && lhs.message == rhs.message && lhs.confirmTitle == rhs.confirmTitle
            && lhs.isDestructive == rhs.isDestructive
    }
}

/// Where a running action reports to and writes to.
public struct ActionContext: Sendable {
    /// Overall progress from 0 to 1, or nil while it is unknown.
    public var progress: @Sendable (Double?) -> Void
    /// Where results go when the input has no folder of its own (text or an
    /// image from the clipboard): `~/Downloads` in the app.
    public var fallbackOutputDirectory: URL
    /// Scratch space for this run; the caller deletes it afterwards.
    public var temporaryDirectory: URL
    /// The values of the action's `options`.
    public var options: ActionOptionValues
    /// Where a command that `runsOnHosts` runs (`$mem @pi`), which
    /// `CommandAction` hands to `resolve`; this Mac for every other action.
    public var machine: Machine

    public init(
        progress: @escaping @Sendable (Double?) -> Void = { _ in },
        fallbackOutputDirectory: URL,
        temporaryDirectory: URL,
        options: ActionOptionValues = ActionOptionValues(),
        machine: Machine = .local
    ) {
        self.progress = progress
        self.fallbackOutputDirectory = fallbackOutputDirectory
        self.temporaryDirectory = temporaryDirectory
        self.options = options
        self.machine = machine
    }

    /// A context with a fresh temporary directory (created on disk).
    public static func make(
        fallbackOutputDirectory: URL,
        options: ActionOptionValues = ActionOptionValues(),
        machine: Machine = .local,
        progress: @escaping @Sendable (Double?) -> Void = { _ in }
    ) throws -> ActionContext {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "cortex-action-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporary, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return ActionContext(
            progress: progress, fallbackOutputDirectory: fallbackOutputDirectory, temporaryDirectory: temporary, options: options,
            machine: machine)
    }

    public func removeTemporaryDirectory() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

/// One entry of the `>` palette section. Its main input comes from context
/// (the clipboard, the Finder selection) or is handed in (a clip, a drop,
/// the selection); its options are its further arguments. A `Command` is
/// one whose input is typed after `$` instead: it resolves to an outcome,
/// and `CommandAction` runs that as a quick action.
public protocol QuickAction: Sendable {
    /// Stable across launches: usage counts are stored under it.
    var id: String { get }
    var title: String { get }
    /// SF Symbol name.
    var symbol: String { get }
    /// More words search finds it by ("heic", "jpeg", "gif").
    var keywords: [String] { get }
    /// Fast and side-effect free (text transformations): the palette shows
    /// the result before it is run. Everything else runs in the background
    /// and reports progress.
    var isInstant: Bool { get }
    /// Settings shown below the action in the palette; their values are in
    /// `ActionContext.options`.
    var options: [ActionOption] { get }
    /// Sends its input to an online service (the AI actions): never run on
    /// sensitive input, and never instant.
    var isRemote: Bool { get }
    /// Its results are secrets (a `$token` value): recorded as sensitive
    /// clips whatever the input.
    var hasSensitiveResult: Bool { get }

    /// Whether it takes this input.
    func accepts(_ input: ActionInput) -> Bool
    /// Whether `>` may offer it on this context input. Every action that
    /// accepts the input; a command only on input unmistakably meant for it
    /// (Kill Process on Port: a copied port number).
    func matches(_ input: ActionInput) -> Bool
    /// What ⏎ will do when it is not previewed: the shell command it runs.
    func plan(for input: ActionInput) -> String?
    func run(_ input: ActionInput, context: ActionContext) async throws -> ActionOutput
}

public extension QuickAction {
    var keywords: [String] { [] }
    var isInstant: Bool { false }
    var options: [ActionOption] { [] }
    var isRemote: Bool { false }
    var hasSensitiveResult: Bool { false }
    func matches(_ input: ActionInput) -> Bool { true }
    func plan(for input: ActionInput) -> String? { nil }
}

/// Errors with a message meant for the user.
public struct QuickActionError: Error, Equatable, CustomStringConvertible, LocalizedError {
    public var message: String
    /// Nothing went wrong; there is only nothing to do ("Nothing is listening
    /// on port 3000"). The pane shows it plainly instead of as an error, and
    /// run from `>` it is a notification, not a failure.
    public var isNotice = false

    public init(_ message: String) {
        self.message = message
    }

    /// `message` as a notice.
    public static func notice(_ message: String) -> QuickActionError {
        var error = QuickActionError(message)
        error.isNotice = true
        return error
    }

    public var description: String { message }
    public var errorDescription: String? { message }
}
