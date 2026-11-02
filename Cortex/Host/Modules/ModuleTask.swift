import Foundation

/// Something kept running in the background until `cancel()`.
@MainActor
final class ModuleTask {
    private var onCancel: (() -> Void)?

    init(onCancel: @escaping () -> Void) {
        self.onCancel = onCancel
    }

    var isCancelled: Bool { onCancel == nil }

    func cancel() {
        let onCancel = onCancel
        self.onCancel = nil
        onCancel?()
    }
}

/// Runs `start` with the value while `wanted` returns one and `stop` when it
/// returns nil, following every change of what `wanted` reads (observable
/// settings). Only runs with the Accessibility permission: stops when it is
/// revoked and starts again once it is granted, also after a `start` that
/// failed for want of it. Cancelling the task stops it for good.
///
/// `start` is called again on every change while wanted, so it must accept
/// being called while running (an event tap that takes the new rules).
@MainActor
func whileWanted<Value>(
    accessibility: AccessibilityPermission,
    _ wanted: @escaping @MainActor () -> Value?,
    start: @escaping @MainActor (Value) -> Bool,
    stop: @escaping @MainActor () -> Void
) -> ModuleTask {
    let runner = WhileWanted(accessibility: accessibility, wanted: wanted, start: start, stop: stop)
    let task = ModuleTask {
        runner.isCancelled = true
        stop()
    }
    runner.update()
    return task
}

/// `whileWanted` for something that is either on or off.
@MainActor
func whileWanted(
    accessibility: AccessibilityPermission,
    _ wanted: @escaping @MainActor () -> Bool,
    start: @escaping @MainActor () -> Bool,
    stop: @escaping @MainActor () -> Void
) -> ModuleTask {
    whileWanted(accessibility: accessibility, { wanted() ? () : nil }, start: { _ in start() }, stop: stop)
}

@MainActor
private final class WhileWanted<Value> {
    let accessibility: AccessibilityPermission
    let wanted: @MainActor () -> Value?
    let start: @MainActor (Value) -> Bool
    let stop: @MainActor () -> Void
    var isCancelled = false {
        didSet { if isCancelled { setWatching(false) } }
    }
    /// Started, so the permission is watched for revocation.
    private var isWatching = false

    init(
        accessibility: AccessibilityPermission,
        wanted: @escaping @MainActor () -> Value?,
        start: @escaping @MainActor (Value) -> Bool,
        stop: @escaping @MainActor () -> Void
    ) {
        self.accessibility = accessibility
        self.wanted = wanted
        self.start = start
        self.stop = stop
    }

    /// Kept alive by the observation until the task is cancelled.
    func update() {
        guard !isCancelled else { return }
        let (value, granted) = withObservationTracking {
            (wanted(), accessibility.isGranted)
        } onChange: {
            Task { @MainActor in self.update() }
        }
        guard let value else {
            stop()
            setWatching(false)
            return
        }
        // A tap left running without the permission freezes all input, so it
        // stops the moment the permission is gone and waits for it to return.
        guard granted else {
            stop()
            setWatching(false)
            accessibility.startPolling()
            return
        }
        if start(value) {
            setWatching(true)
        } else {
            setWatching(false)
            accessibility.refresh()
            accessibility.startPolling()
        }
    }

    private func setWatching(_ watching: Bool) {
        guard watching != isWatching else { return }
        isWatching = watching
        if watching {
            accessibility.startWatching()
        } else {
            accessibility.stopWatching()
        }
    }
}
