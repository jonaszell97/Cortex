import SwiftUI

/// The palette: one search field, the active module's scope (or an overlay)
/// below it, key hints at the bottom.
struct PaletteView: View {
    static let size = CGSize(width: 820, height: 520)

    @Bindable var model: PaletteModel
    let settings: PaletteSettings
    @FocusState private var searchFocused: Bool

    private var style: PaletteStyle { settings.style }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            PaletteDivider(kind: .accent)
            if let overlay = model.overlay {
                overlay.body
            } else if let scope = model.activeScope {
                scope.body
            } else {
                PaletteLanding(routes: model.routes) { model.query = $0 }
            }
            PaletteDivider()
            KeyHintsBar(hints: model.hints)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .palettePane(style)
        .environment(\.paletteStyle, style)
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            return model.onDropFiles?(files) ?? false
        }
        .onAppear { searchFocused = true }
        .onChange(of: model.showCount) { searchFocused = true }
        .onChange(of: model.focusRequest) { searchFocused = true }
    }

    private var searchField: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.title2)
                .paletteSearchIcon(style)
                .allowsHitTesting(false)
            // The placeholder lists every trigger, so it is set smaller than
            // the query. The glass style's tint would wash out the system's
            // faint placeholder. A concrete colour: the text field cannot
            // take a hierarchical style like `.secondary` and shows it as
            // primary.
            TextField(model.placeholder, text: $model.query,
                      prompt: Text(model.placeholder).font(.body)
                          .foregroundStyle(style == .glass ? Color(nsColor: .secondaryLabelColor) : Color(nsColor: .placeholderTextColor)))
                .textFieldStyle(.plain)
                .font(.title2)
                .focused($searchFocused)
                .disabled(model.overlay != nil)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(WindowDragArea())
    }
}
