import ServiceManagement
import CortexCore

/// Launch at login through `SMAppService.mainApp`.
///
/// Registers whichever copy of the app is running, so enable it from the
/// installed copy in /Applications, not from a build in DerivedData.
@MainActor
@Observable
final class LaunchAtLogin {
    private(set) var status = SMAppService.mainApp.status
    private(set) var lastError: String?

    @ObservationIgnored private let log = Log.logger("login-item")

    var isEnabled: Bool { status == .enabled || status == .requiresApproval }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            log.error("Changing login item failed: \(error, privacy: .public)")
            lastError = error.localizedDescription
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
