import AppKit
import SwiftUI
import CortexCore

struct ActionRowView: View {
    let action: any QuickAction
    let shortcutNumber: Int?
    let isSelected: Bool

    var body: some View {
        PaletteRow(
            symbol: action.symbol,
            title: action.title,
            subtitle: Self.detail(for: action),
            shortcutNumber: shortcutNumber,
            isSelected: isSelected)
    }

    /// Its file, or that it runs in the background.
    static func detail(for action: any QuickAction) -> String? {
        if let user = action as? UserAction { return user.file.lastPathComponent }
        return action.isInstant ? nil : "Runs in the background"
    }
}

/// The right-hand pane in the `>` section: what the selected action works
/// on, and its result when it can be shown in advance.
struct ActionPreviewView: View {
    let input: ResolvedActionInput?
    let action: (any QuickAction)?
    let preview: ActionPreview?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let input {
                ActionInputHeader(resolved: input)
                Divider()
            }
            result
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var result: some View {
        if let preview, preview.actionID == action?.id {
            switch preview.result {
            case .success(let output):
                ActionOutputView(output: output, presenter: (action as? CommandAction)?.command as? any ReportPresenting)
            case .failure(let error):
                ActionErrorView(message: error.message)
            }
        } else if let action, !action.isInstant {
            // A command says what it does.
            let summary = (action as? CommandAction)?.command.summary ?? ""
            ContentUnavailableView(
                action.title,
                systemImage: action.symbol,
                description: Text(summary.isEmpty
                    ? "Runs in the background; a notification says when it is done. Files are written next to the originals, never over them."
                    : summary))
        } else {
            Color.clear
        }
    }
}

/// What an action or a command works on and where it came from: the first
/// lines of the right-hand pane.
struct ActionInputHeader: View {
    let resolved: ResolvedActionInput

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(resolved.source.label.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            switch resolved.input {
            case .files(let urls):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(urls.prefix(4), id: \.self) { url in
                        HStack(spacing: 6) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                                .resizable()
                                .frame(width: 16, height: 16)
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    if urls.count > 4 {
                        Text("and \(urls.count - 4) more")
                            .foregroundStyle(.secondary)
                    }
                }
            case .image(let data):
                HStack(spacing: 8) {
                    if let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 48, maxHeight: 32)
                    }
                    Text(resolved.input.summary)
                }
            case .text(let text):
                Text(PaletteRow.firstLine(of: text))
                    .lineLimit(2)
                Text(resolved.input.summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .none:
                Text(resolved.source == .typed ? "Nothing typed yet" : "Nothing on the clipboard")
                    .foregroundStyle(.secondary)
            }
            if let problem = resolved.problem {
                HStack(alignment: .firstTextBaseline) {
                    Label(problem, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Open Settings") { FinderSelection.openAutomationSettings() }
                        .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// An action's output as the pane shows it before ⏎: the text, the view of a
/// report, the question to be asked, what opens.
struct ActionOutputView: View {
    let output: ActionOutput
    /// Draws a `.report`'s content, when it is its own (`$mem`).
    var presenter: (any ReportPresenting)?

    var body: some View {
        switch output {
        case .text(let text):
            TextPreview(text: text)
        case .report(let report):
            if let view = presenter?.view(for: report) {
                view
            } else {
                TextPreview(text: report.text)
            }
        case .image(let data):
            if let image = NSImage(data: data) {
                Image(nsImage: image)
                    .interpolation(.none)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(16)
            }
        case .done(let message):
            Text(message)
                .font(.title3)
                .padding(16)
        case .snippet(let body):
            VStack(alignment: .leading, spacing: 0) {
                Label("Opens the snippet editor with this text", systemImage: "square.and.pencil")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top], 16)
                TextPreview(text: body)
            }
        case .saveCommand(let command):
            VStack(alignment: .leading, spacing: 0) {
                Label("⏎ asks for a name to type after $, then saves this as a command", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding([.horizontal, .top], 16)
                TextPreview(text: command)
            }
        case .confirm(let confirmation):
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text(confirmation.title)
                        .font(.title3.weight(.semibold))
                    Text(confirmation.message)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                    Label("⏎ asks before going ahead", systemImage: "questionmark.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
            }
        case .open(let url):
            VStack(alignment: .leading, spacing: 8) {
                Label("⏎ opens", systemImage: "arrow.up.forward.square")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.absoluteString)
                    .font(.body.monospaced())
                    .textSelection(.enabled)
            }
            .padding(16)
        case .reveal(let url):
            VStack(alignment: .leading, spacing: 8) {
                Label("⏎ shows it in Finder", systemImage: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 32, height: 32)
                    Text(url.path(percentEncoded: false))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        case .openWith(let url, let app):
            VStack(alignment: .leading, spacing: 8) {
                Label("⏎ opens it in \(app.deletingPathExtension().lastPathComponent)", systemImage: "terminal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.path(percentEncoded: false)))
                        .resizable()
                        .frame(width: 32, height: 32)
                    Text(url.path(percentEncoded: false))
                        .font(.body.monospaced())
                        .textSelection(.enabled)
                }
            }
            .padding(16)
        case .play(let url):
            VStack(alignment: .leading, spacing: 8) {
                Label("⏎ plays it", systemImage: "speaker.wave.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(.title3)
                Text(url.path(percentEncoded: false))
                    .font(.callout.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .padding(16)
        case .files, .handled:
            Color.clear
        }
    }
}

/// Why there is nothing to show.
struct ActionErrorView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "xmark.octagon")
            .foregroundStyle(.red)
            .padding(16)
    }
}

/// Why there is nothing to do: not an error, so it is not red.
struct ActionNoticeView: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "info.circle")
            .foregroundStyle(.secondary)
            .padding(16)
    }
}

/// The selected action's options, below its preview. Changes are
/// remembered at once and the preview follows. ⇥ moves from the search field
/// into the text fields; ⏎ still runs the action from there.
struct ActionOptionsView: View {
    let options: [ActionOption]
    let values: ActionOptionValues
    let onChange: (ActionOption, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPTIONS")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                ForEach(options) { option in
                    GridRow {
                        Text(option.title)
                            .foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                        ActionOptionControl(option: option, value: values[option]) { onChange(option, $0) }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
