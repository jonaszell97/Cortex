import SafariServices
import SwiftUI
import UniformTypeIdentifiers
import CortexCore

/// The reading list: unread or read links, search over all of them, adding
/// one by pasting or typing. Tapping a link opens it and marks it read.
struct ReadingListView: View {
    @Environment(ReadingListModel.self) private var readingList
    @Environment(MobileSyncService.self) private var sync
    @Environment(\.openURL) private var openURL
    @State private var filter = Filter.unread
    @State private var query = ""
    @State private var newLink = ""
    @State private var editing: ReadingItem?
    @State private var safariPage: SafariPage?
    @State private var errorMessage: String?

    enum Filter: String, CaseIterable {
        case unread = "Unread"
        case read = "Read"
    }

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Searching looks at every link, read or not.
    private var shown: [ReadingItem] {
        let ranked = ReadingListSearch.rank(readingList.items, query: query)
        if isSearching { return ranked }
        return ranked.filter { $0.isRead == (filter == .read) }
    }

    var body: some View {
        List {
            if !isSearching {
                Section {
                    Picker("Show", selection: $filter) {
                        ForEach(Filter.allCases, id: \.self) { Text($0.rawValue) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
            }
            Section {
                if !isSearching, filter == .unread { addRow }
                ForEach(shown) { item in
                    Button { open(item) } label: { ReadingItemRow(item: item, showsReadState: isSearching) }
                        .foregroundStyle(.primary)
                        .swipeActions(edge: .leading) { readButton(item).tint(.blue) }
                        .swipeActions(edge: .trailing) { deleteButton(item) }
                        .contextMenu { menu(for: item) }
                }
            } footer: {
                if !isSearching { Text(sync.footerLine ?? "") }
            }
        }
        .navigationTitle("Reading List")
        .searchable(text: $query, prompt: "Titles, sites, links, notes")
        .refreshable { await sync.syncNow() }
        .overlay { emptyState }
        .sheet(item: $editing) { ReadingItemEditor(item: $0) }
        .fullScreenCover(item: $safariPage) { page in
            SafariView(url: page.url) { safariPage = nil }
                .ignoresSafeArea()
        }
        .alert("Can't do that", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") {}
        } message: {
            Text(errorMessage ?? "")
        }
    }

    // MARK: - Adding

    private var addRow: some View {
        HStack {
            TextField("Add a link", text: $newLink)
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { add(newLink, clearing: true) }
            // No paste prompt: the system button is the permission.
            PasteButton(supportedContentTypes: [.url, .plainText]) { providers in
                Task { await paste(providers) }
            }
            .labelStyle(.iconOnly)
            .buttonBorderShape(.capsule)
        }
    }

    private func add(_ text: String, clearing: Bool = false) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        Task {
            do {
                try await readingList.add(text)
                if clearing { newLink = "" }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// A copied link (Safari puts one on the pasteboard as a URL), or text
    /// that is one.
    private func paste(_ providers: [NSItemProvider]) async {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await provider.load(URL.self), !url.isFileURL {
                return add(url.absoluteString)
            }
            if let text = await provider.load(String.self) {
                guard ReadingItem.isPastedLink(text) else {
                    errorMessage = "The clipboard has no web link."
                    return
                }
                return add(text)
            }
        }
        errorMessage = "The clipboard has no web link."
    }

    // MARK: - Actions

    private func open(_ item: ReadingItem) {
        guard let url = URL(string: item.url), let id = item.id else { return }
        switch readingList.settings.openLinks {
        case .browser: openURL(url)
        case .inApp: safariPage = SafariPage(url: url)
        }
        Task { await readingList.setRead(true, id: id) }
    }

    private func readButton(_ item: ReadingItem) -> some View {
        Button {
            guard let id = item.id else { return }
            Task { await readingList.setRead(!item.isRead, id: id) }
        } label: {
            item.isRead
                ? Label("Mark Unread", systemImage: "circle")
                : Label("Mark Read", systemImage: "checkmark.circle")
        }
    }

    private func deleteButton(_ item: ReadingItem) -> some View {
        Button(role: .destructive) {
            guard let id = item.id else { return }
            Task { await readingList.delete(id: id) }
        } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func menu(for item: ReadingItem) -> some View {
        Button { open(item) } label: { Label("Open", systemImage: "safari") }
        if ReadingListModel.canAddToSafari(item) {
            Button {
                Task {
                    do {
                        try await readingList.addToSafari(item)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Add to Safari's Reading List", systemImage: "eyeglasses")
            }
        }
        readButton(item)
        Button { editing = item } label: { Label("Edit", systemImage: "pencil") }
        if let url = URL(string: item.url) {
            ShareLink(item: url, subject: Text(item.displayTitle)) { Label("Share", systemImage: "square.and.arrow.up") }
            Button { UIPasteboard.general.url = url } label: { Label("Copy Link", systemImage: "link") }
        }
        Divider()
        deleteButton(item)
    }

    @ViewBuilder
    private var emptyState: some View {
        if isSearching, shown.isEmpty {
            ContentUnavailableView.search(text: query)
        } else if !isSearching, shown.isEmpty {
            switch filter {
            case .unread:
                ContentUnavailableView(
                    "Nothing to read", systemImage: "books.vertical",
                    description: Text("Paste a link above, or save one on your Mac."))
            case .read:
                ContentUnavailableView("No read links", systemImage: "checkmark.circle")
            }
        }
    }
}

/// A link: title, then site and age (and its note when there is one).
struct ReadingItemRow: View {
    let item: ReadingItem
    /// Search results mix read and unread links.
    var showsReadState = false

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            if showsReadState {
                Image(systemName: item.isRead ? "checkmark.circle" : "circle")
                    .foregroundStyle(.secondary)
                    .imageScale(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .lineLimit(2)
                Text("\(item.host) · \(age)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .opacity(showsReadState && item.isRead ? 0.6 : 1)
    }

    /// When it was added, or for a read link when it was read.
    private var age: String {
        item.readAt.map { "read \(ReadingDates.relative($0))" } ?? ReadingDates.relative(item.addedAt)
    }
}

/// Edits a link's title and note.
struct ReadingItemEditor: View {
    let item: ReadingItem
    @Environment(ReadingListModel.self) private var readingList
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var note: String

    init(item: ReadingItem) {
        self.item = item
        _title = State(initialValue: item.title ?? "")
        _note = State(initialValue: item.note ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, prompt: Text(item.untitledName), axis: .vertical)
                    TextField("Note", text: $note, prompt: Text("Why you saved it"), axis: .vertical)
                        .lineLimit(3...)
                } footer: {
                    Text(item.url)
                        .textSelection(.enabled)
                }
            }
            .navigationTitle("Edit Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        guard let id = item.id else { return dismiss() }
                        Task {
                            await readingList.edit(id: id, title: title, note: note)
                            dismiss()
                        }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// A page to show in the in-app browser.
struct SafariPage: Identifiable {
    let url: URL
    var id: URL { url }
}

/// `SFSafariViewController`, in Reader when the page has one. Its Done
/// button dismisses it on its own, so `onDone` resets the presentation.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    let onDone: () -> Void

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = true
        let controller = SFSafariViewController(url: url, configuration: configuration)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    final class Coordinator: NSObject, SFSafariViewControllerDelegate {
        let onDone: () -> Void

        init(onDone: @escaping () -> Void) {
            self.onDone = onDone
        }

        func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
            onDone()
        }
    }
}

@MainActor
enum ReadingDates {
    private static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func relative(_ date: Date, now: Date = .now) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

extension NSItemProvider {
    /// The item as `T`, or nil if it isn't one.
    @MainActor
    func load<T: Transferable & Sendable>(_ type: T.Type) async -> T? {
        await withCheckedContinuation { continuation in
            _ = loadTransferable(type: type) { continuation.resume(returning: try? $0.get()) }
        }
    }
}
