import Foundation
import CortexCore

/// Keeps the Mac from idle sleeping while Cortex runs, through a `caffeinate`
/// child process. The choice is stored in UserDefaults on this Mac.
///
/// `caffeinate -w` watches Cortex's own pid, so it exits with the app even
/// when the app crashes or is killed.
@MainActor
@Observable
final class KeepAwake {
    static let key = "keepAwake"
    static let caffeinateURL = URL(filePath: "/usr/bin/caffeinate")

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let log = Log.logger("keep-awake")
    @ObservationIgnored private var process: Process?

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.key)
            apply()
        }
    }
    private(set) var lastError: String?

    /// Whether a `caffeinate` process is running right now.
    var isRunning: Bool { process?.isRunning ?? false }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key)
    }

    /// Starts or stops `caffeinate` to match `isEnabled`.
    func apply() {
        if isEnabled { start() } else { stop() }
    }

    func stop() {
        guard let process else { return }
        self.process = nil
        if process.isRunning { process.terminate() }
        log.info("Stopped keeping the Mac awake")
    }

    private func start() {
        guard !isRunning else { return }
        let process = Process()
        process.executableURL = Self.caffeinateURL
        // -i: no idle sleep. The display may still sleep.
        process.arguments = ["-i", "-w", String(ProcessInfo.processInfo.processIdentifier)]
        process.terminationHandler = { [weak self] ended in
            Task { @MainActor in
                guard let self, self.process === ended else { return }
                self.process = nil
                self.log.error("caffeinate exited unexpectedly (status \(ended.terminationStatus))")
            }
        }
        do {
            try process.run()
            self.process = process
            lastError = nil
            log.info("Keeping the Mac awake")
        } catch {
            log.error("Starting caffeinate failed: \(error, privacy: .public)")
            lastError = error.localizedDescription
        }
    }
}
