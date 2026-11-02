import SwiftUI

/// A palette list (clips, snippets, actions): rows drawn by the caller, the
/// selection kept in view, click to select, double click to activate. The
/// first nine rows get their ⌘1–9 number. Empty, it shows `empty` once the
/// results are in.
struct PaletteList<Item, ID: Hashable, Row: View>: View {
    let list: ResultList<Item, ID>
    let empty: PaletteEmptyState
    let onActivate: (Item) -> Void
    @ViewBuilder let row: (_ item: Item, _ shortcutNumber: Int?, _ isSelected: Bool) -> Row

    var body: some View {
        if list.isEmpty {
            if list.hasLoaded {
                empty
            } else {
                Color.clear
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(entries, id: \.id) { entry in
                            row(entry.item, entry.index < 9 ? entry.index + 1 : nil, entry.id == list.selectedID)
                                .id(entry.id)
                                .contentShape(Rectangle())
                                .onClick { list.select(entry.id) } doubleClick: { onActivate(entry.item) }
                        }
                    }
                    .padding(8)
                }
                .onChange(of: list.selectedID) { _, id in
                    guard let id else { return }
                    proxy.scrollTo(id)
                }
            }
        }
    }

    private struct Entry {
        let index: Int
        let id: ID
        let item: Item
    }

    private var entries: [Entry] {
        list.items.enumerated().map { Entry(index: $0.offset, id: list.id(of: $0.element), item: $0.element) }
    }
}

extension View {
    /// A list row's or grid cell's clicks. A plain tap gesture after a
    /// double-tap one fires only once the double-click interval has passed,
    /// which made selecting by click lag. Here the first click selects at
    /// once, like in Finder, and a double click (which selects first) also
    /// activates.
    func onClick(_ click: @escaping () -> Void, doubleClick: @escaping () -> Void) -> some View {
        onTapGesture(perform: click)
            .simultaneousGesture(TapGesture(count: 2).onEnded(doubleClick))
    }
}
