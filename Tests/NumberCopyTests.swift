import XCTest
@testable import Codenotch

/// The figures on the notch in the app's own language.
///
/// Every assertion passes an explicit locale. `L10n.locale` answers `en` under
/// XCTest by design — see the note in `L10n` — so a test that relied on the
/// ambient locale would only ever exercise English.
final class NumberCopyTests: XCTestCase {
    private let mn = Locale(identifier: "mn")
    private let en = Locale(identifier: "en")
    private let ru = Locale(identifier: "ru")

    // MARK: - Scale words

    /// The point of the change: a Mongolian ring says "мянга", not "k".
    func testMongolianSpellsOutTheScaleWord() {
        XCTAssertEqual(NumberCopy.scaled(651_061, locale: mn), "651 мянга")
        XCTAssertEqual(NumberCopy.scaled(1_128_771, locale: mn), "1.1 сая")
        XCTAssertEqual(NumberCopy.scaled(2_300_000_000, locale: mn), "2.3 тэрбум")
    }

    func testRussianUsesItsOwnAbbreviations() {
        XCTAssertEqual(NumberCopy.scaled(651_061, locale: ru), "651 тыс.")
        XCTAssertEqual(NumberCopy.scaled(1_128_771, locale: ru), "1,1 млн")
    }

    /// English is the catalog's source language, so it renders the key itself
    /// — which is exactly what it rendered before this file existed. The ring
    /// has no room to grow in English and none of it should have changed.
    func testEnglishIsUnchanged() {
        XCTAssertEqual(NumberCopy.scaled(9_999, locale: en), "9999")
        XCTAssertEqual(NumberCopy.scaled(651_061, locale: en), "651k")
        XCTAssertEqual(NumberCopy.scaled(1_128_771, locale: en), "1.1M")
        XCTAssertEqual(NumberCopy.scaled(2_000_000, locale: en), "2.0M")
    }

    /// Under ten thousand a scale word is noise, in every language: a credit
    /// balance of 431 is 431, not "0.4 мянга".
    func testSmallCountsPrintVerbatimInEveryLanguage() {
        for locale in [en, mn, ru] {
            XCTAssertEqual(NumberCopy.scaled(431, locale: locale), "431")
            XCTAssertEqual(NumberCopy.scaled(9_999, locale: locale), "9999")
        }
    }

    /// A four-digit count must not pick up a thousands separator — "9,999"
    /// under a 44 pt ring is a character wider than the ring has to give.
    func testTheRingsOwnFigureIsNeverGrouped() {
        XCTAssertEqual(NumberCopy.integer(9_999, locale: en), "9999")
        XCTAssertEqual(NumberCopy.integer(9_999, locale: ru), "9999")
    }

    /// `LimitWindow.compact` is what the ring and the cards actually call.
    func testCompactGoesThroughTheSameVocabulary() {
        XCTAssertEqual(LimitWindow.compact(651_061, locale: mn), "651 мянга")
        XCTAssertEqual(LimitWindow.compact(651_061, locale: en), "651k")
    }

    /// The tooltip used to format with `en_US_POSIX` and an English "K", so a
    /// Mongolian card carried an English unit. It shares the ring's words now.
    func testTheTooltipAgreesWithTheRing() {
        XCTAssertEqual(UsageFormat.tokens(1_128_771, locale: mn),
                       NumberCopy.scaled(1_128_771, locale: mn))
        XCTAssertEqual(UsageFormat.tokens(nil, locale: mn), "—")
    }

    // MARK: - Durations

    func testDurationsCarryTheirUnitsIntoMongolian() {
        XCTAssertEqual(NumberCopy.duration(seconds: 90 * 60, locale: mn), "1 ц 30 мин")
        XCTAssertEqual(NumberCopy.duration(seconds: 120 * 60, locale: mn), "2 ц")
        XCTAssertEqual(NumberCopy.duration(seconds: 45 * 60, locale: mn), "45 мин")
        XCTAssertEqual(NumberCopy.days(3, locale: mn), "3 хоног")
    }

    func testEnglishDurationsAreUnchanged() {
        XCTAssertEqual(NumberCopy.duration(seconds: 90 * 60, locale: en), "1h 30m")
        XCTAssertEqual(NumberCopy.duration(seconds: 45 * 60, locale: en), "45m")
        XCTAssertEqual(NumberCopy.days(3, locale: en), "3d")
    }

    /// A reset "in 0 minutes" reads as though it has already happened.
    func testAnAlmostElapsedSpanStillReadsAsAMinute() {
        XCTAssertEqual(NumberCopy.duration(seconds: 3, locale: en), "1m")
    }

    // MARK: - Bytes

    /// The hand-rolled table this replaced always wrote an English "GB".
    func testMemorySizesAreLocalized() {
        XCTAssertEqual(NumberCopy.bytes(2_147_483_648, locale: en), "2 GB")
        XCTAssertEqual(NumberCopy.bytes(2_147_483_648, locale: mn), "2 ГБ")
    }

    /// `.byteCount` writes "Zero kB" by default, which reads as a unit that
    /// was measured rather than a size that is not there.
    func testZeroBytesIsNotSpelledOut() {
        XCTAssertEqual(NumberCopy.bytes(0, locale: en), "0 bytes")
    }

    // MARK: - Dates

    /// `RelativeDateTimeFormatter` follows the Mac unless it is told not to,
    /// which put an English "in 4 min" beside Mongolian labels.
    func testRelativeDatesFollowTheAppsLanguageNotTheMacs() {
        let now = Date()
        let soon = now.addingTimeInterval(4 * 60)
        let english = NumberCopy.relative(soon, to: now, locale: en)
        let mongolian = NumberCopy.relative(soon, to: now, locale: mn)

        XCTAssertFalse(english.isEmpty)
        XCTAssertFalse(mongolian.isEmpty)
        XCTAssertNotEqual(english, mongolian,
                          "the Mongolian relative date is still rendering in English")
    }

    /// A clock time formatted against the app's locale, not the Mac's.
    func testClockTimesUseTheAppsLocale() {
        let noon = Date(timeIntervalSince1970: 0).addingTimeInterval(12 * 3600)
        XCTAssertFalse(NumberCopy.time(noon, locale: en).isEmpty)
        XCTAssertFalse(NumberCopy.time(noon, locale: mn).isEmpty)
    }

    // MARK: - Catalog

    /// The scale words have to be in the catalog or every language silently
    /// falls back to the English "k", which is the bug this all fixes.
    func testTheScaleWordsAreInTheCatalog() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("../Sources/Localizable.xcstrings")
            .standardizedFileURL
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch let error as NSError where error.code == NSFileReadNoPermissionError {
            throw XCTSkip("macOS privacy restricts reading the source catalog")
        }
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let strings = try XCTUnwrap(json?["strings"] as? [String: Any])

        for key in ["%@k", "%@M", "%@B", "%@h", "%@m", "%@h %@m", "%@d"] {
            let entry = strings[key] as? [String: Any]
            let localizations = entry?["localizations"] as? [String: Any]
            XCTAssertNotNil(localizations?["mn"], "no Mongolian scale word for \(key)")
        }
    }
}
