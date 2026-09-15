import Foundation

/// Large counts, dates and durations in the app's own language.
///
/// Everything here goes through `L10n.locale` rather than `Locale.current`,
/// because Codenotch picks its language in Settings instead of following the
/// Mac. A person running macOS in English who chooses Монгол was otherwise
/// reading Mongolian copy with English scale words and English weekday names
/// beside it — the half-translated look this exists to remove.
///
/// The scale words are catalog keys, not a `switch` in here, so a locale that
/// groups by ten-thousands (日本語 万, 简体中文 万) can say so in the catalog
/// without this file learning about it. English source strings are the keys,
/// per `L10n`, so English renders exactly what it rendered before.
enum NumberCopy {

    // MARK: - Counts

    /// A count with its scale word: `651k`, and `651 мянга` in Mongolian.
    ///
    /// Below 10 000 the number prints verbatim — requests and credits are
    /// three or four digits and a scale word on them reads as noise.
    ///
    /// The mantissa is formatted against `locale` too, so a locale that writes
    /// `1,1` rather than `1.1` gets its own decimal mark instead of the one
    /// `String(format:)` would bake in from the C locale.
    static func scaled(_ count: Int, locale: Locale = L10n.locale) -> String {
        if count < 10_000 { return integer(count, locale: locale) }

        if count < 1_000_000 {
            return L10n.t("\(integer(count / 1_000, locale: locale))k", locale: locale)
        }
        if count < 1_000_000_000 {
            return L10n.t("\(decimal(Double(count) / 1_000_000, locale: locale))M", locale: locale)
        }
        return L10n.t("\(decimal(Double(count) / 1_000_000_000, locale: locale))B", locale: locale)
    }

    /// A whole number with the locale's own grouping separator.
    static func integer(_ value: Int, locale: Locale = L10n.locale) -> String {
        value.formatted(.number.grouping(.never).locale(locale))
    }

    /// One fraction digit, kept even when it is zero, so a ring that ticks
    /// from `2.0M` to `2.1M` does not change width as it goes.
    static func decimal(_ value: Double, locale: Locale = L10n.locale) -> String {
        value.formatted(.number.precision(.fractionLength(1)).locale(locale))
    }

    /// A count that is grouped the way the locale groups: `1,128,771`, and
    /// `1 128 771` in Russian. For the places that print the figure in full.
    static func grouped(_ value: Int, locale: Locale = L10n.locale) -> String {
        value.formatted(.number.locale(locale))
    }

    // MARK: - Bytes

    /// Memory sizes, with the unit and the decimal mark both from `locale`.
    ///
    /// `.byteCount` rather than a hand-rolled table of powers of 1024: the
    /// unit names are already translated by the system for every language the
    /// app ships, and the binary/decimal convention is the platform's to pick.
    /// `spellsOutZero: false` because the default writes "Zero kB" for an
    /// unloaded model, which reads as a unit that was measured rather than a
    /// size that is not there. "0 bytes" is the honest version.
    static func bytes(_ count: Int64, locale: Locale = L10n.locale) -> String {
        count.formatted(.byteCount(style: .memory, spellsOutZero: false).locale(locale))
    }

    // MARK: - Durations

    /// A span in the app's language: `2h 30m`, and `2 ц 30 мин` in Mongolian.
    ///
    /// Rounded to whole minutes and never below one, which is what the tooltip
    /// wants — a reset "in 0 minutes" reads as though it has already happened.
    static func duration(seconds: Double, locale: Locale = L10n.locale) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        let hours = minutes / 60
        let remainder = minutes % 60

        if hours > 0 {
            return remainder == 0
                ? L10n.t("\(integer(hours, locale: locale))h", locale: locale)
                : L10n.t("\(integer(hours, locale: locale))h \(integer(remainder, locale: locale))m",
                         locale: locale)
        }
        return L10n.t("\(integer(minutes, locale: locale))m", locale: locale)
    }

    /// A whole number of days.
    static func days(_ value: Int, locale: Locale = L10n.locale) -> String {
        L10n.t("\(integer(value, locale: locale))d", locale: locale)
    }

    // MARK: - Dates

    /// How far off a moment is, in the app's language: `in 3 min`, `2 ц өмнө`.
    ///
    /// A fresh formatter per call rather than a shared one: `locale` changes
    /// whenever Settings does, and a cached formatter kept answering in the
    /// language the app launched in until it was restarted.
    static func relative(_ date: Date,
                         to reference: Date = Date(),
                         locale: Locale = L10n.locale,
                         style: RelativeDateTimeFormatter.UnitsStyle = .abbreviated) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = style
        return formatter.localizedString(for: date, relativeTo: reference)
    }

    /// A clock time, no date: `14:30`, or `2:30 PM` where the locale says so.
    static func time(_ date: Date, locale: Locale = L10n.locale) -> String {
        date.formatted(.dateTime.hour().minute().locale(locale))
    }
}
