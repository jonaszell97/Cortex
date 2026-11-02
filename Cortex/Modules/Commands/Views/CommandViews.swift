import SwiftUI
import CortexCore

/// A command in the `$` list: how it is typed (`$port 3000`), its title
/// below. The argument typed after its name replaces the example
/// (`$code mathical`, not `$code cortex`); the example is dimmed. A typed
/// `@host` follows it (`$disk /mnt/usb @pi`).
struct CommandRowView: View {
    let command: any Command
    /// What was typed after this command's name, when the query names it.
    var typedArgument: String?
    /// The `@host` words typed after it, without the `@`.
    var typedHosts: [String] = []
    let shortcutNumber: Int?
    let isSelected: Bool

    var body: some View {
        let title = Self.title(for: command, typedArgument: typedArgument, typedHosts: typedHosts)
        PaletteRow(
            symbol: command.symbol,
            title: title.text,
            subtitle: command.title,
            shortcutNumber: shortcutNumber,
            isSelected: isSelected,
            isTitleMonospaced: true,
            titleHint: title.hint)
    }

    /// `$code mathical` once something is typed for it; otherwise `$code`
    /// with the example `cortex` as the hint. A typed host is kept
    /// as typed: `$disk /mnt/usb @pi`, and `$mem @pi` without a
    /// hint for an argument.
    static func title(for command: any Command, typedArgument: String?, typedHosts: [String] = []) -> (text: String, hint: String?) {
        var name = CommandsModule.prefix + command.name
        var isTyped = !typedHosts.isEmpty
        if let typedArgument, !typedArgument.isEmpty, command.argument != nil {
            name += " " + typedArgument
            isTyped = true
        }
        name += typedHosts.map { " @" + $0 }.joined()
        let placeholder = command.argument?.placeholder ?? ""
        return (name, isTyped || placeholder.isEmpty ? nil : placeholder)
    }
}

/// The pane for a command that still needs its argument: what it does,
/// what it takes, and that ⏎ opens its form.
struct CommandPane: View {
    let command: any Command

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(command.title, systemImage: command.symbol)
                .font(.title3.weight(.semibold))
            if !command.summary.isEmpty {
                Text(command.summary)
                    .foregroundStyle(.secondary)
            }
            if let argument = command.argument {
                Text(Self.takes(argument))
            }
            Label("⏎ fills it in", systemImage: "return")
                .foregroundStyle(.secondary)
            Text("or type \(CommandsModule.prefix)\(command.usage)")
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// "Port: a number from 1 to 65535, required".
    static func takes(_ argument: CommandArgument) -> String {
        let what = switch argument.kind {
        case .text: "text"
        case .prompt: "text, as long as you like"
        case .number(let range): "a number from \(range.lowerBound) to \(range.upperBound)"
        case .path: "a file or folder"
        case .choice(let choices): choices.allowsPaths ? "one of a list, or a file or folder" : "one of a list"
        }
        return "\(argument.title): \(what), \(argument.isRequired ? "required" : "optional")"
    }
}
