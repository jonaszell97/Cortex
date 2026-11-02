import SwiftUI
import CortexCore

/// A `$` command's form over the list (docs/modules/COMMANDS.md, "The form"):
/// what the command does, its argument with the suggestions under it, the
/// host it runs on, its options, and what ⏎ would do.
struct CommandFormView: View {
    let form: CommandForm
    @FocusState private var focused: CommandForm.Field?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                header
                fields
                if let problem = form.problem {
                    Label(problem, systemImage: "xmark.octagon")
                        .foregroundStyle(.red)
                } else if form.isMarked, let argument = form.argument {
                    Label("Fill in the \(argument.title.lowercased()) first", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.red)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
            Divider()
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { focused = Self.textual(form.focus, in: form) }
        .onChange(of: form.focus) { focused = Self.textual(form.focus, in: form) }
        .onChange(of: focused) {
            // A click into a field; leaving a choice option's focus alone.
            if let focused { form.focus = focused }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(form.command.title, systemImage: form.command.symbol)
                .font(.title3.weight(.semibold))
            if !form.command.summary.isEmpty {
                Text(form.command.summary)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var fields: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 10) {
            if let argument = form.argument {
                GridRow {
                    Text(argument.title)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    SuggestingTextField(
                        title: argument.title,
                        text: Binding(get: { form.text }, set: { form.text = $0 }),
                        prompt: argument.placeholder,
                        isMultiline: argument.kind == .prompt,
                        isMarked: form.isMarked,
                        suggestions: form.shownSuggestions.map(Self.row),
                        highlighted: form.field.highlighted,
                        focus: $focused,
                        field: .argument,
                        onPick: { form.pick($0) })
                    .font(argument.kind == .prompt ? .body : .body.monospaced())
                    Text(argument.isRequired ? "required" : "optional")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if form.command.runsOnHosts {
                GridRow {
                    Text("Host")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    HStack(spacing: 12) {
                        ActionOptionControl(option: form.hostOption, value: form.hostValue) { form.setHost($0) }
                            .focused($focused, equals: .host)
                            .padding(2)
                            .overlay {
                                // Moved with ←→ while it has the keyboard,
                                // like a choice option.
                                if form.focus == .host {
                                    RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
                                }
                            }
                        if form.hosts.isEmpty {
                            Text("none in ~/.ssh/config")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .gridCellColumns(2)
                }
            }
            ForEach(form.command.options) { option in
                GridRow {
                    Text(option.title)
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    ActionOptionControl(option: option, value: form.options[option]) { form.setOption(option, to: $0) }
                        .focused($focused, equals: .option(option.id))
                        .padding(2)
                        .overlay {
                            // A choice is moved with ←→ while it has the
                            // keyboard; it never takes focus itself.
                            if form.focus == .option(option.id), case .choice = option.kind {
                                RoundedRectangle(cornerRadius: 7).strokeBorder(Color.accentColor, lineWidth: 2)
                            }
                        }
                        .gridCellColumns(2)
                }
            }
        }
    }

    @ViewBuilder
    private var preview: some View {
        if case .success(let input) = form.value, form.command.accepts(input) {
            // The fields show what was typed, so there is no header.
            form.actions.commandPane(
                for: form.command, typed: nil, resolution: form.currentResolution ?? form.resolution,
                loading: form.isLoadingPreview && form.currentResolution == nil ? form.machine.describing(form.command.title) : nil,
                refreshProblem: form.refresh.problem)
        } else {
            Color.clear
        }
    }

    /// The field focus goes to; nil for the host and a choice option, which
    /// ←→ change.
    private static func textual(_ field: CommandForm.Field?, in form: CommandForm) -> CommandForm.Field? {
        if field == .host { return nil }
        guard case .option(let id) = field else { return field }
        guard let option = form.command.options.first(where: { $0.id == id }) else { return nil }
        if case .choice = option.kind { return nil }
        return field
    }

    private static func row(_ suggestion: CommandSuggestion) -> SuggestingTextField<CommandForm.Field>.Suggestion {
        let detail: String? = switch suggestion.source {
        case .clipboard:
            suggestion.value.count > 80 ? "Clipboard · \(suggestion.value.count.formatted()) characters" : "Clipboard"
        case .history(let date):
            "History · " + date.formatted(.relative(presentation: .named))
        case .choice:
            nil
        }
        return .init(id: suggestion.id, title: PaletteRow.firstLine(of: suggestion.value), detail: detail)
    }
}
