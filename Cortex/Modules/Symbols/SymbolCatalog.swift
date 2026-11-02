import Foundation
import CortexCore

struct SFSymbol: Equatable, Identifiable, Sendable {
    let name: String
    /// Position in the order SF Symbols lists them.
    let order: Int
    /// Search words the system has for it (may be empty).
    let keywords: [String]
    /// The macOS version it first exists in ("11.0"), if known.
    let macOSVersion: String?

    var id: String { name }
}

/// The SF Symbols this Mac has, with a search over their names and the
/// system's own search words. The names come from `CoreGlyphs.bundle`, a
/// file of the OS and not an API: it is read defensively, and the catalog is
/// empty if it ever moves or changes shape.
struct SymbolCatalog: Sendable {
    static let shared = SymbolCatalog.system()

    static let glyphsDirectory = URL(filePath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources")

    /// Localised copies of a symbol (`doc.richtext.fill.th`, `chevron.right.rtl`)
    /// look the same in the grid and are left out when the plain one exists.
    static let localizationSuffixes: Set<String> = [
        "ar", "bn", "el", "gu", "he", "hi", "ja", "kn", "ko", "ml", "mni", "mr", "or", "pa", "rtl", "ru", "sat", "si",
        "ta", "te", "th", "zh",
    ]

    /// In the order SF Symbols lists them.
    let symbols: [SFSymbol]
    private let index: [Entry]
    /// Position in `symbols` by name.
    private let positions: [String: Int]

    var isEmpty: Bool { symbols.isEmpty }

    /// - Parameters:
    ///   - order: all symbol names, in display order.
    ///   - search: search words by symbol name; names without an entry use
    ///     those of the longest shorter name that has one (`heart.circle.fill`
    ///     finds `heart`'s).
    ///   - releases: the release label (`"2020.1"`) of each symbol name.
    ///   - releaseVersions: the macOS version of each release label.
    ///   - osVersion: symbols that need a newer macOS are left out; the grid
    ///     could draw them as empty cells.
    init(
        order: [String],
        search: [String: [String]],
        releases: [String: String],
        releaseVersions: [String: String],
        osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion
    ) {
        let known = Set(order)
        var symbols: [SFSymbol] = []
        for (position, name) in order.enumerated() {
            if Self.isLocalizedCopy(name, known: known) { continue }
            let version = releases[name].flatMap { releaseVersions[$0] }
            if let version, Self.compare(version, to: osVersion) == .orderedDescending { continue }
            symbols.append(SFSymbol(
                name: name, order: position, keywords: Self.keywords(for: name, in: search), macOSVersion: version))
        }
        self.symbols = symbols
        index = symbols.map(Entry.init)
        positions = Dictionary(symbols.enumerated().map { ($1.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private init() {
        symbols = []
        index = []
        positions = [:]
    }

    /// The catalog of this Mac, empty if the system files are unreadable.
    static func system(directory: URL = glyphsDirectory) -> SymbolCatalog {
        func plist(_ name: String) -> Any? {
            (try? Data(contentsOf: directory.appending(path: name)))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
        }
        guard let order = plist("symbol_order.plist") as? [String],
              let search = plist("symbol_search.plist") as? [String: [String]],
              let availability = plist("name_availability.plist") as? [String: Any],
              let releases = availability["symbols"] as? [String: String],
              let years = availability["year_to_release"] as? [String: [String: String]]
        else {
            Log.logger("symbols").error("SF Symbols data not found in CoreGlyphs.bundle")
            return SymbolCatalog()
        }
        return SymbolCatalog(
            order: order, search: search, releases: releases,
            releaseVersions: years.compactMapValues { $0["macOS"] })
    }

    private static func isLocalizedCopy(_ name: String, known: Set<String>) -> Bool {
        guard let dot = name.lastIndex(of: ".") else { return false }
        return localizationSuffixes.contains(String(name[name.index(after: dot)...])) && known.contains(String(name[..<dot]))
    }

    private static func keywords(for name: String, in search: [String: [String]]) -> [String] {
        var candidate = Substring(name)
        while true {
            if let words = search[String(candidate)] { return words }
            guard let dot = candidate.lastIndex(of: ".") else { return [] }
            candidate = candidate[..<dot]
        }
    }

    /// "11.3" against an OS version, by major and minor.
    private static func compare(_ version: String, to os: OperatingSystemVersion) -> ComparisonResult {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        if major != os.majorVersion { return major < os.majorVersion ? .orderedAscending : .orderedDescending }
        if minor != os.minorVersion { return minor < os.minorVersion ? .orderedAscending : .orderedDescending }
        return .orderedSame
    }

    func symbol(named name: String) -> SFSymbol? {
        positions[name].map { symbols[$0] }
    }

    // MARK: - Search

    /// Symbols matching every word of `query` (in the name, a part of it, or
    /// a search word), best match first: exact names, then names starting
    /// with the query (shorter ones first, so `star` before `star.circle.fill`),
    /// then whole parts, then the rest. Ties go to the more used, then to
    /// the order of SF Symbols.
    func search(_ query: String, usage: UsageRanking = UsageRanking(), now: Date = .now) -> [SFSymbol] {
        let words = query.split { $0.isWhitespace || $0 == ":" }.map { $0.lowercased() }
        guard !words.isEmpty else { return symbols }

        let scored: [(entry: Entry, score: Int, usage: Double)] = index.compactMap { entry in
            var total = 0
            for word in words {
                guard let score = entry.score(word) else { return nil }
                total += score
            }
            return (entry, total, usage.score(of: entry.symbol.name, now: now))
        }
        return scored.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.usage != $1.usage { return $0.usage > $1.usage }
            if $0.entry.nameLength != $1.entry.nameLength { return $0.entry.nameLength < $1.entry.nameLength }
            return $0.entry.symbol.order < $1.entry.symbol.order
        }.map(\.entry.symbol)
    }

    private struct Entry: Sendable {
        let symbol: SFSymbol
        let parts: [String]
        let keywords: [String]
        /// The name without its dots, so `personcircle` finds `person.circle`.
        let compactName: String
        /// `name.count`, which the sort would otherwise count again per comparison.
        let nameLength: Int

        init(_ symbol: SFSymbol) {
            self.symbol = symbol
            nameLength = symbol.name.count
            parts = symbol.name.split(separator: ".").map(String.init)
            compactName = parts.joined()
            keywords = symbol.keywords.map { $0.lowercased() }
        }

        /// Each kind of name match is tried as typed and then with the dots
        /// left out on both sides, which ranks just below it.
        func score(_ word: String) -> Int? {
            let name = symbol.name
            let compactWord = word.replacing(".", with: "")
            let compares = !compactWord.isEmpty
            if name == word { return 100 }
            if compares, compactName == compactWord { return 95 }
            if name.hasPrefix(word) { return 85 }
            if compares, compactName.hasPrefix(compactWord) { return 80 }
            if parts.contains(word) { return 75 }
            if parts.contains(where: { $0.hasPrefix(word) }) { return 65 }
            if keywords.contains(word) { return 60 }
            if keywords.contains(where: { $0.hasPrefix(word) }) { return 50 }
            if name.contains(word) { return 40 }
            if compares, compactName.contains(compactWord) { return 35 }
            if keywords.contains(where: { $0.contains(word) }) { return 30 }
            return nil
        }
    }
}
