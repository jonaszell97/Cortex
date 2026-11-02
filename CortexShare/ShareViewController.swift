import SwiftUI
import UIKit
import UniformTypeIdentifiers
import CortexCore

/// The share sheet's Cortex (plans/IOS.md, M5): a web link goes to the
/// reading list, text and pictures into the inbox as a note. It writes into
/// the App Group container only, the link into the reading list's outbox,
/// never the database; the app adds, indexes and syncs it when it runs.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(items: extensionContext?.inputItems as? [NSExtensionItem] ?? []) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        } cancel: { [weak self] in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        }
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.load() }
    }
}

/// What was shared, and saving it.
@MainActor
@Observable
final class ShareModel {
    enum Content {
        case loading
        case link(URL)
        case note
        case nothing
    }

    var content = Content.loading
    var title = ""
    var text = ""
    var pictures: [KnowledgeCapture.Picture] = []
    var previews: [UIImage] = []
    var error: String?
    var isSaving = false
    var saved: String?

    private let items: [NSExtensionItem]
    private let done: () -> Void
    let cancel: () -> Void
    private let log = Log.logger("share")

    init(items: [NSExtensionItem], done: @escaping () -> Void, cancel: @escaping () -> Void) {
        self.items = items
        self.done = done
        self.cancel = cancel
    }

    /// A web link wins (Safari shares the page with its title); then text
    /// and pictures, which make a note.
    func load() async {
        let providers = items.flatMap { $0.attachments ?? [] }
        // Safari puts the page title here.
        let sharedTitle = items.lazy.compactMap { ($0.attributedContentText ?? $0.attributedTitle)?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }

        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await provider.loadURL(), !url.isFileURL, ReadingItem.normalizedURL(url.absoluteString) != nil {
                title = sharedTitle.flatMap { $0 == url.absoluteString ? nil : $0 } ?? ""
                content = .link(url)
                return
            }
        }
        var texts: [String] = []
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                if let picture = await provider.loadPicture() {
                    pictures.append(picture.picture)
                    previews.append(picture.preview)
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier), let text = await provider.loadText() {
                texts.append(text)
            }
        }
        // Safari's selection: its provider may not load, the item has it.
        if texts.isEmpty, pictures.isEmpty, let sharedTitle { texts.append(sharedTitle) }
        let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        // A link shared as text (a Messages bubble, Notes) is still a link.
        if pictures.isEmpty, !text.contains("\n"), ReadingItem.isPastedLink(text), let url = URL(string: text) {
            title = sharedTitle ?? ""
            content = .link(url)
            return
        }
        guard !text.isEmpty || !pictures.isEmpty else {
            content = .nothing
            return
        }
        self.text = text
        title = KnowledgeCapture.title(forText: text)
        content = .note
    }

    func save() {
        guard !isSaving else { return }
        isSaving = true
        do {
            let directory = try SharedContainer.dataDirectory()
            switch content {
            case .link(let url):
                try SharedContainer.readingListOutbox(in: directory).add(url: url.absoluteString, title: title)
                saved = "Added to the reading list"
            case .note:
                let folder = SharedContainer.knowledgeFolder(in: directory)
                try folder.prepare()
                // The title made from the text, untouched: Core makes it again,
                // and leaves a single line out of the body.
                let title = title == KnowledgeCapture.title(forText: text) ? "" : title
                try KnowledgeCapture.createNote(in: folder, title: title, text: text, pictures: pictures)
                saved = "Saved to the inbox"
            case .loading, .nothing:
                return
            }
            log.info("Saved a shared item")
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                done()
            }
        } catch {
            log.error("Cannot save the shared item: \(error, privacy: .public)")
            self.error = error.localizedDescription
            isSaving = false
        }
    }
}

/// On the main actor, with the model: an item provider is not Sendable.
@MainActor
private extension NSItemProvider {
    func loadURL() async -> URL? {
        await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }

    /// As a string object, else whatever the item is (Safari's selection
    /// doesn't load as a string object).
    func loadText() async -> String? {
        let text: String? = await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: String.self) { text, _ in continuation.resume(returning: text) }
        }
        if let text { return text }
        return await withCheckedContinuation { continuation in
            loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                let text = switch item {
                case let text as String: text
                case let data as Data: String(data: data, encoding: .utf8)
                case let attributed as NSAttributedString: attributed.string
                default: nil as String?
                }
                continuation.resume(returning: text)
            }
        }
    }

    /// The picture's own bytes when it is a file (a photo keeps its HEIC
    /// or JPEG), else a PNG of the image (a screenshot's markup).
    func loadPicture() async -> (picture: KnowledgeCapture.Picture, preview: UIImage)? {
        let type = registeredContentTypes.first { $0.conforms(to: .image) } ?? .image
        let data: Data? = await withCheckedContinuation { continuation in
            _ = loadDataRepresentation(for: type) { data, _ in continuation.resume(returning: data) }
        }
        if let data, let image = UIImage(data: data) {
            return (KnowledgeCapture.Picture(data: data, fileExtension: type.preferredFilenameExtension ?? "jpeg"), image)
        }
        let image: UIImage? = await withCheckedContinuation { continuation in
            _ = loadObject(ofClass: UIImage.self) { image, _ in continuation.resume(returning: image as? UIImage) }
        }
        guard let image, let png = image.pngData() else { return nil }
        return (KnowledgeCapture.Picture(data: png, fileExtension: "png"), image)
    }
}
