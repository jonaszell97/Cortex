import SwiftUI
import CortexCore

/// The Commands page below its switch: every command as a cheat sheet, with
/// how it is typed and where it is from. Problems of the user's files are on
/// the Quick Actions page, which owns the folder.
struct CommandsSettingsView: View {
    let listing: @MainActor () -> [(command: any Command, source: String)]

    var body: some View {
        Section("Commands") {
            ForEach(listing(), id: \.command.id) { entry in
                LabeledContent {
                    Text(entry.source)
                        .foregroundStyle(.secondary)
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CommandsModule.prefix + entry.command.usage)
                                .font(.body.monospaced())
                            Text(entry.command.title)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: entry.command.symbol)
                    }
                }
            }
            Text("Your own: a file in the Quick Actions folder with a trigger, such as trigger = \"gh\" for \(CommandsModule.prefix)gh. See the README.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
