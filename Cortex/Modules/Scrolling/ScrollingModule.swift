import SwiftUI

/// Reverses the scroll direction, separately for the trackpad and the mouse
/// and for each axis, through an event tap that exists only while the module
/// is on and has something to reverse. Off by default; its switch replaces
/// "Adjust scrolling".
@MainActor
final class ScrollingModule: CortexModule {
    static let manifest = ModuleManifest(
        id: "scrolling", name: "Scrolling", summary: "Reverses the scroll direction of the mouse or the trackpad.",
        symbol: "arrow.up.and.down", enabledByDefault: false, legacyEnabledKey: "scrollReversal",
        permissions: [.accessibility], order: 60)

    let reverser: ScrollReverser
    private let context: ModuleContext
    /// The tap's lifetime, between `start()` and `stop()`.
    private(set) var reversal: ModuleTask?

    init(context: ModuleContext) {
        self.context = context
        reverser = ScrollReverser(settings: ScrollingSettings(defaults: context.defaults.store))
    }

    var options: [ModuleOption] {
        let settings = Bindable(reverser.settings)
        return [
            ModuleOption(id: "vertical", title: "Reverse vertical", kind: .toggle(settings.reverseVertical)),
            ModuleOption(id: "horizontal", title: "Reverse horizontal", kind: .toggle(settings.reverseHorizontal)),
            ModuleOption(id: "trackpad", title: "Trackpad", kind: .toggle(settings.reverseTrackpad)),
            ModuleOption(id: "mouse", title: "Mouse", help: "A Magic Mouse counts as a trackpad.", kind: .toggle(settings.reverseMouse)),
        ]
    }

    var settingsView: AnyView? {
        AnyView(ScrollingSettingsView(
            settings: reverser.settings, reverser: reverser,
            requestAccessibility: { [context] in context.requestAccessibility() }))
    }

    func start() async {
        guard reversal == nil else { return }
        let reverser = reverser
        // The tap runs with the current rules exactly while there are any.
        reversal = context.whileWanted(
            { reverser.settings.activeRules },
            start: { reverser.start(rules: $0) },
            stop: { reverser.stop() })
    }

    func stop() {
        reversal?.cancel()
        reversal = nil
    }
}
