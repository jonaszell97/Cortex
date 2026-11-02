import SwiftUI

/// A grid in titled sections (emoji, symbols), with a selection that stays
/// in view. The cells are drawn by the caller.
struct PaletteGrid<Item: Equatable, Cell: View>: View {
    let grid: ResultGrid<Item>
    let hasLoaded: Bool
    let empty: PaletteEmptyState
    let onSelect: (GridPosition) -> Void
    let onActivate: (Item) -> Void
    @ViewBuilder let cell: (Item) -> Cell

    private static var cellSize: CGSize { CGSize(width: 50, height: 44) }
    private var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(Self.cellSize.width), spacing: 4), count: grid.columns)
    }

    var body: some View {
        if grid.isEmpty {
            if hasLoaded {
                empty
            } else {
                Color.clear
            }
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 2) {
                        ForEach(Array(grid.sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            Section {
                                // A range, not the items: re-diffing thousands of
                                // symbols on every arrow key would lag.
                                ForEach(section.items.indices, id: \.self) { index in
                                    let item = section.items[index]
                                    let position = GridPosition(section: sectionIndex, index: index)
                                    cell(item)
                                        .frame(width: Self.cellSize.width, height: Self.cellSize.height)
                                        .paletteSelection(position == grid.selection)
                                        .contentShape(Rectangle())
                                        .id(Self.cellID(position))
                                        .onClick { onSelect(position) } doubleClick: { onActivate(item) }
                                }
                            } header: {
                                if let title = section.title {
                                    Text(title)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.leading, 4)
                                        .padding(.top, sectionIndex == 0 ? 0 : 10)
                                        .id(Self.headerID(sectionIndex))
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .onChange(of: grid.selection) { scrollToSelection(proxy) }
                // New results: back to the top, even if the selection did not change.
                .onChange(of: grid.revision) { scrollToSelection(proxy, anchor: .top) }
            }
        }
    }

    private func scrollToSelection(_ proxy: ScrollViewProxy, anchor: UnitPoint? = nil) {
        guard let position = grid.selection else { return }
        // On the first row, bring the section's title into view too.
        let hasTitle = grid.sections.indices.contains(position.section)
            && grid.sections[position.section].title != nil
        if position.index < grid.columns, hasTitle {
            proxy.scrollTo(Self.headerID(position.section), anchor: anchor)
        } else {
            proxy.scrollTo(Self.cellID(position), anchor: anchor)
        }
    }

    private static func headerID(_ section: Int) -> String { "header-\(section)" }
    private static func cellID(_ position: GridPosition) -> String { "cell-\(position.section)-\(position.index)" }
}
