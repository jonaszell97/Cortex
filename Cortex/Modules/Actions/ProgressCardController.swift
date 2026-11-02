import AppKit
import SwiftUI
import CortexCore

/// A notification-style card in the top-right corner with a progress bar and
/// a cancel button per running job. macOS notifications cannot show progress
/// (and ActivityKit is not available on the Mac), so this is a panel of our
/// own. It never takes focus from the app in front.
@MainActor
final class ProgressCardController {
    /// Quick jobs finish before the card would appear, so it never flashes.
    static let defaultShowDelay: Duration = .seconds(1)

    private let actions: ActionsService
    private let showDelay: Duration
    private let panel: ProgressCardPanel
    private var showTask: Task<Void, Never>?

    init(actions: ActionsService, showDelay: Duration = defaultShowDelay) {
        self.actions = actions
        self.showDelay = showDelay
        panel = ProgressCardPanel()
        let hostingView = FirstClickHostingView(rootView: ProgressCardView(actions: actions))
        hostingView.sizingOptions = []
        panel.contentView = hostingView
        observeJobs()
    }

    /// Whether the card is (being) shown; the panel itself fades out first.
    private(set) var isShowing = false

    private func observeJobs() {
        let count = withObservationTracking {
            actions.jobs.count
        } onChange: { [weak self] in
            Task { @MainActor in self?.observeJobs() }
        }
        update(jobCount: count)
    }

    private func update(jobCount: Int) {
        guard jobCount > 0 else {
            showTask?.cancel()
            showTask = nil
            hide()
            return
        }
        if isShowing {
            place()
        } else if showTask == nil {
            showTask = Task { [weak self, showDelay] in
                try? await Task.sleep(for: showDelay)
                guard let self, !Task.isCancelled else { return }
                self.showTask = nil
                if !self.actions.jobs.isEmpty { self.show() }
            }
        }
    }

    private func show() {
        isShowing = true
        place()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        isShowing = false
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            panel.animator().alphaValue = 0
        } completionHandler: { [panel] in
            MainActor.assumeIsolated {
                // A new job may have brought it back meanwhile.
                if panel.alphaValue == 0 { panel.orderOut(nil) }
            }
        }
    }

    /// Below the menu bar in the top-right corner, where notifications
    /// appear, sized to the number of jobs.
    private func place() {
        let size = NSSize(
            width: ProgressCardView.width,
            height: ProgressCardView.height(forJobs: actions.jobs.count))
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let margin: CGFloat = 12
        let origin = NSPoint(x: visible.maxX - size.width - margin, y: visible.maxY - size.height - margin)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: panel.isVisible)
    }
}

private final class ProgressCardPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: ProgressCardView.width, height: 80),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
    }

    /// Never key: typing stays in the app in front, and the palette keeps
    /// its focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The cancel button must work on the first click, although the panel is
/// never key and Cortex never active.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct ProgressCardView: View {
    static let width: CGFloat = 340
    static let rowHeight: CGFloat = 58
    static let padding: CGFloat = 10

    static func height(forJobs count: Int) -> CGFloat {
        CGFloat(max(count, 1)) * rowHeight + 2 * padding
    }

    let actions: ActionsService

    var body: some View {
        VStack(spacing: 0) {
            ForEach(actions.jobs) { job in
                ProgressCardRow(job: job)
                    .frame(height: Self.rowHeight)
            }
        }
        .padding(Self.padding)
        .frame(width: Self.width, alignment: .top)
        .frame(maxHeight: .infinity, alignment: .top)
        .glassEffect(.regular, in: .rect(cornerRadius: 18))
    }
}

private struct ProgressCardRow: View {
    let job: ActionJob

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: 28)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(job.title)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(status)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Text(job.inputSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let progress = job.progress {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                } else {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .controlSize(.small)
                }
            }

            Button {
                job.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
            .disabled(job.isCancelled)
        }
        .padding(.horizontal, 6)
    }

    private var status: String {
        if job.isCancelled { return "Cancelling…" }
        return job.progress.map { "\(Int(($0 * 100).rounded())) %" } ?? ""
    }
}
