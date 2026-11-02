import SwiftUI
import CortexCore

/// `=` in the palette: calculates and converts units as you type
/// (`=1920/1080`, `=3 in to cm`); ⏎ pastes the result. The maths and units
/// are in CortexCore (`CalcQuery`); recent calculations stay on this Mac.
@MainActor
final class CalculatorModule: CortexModule {
    static let manifest = ModuleManifest(
        id: "calculator", name: "Calculator", summary: "Calculates and converts units in the palette as you type.",
        symbol: "plus.forwardslash.minus", trigger: .prefix("="), placeholder: "calc",
        permissions: [.accessibility], order: 45)

    let settings: CalculatorSettings
    private let scope: CalculatorScope

    init(context: ModuleContext) {
        let settings = CalculatorSettings(defaults: context.defaults)
        self.settings = settings
        scope = CalculatorScope(settings: settings, moduleID: context.id) { [context] in context.palette }
    }

    var palette: (any PaletteScope)? { scope }

    var options: [ModuleOption] {
        let settings = Bindable(settings)
        let separator = Binding(
            get: { [settings = self.settings] in settings.decimalSeparator.rawValue },
            set: { [settings = self.settings] in
                settings.decimalSeparator = CalculatorDecimalSeparator(rawValue: $0) ?? .system
            })
        let example = 1234.5
        return [
            ModuleOption(
                id: "digits", title: "Significant digits", help: "Of the result. The plain number below it is exact.",
                kind: .integer(settings.digits, range: CalculatorSettings.digitRange, unit: nil)),
            ModuleOption(
                id: "decimalSeparator", title: "Result format",
                kind: .choice(separator, [
                    (value: CalculatorDecimalSeparator.system.rawValue,
                     title: "System (\(CalcFormatter.display(example)))"),
                    (value: CalculatorDecimalSeparator.point.rawValue,
                     title: "Point (\(CalcFormatter.display(example, locale: Locale(identifier: "en_US_POSIX"))))"),
                ])),
            ModuleOption(
                id: "keepRecents", title: "Keep recent calculations",
                help: "Listed after = with nothing typed. Only on this Mac.",
                kind: .toggle(settings.keepRecents)),
            ModuleOption(
                id: "clearRecents", title: "Recent calculations",
                kind: .button("Clear", role: .destructive) { [settings = self.settings] in settings.clearRecents() },
                isEnabled: { [settings = self.settings] in !settings.recents.isEmpty }),
        ]
    }

    func stop() {
        scope.clear()
    }
}
