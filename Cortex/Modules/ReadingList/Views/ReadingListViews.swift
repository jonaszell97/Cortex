import SwiftUI
import CortexCore

/// The `+` scope: the links and the selected one's details.
struct ReadingListView: View {
    let scope: ReadingListScope

    var body: some View {
        PaletteSplitLayout {
            PaletteList(
                list: scope.list,
                empty: PaletteEmptyState(
                    title: scope.query.isEmpty ? "Nothing to read" : "No matching links",
                    systemImage: "books.vertical",
                    description: scope.query.isEmpty
                        ? "Paste a link here, or press ⌘N to add the one on the clipboard."
                        : "Search looks at titles, websites, links and notes."),
                onActivate: { scope.choose($0) }
            ) { entry, shortcutNumber, isSelected in
                ReadingListRowView(entry: entry, shortcutNumber: shortcutNumber, isSelected: isSelected)
            }
        } preview: {
            switch scope.list.selected {
            case .add(let url): ReadingAddPreviewView(url: url)
            case .item(let item): ReadingItemPreviewView(item: item)
            case nil: Color.clear
            }
        }
    }
}

struct ReadingListRowView: View {
    let entry: ReadingListEntry
    let shortcutNumber: Int?
    let isSelected: Bool

    var body: some View {
        switch entry {
        case .add(let url):
            PaletteRow(
                symbol: "plus.circle", title: "Add to Reading List", subtitle: url,
                shortcutNumber: shortcutNumber, isSelected: isSelected)
        case .item(let item):
            PaletteRow(
                symbol: item.isRead ? "checkmark.circle" : "doc.text",
                title: item.displayTitle,
                subtitle: "\(item.host) · \(ReadingDates.relative(item.addedAt))",
                shortcutNumber: shortcutNumber,
                isSelected: isSelected)
            .opacity(item.isRead && !isSelected ? 0.6 : 1)
        }
    }
}

/// A typed link, before it is added.
struct ReadingAddPreviewView: View {
    let url: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add to Reading List").font(.title3.bold())
            Text(url)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The selected link: title, link, note and dates.
struct ReadingItemPreviewView: View {
    let item: ReadingItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.displayTitle)
                    .font(.title3.bold())
                    .lineLimit(3)
                Text(item.url)
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)

            if let note = item.note {
                Divider()
                TextPreview(text: note)
            }
            Spacer(minLength: 0)
            Divider()
            footer
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let source = item.sourceAppName {
                Text("Added \(ReadingDates.relative(item.addedAt)) from \(source)")
            } else {
                Text("Added \(ReadingDates.relative(item.addedAt))")
            }
            if let readAt = item.readAt {
                Text("Read \(ReadingDates.relative(readAt))")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Edits a link's title and note.
struct ReadingItemFormView: View {
    let form: ReadingItemForm
    @FocusState private var focused: Field?

    private enum Field { case title, note }

    var body: some View {
        @Bindable var form = form
        VStack(alignment: .leading, spacing: 16) {
            Label(form.item.host, systemImage: "books.vertical")
                .font(.title3.bold())
            Form {
                TextField("Title", text: $form.title, prompt: Text(form.item.untitledName))
                    .focused($focused, equals: .title)
                TextField("Note", text: $form.note, prompt: Text("Why you saved it"))
                    .focused($focused, equals: .note)
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = .title }
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
