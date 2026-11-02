import AppKit
import SwiftUI
import CortexCore

/// A row of the `=` list: a way to write the result, or a recent
/// calculation while nothing is typed.
struct CalculatorRow: Hashable, Identifiable {
    enum Kind: Hashable {
        case value
        case recent
    }

    let kind: Kind
    /// What ⏎ pastes (a value) or puts back into the field (a recent).
    let text: String
    let subtitle: String?
    /// What ⇥ puts into the field to keep calculating with it: the exact
    /// value, with its unit (`1.7777777777777777`, `7.62 cm`).
    let continuation: String

    var id: String { "\(kind):\(text)" }
}

/// `=` in the palette: calculates and converts as you type. The rows are the
/// result in the system's number format, as a plain number for code and,
/// for a conversion, without its unit; a lone quantity (`5 ft`) lists it in
/// other units. ⏎ pastes the selected row, ⌥⏎ copies it, ⇥ keeps
/// calculating with it. With nothing typed, the recent calculations: ⏎ puts
/// one back into the field, ⌘⌫ forgets it.
@MainActor
@Observable
final class CalculatorScope: PaletteScope {
    let list = ResultList<CalculatorRow, String>(id: \.id)
    /// The query as last searched.
    private(set) var query = ""
    /// How the query was read, for the pane: `3 inches → centimetres`.
    private(set) var understood: String?
    /// The result at full precision, for the pane.
    private(set) var exact: String?
    /// Why the query has no result; nil while it is fine or unfinished.
    private(set) var error: String?

    @ObservationIgnored private let settings: CalculatorSettings
    @ObservationIgnored private let moduleID: ModuleID
    @ObservationIgnored private let locale: Locale
    @ObservationIgnored private let palette: @MainActor () -> any PaletteHost

    init(
        settings: CalculatorSettings, moduleID: ModuleID, locale: Locale = .current,
        palette: @escaping @MainActor () -> any PaletteHost
    ) {
        self.settings = settings
        self.moduleID = moduleID
        self.locale = locale
        self.palette = palette
    }

    /// The system's decimal separator is accepted in what is typed, besides `.`.
    private var inputSeparator: Character { locale.decimalSeparator?.first ?? "." }

    private var displayLocale: Locale {
        switch settings.decimalSeparator {
        case .system: locale
        case .point: Locale(identifier: "en_US_POSIX")
        }
    }

    // MARK: - Rows

    func rows(for query: CalcQuery, result: CalcResult) -> [CalculatorRow] {
        let value = result.value
        let display = display(value)
        let plain = CalcFormatter.plain(value)
        var rows: [CalculatorRow]

        if let unit = result.unit, query.target == nil {
            let equivalents = UnitCatalog.equivalents(of: value, in: unit)
            let all = equivalents.isEmpty ? [result] : equivalents
            rows = all.compactMap { equivalent in
                guard let unit = equivalent.unit else { return nil }
                return CalculatorRow(
                    kind: .value, text: unit.format(self.display(equivalent.value)), subtitle: unit.plural,
                    continuation: unit.format(CalcFormatter.plain(equivalent.value)))
            }
        } else if let unit = result.unit {
            let continuation = unit.format(plain)
            rows = [
                CalculatorRow(kind: .value, text: unit.format(display), subtitle: "Result", continuation: continuation),
                CalculatorRow(kind: .value, text: display, subtitle: "Without the unit", continuation: continuation),
                CalculatorRow(kind: .value, text: plain, subtitle: "Plain number, for code", continuation: continuation),
            ]
        } else {
            rows = [
                CalculatorRow(kind: .value, text: display, subtitle: "Result", continuation: plain),
                CalculatorRow(kind: .value, text: plain, subtitle: "Plain number, for code", continuation: plain),
            ]
        }
        var seen = Set<String>()
        return rows.filter { seen.insert($0.text).inserted }
    }

    private func display(_ value: Double) -> String {
        CalcFormatter.display(value, digits: settings.digits, locale: displayLocale)
    }

    /// A recent calculation, with what it comes to now.
    private func recentRow(_ calculation: String) -> CalculatorRow {
        let result = try? CalcQuery.parse(calculation, decimalSeparator: inputSeparator).evaluate()
        let subtitle = result.map { result in
            let text = display(result.value)
            return "= " + (result.unit?.format(text) ?? text)
        }
        return CalculatorRow(kind: .recent, text: calculation, subtitle: subtitle, continuation: calculation)
    }

    // MARK: - PaletteScope

    func search(_ text: String) {
        query = text
        understood = nil
        exact = nil
        error = nil
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            list.replace(with: settings.recents.map(recentRow), query: text)
            return
        }
        do {
            let parsed = try CalcQuery.parse(trimmed, decimalSeparator: inputSeparator)
            let result = try parsed.evaluate()
            understood = parsed.text
            let plain = CalcFormatter.plain(result.value)
            exact = result.unit?.format(plain) ?? plain
            list.replace(with: rows(for: parsed, result: result), query: text)
        } catch {
            if error != .unfinished { self.error = error.message }
            list.replace(with: [], query: text)
        }
    }

    func clear() {
        list.clear()
        query = ""
        understood = nil
        exact = nil
        error = nil
    }

    var body: AnyView { AnyView(CalculatorView(scope: self)) }

    func move(_ step: PaletteStep) {
        if case .vertical(let delta) = step { list.move(by: delta) }
    }

    func activate(_ activation: PaletteActivation, target: PaletteTarget) -> Bool {
        let row = switch target {
        case .selected: list.selected
        case .position(let index): list.item(at: index)
        }
        guard let row else {
            Beep.play()
            return true
        }
        choose(row, copyOnly: activation.isCopy)
        return true
    }

    var activationHints: [PaletteHint] {
        switch list.selected?.kind {
        case .recent: [PaletteHint(.primary, "Calculate again")]
        case .value: [PaletteHint(.primary, "Paste"), PaletteHint(.option, "Copy")]
        case nil: []
        }
    }

    var keys: [PaletteKey] {
        let selected = list.selected
        return [
            PaletteKey(.tab, hint: selected?.kind == .value ? "Keep calculating" : nil) { [unowned self] in
                guard let row = list.selected, row.kind == .value else { return true }
                palette().open(moduleID, searching: row.continuation)
                return true
            },
            PaletteKey(.command(.delete), hint: selected?.kind == .recent ? "Forget" : nil) { [unowned self] in
                guard let row = list.selected, row.kind == .recent else { return false }
                settings.removeRecent(row.text)
                search(query)
                return true
            },
        ]
    }

    // MARK: - Actions

    /// Pastes or copies a value and remembers the calculation; puts a recent
    /// calculation back into the field.
    func choose(_ row: CalculatorRow, copyOnly: Bool = false) {
        switch row.kind {
        case .recent:
            palette().open(moduleID, searching: row.text)
        case .value:
            settings.addRecent(query)
            palette().closeAndDeliver(
                .text(row.text), copyOnly ? .copyOnly : .paste(.plainText),
                recording: .record(sensitive: false), restoringPasteboard: false, after: nil)
        }
    }
}
