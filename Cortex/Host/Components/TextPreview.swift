import SwiftUI

/// Text in a preview card: monospaced, selectable and scrollable, cut to
/// the first screens of very long text.
struct TextPreview: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(Self.previewText(text))
                .font(.body.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
        }
    }

    /// Very long text makes SwiftUI layout slow; the preview does not need
    /// more than the first screens of it.
    static let previewLimit = 20_000

    static func previewText(_ text: String) -> String {
        text.count > previewLimit ? String(text.prefix(previewLimit)) + "\n…" : text
    }
}
