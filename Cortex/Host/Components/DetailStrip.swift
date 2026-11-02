import SwiftUI

/// Below a grid: the selected item large, its title and a caption, and on
/// the right an accessory (the skin tone ⇥ cycles). Without a title nothing
/// is selected and only the accessory shows.
struct DetailStrip<Glyph: View, Accessory: View>: View {
    let title: String?
    var caption = ""
    var titleFont: Font = .headline
    @ViewBuilder let glyph: () -> Glyph
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(spacing: 14) {
            if let title {
                glyph()
                    .frame(width: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(titleFont)
                        .lineLimit(1)
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            accessory()
        }
        .padding(.horizontal, 16)
        .frame(height: 60)
    }
}

extension DetailStrip where Accessory == EmptyView {
    init(title: String?, caption: String = "", titleFont: Font = .headline, @ViewBuilder glyph: @escaping () -> Glyph) {
        self.init(title: title, caption: caption, titleFont: titleFont, glyph: glyph, accessory: { EmptyView() })
    }
}
