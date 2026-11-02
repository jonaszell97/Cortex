import SwiftUI

/// The settings window: General and the pages active modules add
/// (`settingsPanes`), then one page per module in manifest order.
struct SettingsView: View {
    enum Page: Hashable {
        case general
        case pane(ModuleID, String)
        case module(ModuleID)
    }

    let host: ModuleHost
    let general: GeneralSettingsView
    @State private var selection = Page.general

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { selection }, set: { if let page = $0 { selection = page } })) {
                Label("General", systemImage: "gearshape")
                    .tag(Page.general)
                ForEach(panes, id: \.page) { pane in
                    Label(pane.pane.title, systemImage: pane.pane.symbol)
                        .tag(pane.page)
                }
                Section("Modules") {
                    ForEach(host.manifests.sorted { $0.order < $1.order }, id: \.id) { manifest in
                        Label(manifest.name, systemImage: manifest.symbol)
                            .foregroundStyle(host.isActive(manifest.id) ? .primary : .secondary)
                            .tag(Page.module(manifest.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 320)
        } detail: {
            switch selection {
            case .general:
                general
            case .pane:
                if let pane = panes.first(where: { $0.page == selection }) {
                    pane.pane.view
                        .id(selection)
                } else {
                    general
                }
            case .module(let id):
                if let module = host.modules.first(where: { ModuleHost.manifest(of: $0).id == id }) {
                    ModuleSettingsPage(module: module, host: host)
                        .id(id)
                }
            }
        }
        // On the split view, not the sidebar: removing the toggle from the
        // sidebar makes SwiftUI ignore its column width.
        .toolbar(removing: .sidebarToggle)
        .frame(minWidth: 760, minHeight: 480)
    }

    /// The active modules' panes, in manifest order.
    private var panes: [(page: Page, pane: SettingsPane)] {
        host.modules
            .map { (manifest: ModuleHost.manifest(of: $0), module: $0) }
            .filter { host.isActive($0.manifest.id) }
            .sorted { $0.manifest.order < $1.manifest.order }
            .flatMap { entry in entry.module.settingsPanes.map { (Page.pane(entry.manifest.id, $0.id), $0) } }
    }
}
