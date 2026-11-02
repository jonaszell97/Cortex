import AppKit
import KeyboardShortcuts

/// The modules' part of the status menu: one group per module, each after a
/// separator, right after `anchor`. Updated in place where the shape allows,
/// so the item under the mouse stays highlighted while a running job reports
/// its progress.
@MainActor
final class StatusMenuSection {
    private let menu: NSMenu
    private let anchor: NSMenuItem
    /// In menu order, right after `anchor`.
    private(set) var items: [NSMenuItem] = []

    init(in menu: NSMenu, after anchor: NSMenuItem) {
        self.menu = menu
        self.anchor = anchor
    }

    func update(_ groups: [[StatusMenuItem]]) {
        // nil is a separator.
        let rows: [StatusMenuItem?] = groups.filter { !$0.isEmpty }.flatMap { [nil] + $0 }
        guard let anchorIndex = menu.items.firstIndex(of: anchor) else { return }
        for (offset, row) in rows.enumerated() {
            if offset < items.count, Self.update(items[offset], to: row) { continue }
            let item: NSMenuItem = row.map(ModuleMenuItem.init) ?? .separator()
            if offset < items.count {
                menu.removeItem(items[offset])
                items[offset] = item
            } else {
                items.append(item)
            }
            menu.insertItem(item, at: anchorIndex + 1 + offset)
        }
        for item in items.dropFirst(rows.count) { menu.removeItem(item) }
        items.removeLast(max(0, items.count - rows.count))
    }

    /// False when the menu item is of the other kind (separator or not).
    private static func update(_ item: NSMenuItem, to row: StatusMenuItem?) -> Bool {
        switch (item as? ModuleMenuItem, row) {
        case (nil, nil):
            return true
        case (let item?, let row?):
            item.show(row)
            return true
        default:
            return false
        }
    }
}

/// A module's status menu item, running its closure when chosen.
@MainActor
final class ModuleMenuItem: NSMenuItem {
    private var handler: (@MainActor () -> Void)?
    private var symbol: String?
    private var shortcutName: KeyboardShortcuts.Name?

    init(_ item: StatusMenuItem) {
        super.init(title: item.title, action: nil, keyEquivalent: "")
        target = self
        show(item)
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func show(_ item: StatusMenuItem) {
        title = item.title
        state = item.state
        handler = item.action
        action = item.action == nil ? nil : #selector(choose)
        isEnabled = item.isEnabled && item.action != nil
        toolTip = item.toolTip
        if item.image != symbol {
            symbol = item.image
            image = item.image.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }
        }
        if item.shortcut != shortcutName {
            shortcutName = item.shortcut
            setShortcut(for: item.shortcut)
        }
    }

    @objc private func choose() {
        handler?()
    }
}
