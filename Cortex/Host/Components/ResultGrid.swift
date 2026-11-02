import Foundation

/// A titled run of items in a palette grid; `id` is stable between reloads.
struct GridSection<Item: Equatable>: Identifiable, Equatable {
    let id: Int
    let title: String?
    let items: [Item]
}

extension GridSection: Sendable where Item: Sendable {}

/// Where an item sits in the grid. The same item can be in two sections
/// (frequently used and its category), so a position, not the item,
/// identifies a cell.
struct GridPosition: Hashable {
    var section: Int
    var index: Int
}

/// What a palette grid (emoji, symbols) shows and where the selection is,
/// with the arrow key movement. Kept free of UI so it can be tested.
struct ResultGrid<Item: Equatable> {
    private(set) var sections: [GridSection<Item>] = []
    private(set) var selection: GridPosition?
    /// Goes up each time the content is replaced with the selection moved
    /// back to the start, so the view can scroll back there even when the
    /// selection was already at the first item.
    private(set) var revision = 0
    let columns: Int

    init(columns: Int) {
        self.columns = columns
    }

    var isEmpty: Bool { sections.isEmpty }

    var selected: Item? {
        selection.flatMap(item(at:))
    }

    func item(at position: GridPosition) -> Item? {
        guard sections.indices.contains(position.section),
              sections[position.section].items.indices.contains(position.index)
        else { return nil }
        return sections[position.section].items[position.index]
    }

    /// The nth item counting from the top of the grid (⌘1 is 0).
    func item(atFlatIndex index: Int) -> Item? {
        position(atFlatIndex: index).flatMap(item(at:))
    }

    /// Replaces the content. The selection goes to the first item, or stays
    /// where it is if `keepingSelection` and it still points at an item.
    mutating func replace(with sections: [GridSection<Item>], keepingSelection: Bool = false) {
        self.sections = sections
        if keepingSelection, selected != nil { return }
        selection = sections.isEmpty ? nil : GridPosition(section: 0, index: 0)
        revision += 1
    }

    mutating func clear() {
        sections = []
        selection = nil
    }

    mutating func select(_ position: GridPosition?) {
        selection = position
    }

    /// ← and →: one item, continuing into the next or previous section.
    mutating func moveSideways(by delta: Int) {
        guard let current = selection, let flat = flatIndex(of: current) else { return }
        let count = sections.reduce(0) { $0 + $1.items.count }
        selection = position(atFlatIndex: min(max(flat + delta, 0), count - 1))
    }

    /// ↑ and ↓: one row, in the same column where the row has one; at the
    /// end of a section on to the first or last row of the next or previous.
    mutating func moveVertically(by delta: Int) {
        guard var position = selection, delta != 0 else { return }
        for _ in 0..<abs(delta) {
            let section = sections[position.section]
            let column = position.index % columns
            let row = position.index / columns
            let lastRow = (section.items.count - 1) / columns
            if delta > 0 {
                if row < lastRow {
                    position.index = min((row + 1) * columns + column, section.items.count - 1)
                } else if position.section + 1 < sections.count {
                    position = GridPosition(
                        section: position.section + 1,
                        index: min(column, sections[position.section + 1].items.count - 1))
                }
            } else {
                if row > 0 {
                    position.index = (row - 1) * columns + column
                } else if position.section > 0 {
                    let previous = sections[position.section - 1]
                    let previousLastRow = (previous.items.count - 1) / columns
                    position = GridPosition(
                        section: position.section - 1,
                        index: min(previousLastRow * columns + column, previous.items.count - 1))
                }
            }
        }
        selection = position
    }

    private func flatIndex(of position: GridPosition) -> Int? {
        guard sections.indices.contains(position.section) else { return nil }
        return sections[..<position.section].reduce(0) { $0 + $1.items.count } + position.index
    }

    private func position(atFlatIndex index: Int) -> GridPosition? {
        guard index >= 0 else { return nil }
        var remaining = index
        for (section, contents) in sections.enumerated() {
            if remaining < contents.items.count { return GridPosition(section: section, index: remaining) }
            remaining -= contents.items.count
        }
        return nil
    }
}
