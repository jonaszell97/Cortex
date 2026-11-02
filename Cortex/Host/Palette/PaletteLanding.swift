import SwiftUI

/// What an empty query shows while no module is the default (Clipboard is
/// off or unavailable): the triggers, so the palette still leads somewhere.
struct PaletteLanding: View {
    let routes: [PaletteRoute]
    let open: (String) -> Void

    private var triggers: [(prefix: String, name: String)] {
        routes.compactMap { route in
            guard case .prefix(let prefix) = route.trigger, let name = route.placeholder else { return nil }
            return (prefix, name)
        }
    }

    var body: some View {
        if triggers.isEmpty {
            PaletteEmptyState(
                title: "Nothing to search", systemImage: "square.dashed",
                description: "Every module that uses the palette is switched off.")
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Type a trigger:")
                    .foregroundStyle(.secondary)
                ForEach(triggers, id: \.prefix) { trigger in
                    Button { open(trigger.prefix) } label: {
                        HStack(spacing: 10) {
                            Text(trigger.prefix)
                                .font(.body.monospaced().weight(.semibold))
                                .frame(minWidth: 28)
                            Text(trigger.name.prefix(1).uppercased() + trigger.name.dropFirst())
                        }
                    }
                    .buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
