import Foundation
import Testing
@testable import CortexCore

@Suite struct EmojiTests {
    let catalog = EmojiCatalog.shared
    let languages = ["de", "en"]

    func characters(_ query: String, languages: [String] = ["en"], usage: UsageRanking = UsageRanking()) -> [String] {
        catalog.search(query, languages: languages, usage: usage).map(\.character)
    }

    /// Variation selectors differ between sources; compare without them.
    func bare(_ text: String) -> String { text.replacingOccurrences(of: "\u{FE0F}", with: "") }

    @Test func bundledDataIsLoaded() {
        #expect(catalog.emoji.count > 1_800)
        #expect(catalog.emoji.allSatisfy { $0.version <= EmojiCatalog.maxVersion })
        #expect(catalog.languages.contains("de"))
        #expect(Set(catalog.emoji.map(\.group)) == Set(EmojiGroup.allCases))
        #expect(Set(catalog.emoji.map(\.character)).count == catalog.emoji.count)
    }

    @Test func emptyQueryListsEverythingInUnicodeOrder() {
        #expect(catalog.search("").count == catalog.emoji.count)
        #expect(bare(catalog.search("").first?.character ?? "") == "😀")
        #expect(catalog.search(":").count == catalog.emoji.count)
    }

    @Test func findsByNameKeywordAndShortcode() {
        #expect(characters("grinning").map(bare).contains("😀"))
        #expect(characters("thumbs up").map(bare).first == "👍")
        #expect(characters("thumbsup").map(bare).first == "👍")
        #expect(characters("happy").map(bare).contains("😀"), "a keyword")
        #expect(characters("+1").map(bare).first == "👍")
    }

    @Test func spacesAndUnderscoresCanBeLeftOut() {
        #expect(characters("redheart").map(bare).first == "❤")
        #expect(characters("facewithtears").map(bare).first == "😂")
        #expect(characters("tearsofjoy").map(bare).contains("😂"))
        #expect(characters("rotesherz", languages: languages).map(bare).first == "❤")
        #expect(characters("partypop").map(bare).first == "🎉", "party_popper without the underscore")
        // As typed still ranks first.
        #expect(characters("red heart").map(bare).first == "❤")
    }

    @Test func colonsAndCaseAreIgnored() {
        #expect(characters(":THUMBSUP:") == characters("thumbsup"))
        #expect(characters("thumbs_up").map(bare).first == "👍")
    }

    @Test func everyWordMustMatch() {
        let hits = characters("red heart")
        #expect(hits.map(bare).first == "❤")
        #expect(characters("heart zzzz").isEmpty)
    }

    @Test func exactNameAndShortcodeBeatPartialMatches() {
        let hits = catalog.search("fire", languages: ["en"])
        #expect(bare(hits.first?.character ?? "") == "🔥")
    }

    @Test func searchesTheSystemLanguage() {
        #expect(characters("daumen", languages: languages).map(bare).first == "👍")
        #expect(characters("daumen").isEmpty, "German is only searched when asked for")
        #expect(characters("Gesicht", languages: languages).count > 50)
    }

    @Test func foldsCaseAndDiacritics() {
        // "fröhlich" is a German keyword of 😀.
        #expect(characters("frohlich", languages: languages).map(bare).contains("😀"))
        #expect(characters("FRÖHLICH", languages: languages).map(bare).contains("😀"))
    }

    @Test func usageBreaksTiesAmongEqualMatches() throws {
        // "happy" is an exact keyword of 16 emoji (all equal), and part of
        // "unhappy" in others, which score lower.
        let equal = catalog.search("happy").filter { $0.keywords["en"]?.contains("happy") == true }
        #expect(equal.count > 5)
        let last = try #require(equal.last).character
        var usage = UsageRanking()
        usage.recordUse(of: last)
        #expect(characters("happy", usage: usage).first == last)
        #expect(characters("happy").first != last)
    }

    @Test func preferredLanguagesComeFirstThenEnglish() {
        #expect(catalog.languages(preferred: ["de-DE", "en-US"]) == ["de", "en"])
        #expect(catalog.languages(preferred: ["fr-FR", "en-US"]) == ["en"])
        #expect(catalog.languages(preferred: ["de"]) == ["de", "en"])
    }

    @Test func nameFallsBackToEnglish() throws {
        let thumbs = try #require(catalog.search("thumbsup").first)
        #expect(thumbs.name(in: ["de", "en"]) == "Daumen hoch")
        #expect(thumbs.name(in: ["fr", "en"]) == "thumbs up")
    }

    @Test func skinTones() throws {
        let thumbs = try #require(catalog.search("thumbsup").first)
        #expect(thumbs.hasSkinTones)
        #expect(thumbs.skinTones.count == 5)
        #expect(thumbs.character(tone: nil) == thumbs.character)
        #expect(thumbs.character(tone: .medium) == "👍🏽")
        let fire = try #require(catalog.search("fire").first)
        #expect(!fire.hasSkinTones)
        #expect(fire.character(tone: .dark) == fire.character, "no variants: the emoji stays as it is")
    }

    @Test func skinToneCycleEndsWithNone() {
        var tone: EmojiSkinTone? = nil
        var seen: [EmojiSkinTone?] = []
        for _ in 0..<6 {
            tone = EmojiSkinTone.next(after: tone)
            seen.append(tone)
        }
        #expect(seen == [.light, .mediumLight, .medium, .mediumDark, .dark, nil])
        #expect(EmojiSkinTone.medium.swatch == "✋🏽")
    }

    @Test func codePoints() throws {
        let thumbs = try #require(catalog.search("thumbsup").first)
        #expect(thumbs.codePoints == "U+1F44D")
    }

    @Test func newerEmojiVersionsAreLeftOut() throws {
        let older = try EmojiCatalog(data: #require(EmojiCatalog.bundledData()), maxVersion: 12.0)
        #expect(older.emoji.count < catalog.emoji.count)
        #expect(older.emoji.allSatisfy { $0.version <= 12.0 })
    }

    // MARK: - Usage

    @Test func usageCountsAndDecays() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var usage = UsageRanking()
        usage.recordUse(of: "🔥", now: start)
        usage.recordUse(of: "🔥", now: start)
        usage.recordUse(of: "🎉", now: start)
        #expect(usage.score(of: "🔥", now: start) == 2)
        #expect(usage.top(2, now: start) == ["🔥", "🎉"])

        let later = start.addingTimeInterval(UsageRanking.halfLife)
        #expect(abs(usage.score(of: "🔥", now: later) - 1) < 0.001)
        // A fresh use outweighs an old habit.
        usage.recordUse(of: "🎉", now: later)
        usage.recordUse(of: "🎉", now: later)
        #expect(usage.top(1, now: later) == ["🎉"])
        #expect(usage.score(of: "🚀", now: later) == 0)
    }

    @Test func usageKeepsTheBestRecords() {
        var usage = UsageRanking()
        let now = Date.now
        for index in 0..<(UsageRanking.maxRecords + 20) {
            usage.recordUse(of: "e\(index)", now: now)
        }
        for _ in 0..<5 { usage.recordUse(of: "e0", now: now) }
        #expect(usage.top(1000, now: now).count == UsageRanking.maxRecords)
        #expect(usage.top(1, now: now) == ["e0"])
    }

    @Test func usageKeepsANewGlyphWhenTheOthersScoreHigher() {
        var usage = UsageRanking()
        let now = Date.now
        for index in 0..<UsageRanking.maxRecords {
            usage.recordUse(of: "e\(index)", now: now)
            usage.recordUse(of: "e\(index)", now: now)
        }
        usage.recordUse(of: "new", now: now)
        usage.recordUse(of: "new", now: now)
        #expect(usage.score(of: "new", now: now) == 2)
        #expect(usage.top(1000, now: now).count == UsageRanking.maxRecords)
    }

    @Test func usageRoundTripsThroughJSON() throws {
        var usage = UsageRanking()
        usage.recordUse(of: "🔥")
        let decoded = try JSONDecoder().decode(UsageRanking.self, from: JSONEncoder().encode(usage))
        #expect(decoded == usage)
    }
}
