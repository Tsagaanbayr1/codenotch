import Foundation

/// Parses what Claude Code's `/usage` command prints.
///
/// ```
/// You are currently using your subscription to power your Claude Code usage
///
/// Current session: 0% used · resets Sep 12 at 11:20pm (Asia/Ulaanbaatar)
/// Current week (all models): 49% used · resets Sep 15 at 10pm (Asia/Ulaanbaatar)
/// Current week (Opus): 50% used · resets Sep 15 at 10pm (Asia/Ulaanbaatar)
/// ```
///
/// Recorded from a live run. Everything below that — the "What's contributing"
/// breakdown — is local telemetry about *this machine*, not the account's
/// limits, so it is deliberately not read: its percentages are of a different
/// denominator entirely and showing one in a ring would be a lie.
///
/// This is prose, not an API, so two things are true at once: it is the only
/// reading available without holding the user's token, and it can change shape
/// under us. Every ambiguity therefore fails closed — a line that does not
/// parse is dropped, and a run that yields no windows at all throws rather than
/// reporting a confident 0%.
enum ClaudeUsageText {
    /// The windows in a `/usage` printout, in the order the notch shows them.
    static func windows(in text: String,
                        now: Date = Date(),
                        calendar: Calendar = .current) throws -> [LimitWindow] {
        let windows = text
            .split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { window(inLine: String($0), now: now, calendar: calendar) }
            .sorted(by: displayOrder)

        guard !windows.isEmpty else {
            // `/usage` prints a cost summary instead of limits when the login
            // has no subscription behind it. That is not a failure to read —
            // it is a true answer to a different question, and saying "couldn't
            // read usage" would send someone to fix a CLI that is working.
            if text.contains("Total cost:") {
                throw UsageProviderError.unavailable(
                    "This Claude Code login bills by API cost, so it has no subscription limits to show")
            }
            throw UsageProviderError.unavailable("Claude Code's /usage printed no limits")
        }
        return windows
    }

    /// `Current session: 0% used · resets Sep 12 at 11:20pm (Asia/Ulaanbaatar)`
    ///
    /// The `% used` is required immediately after the label rather than merely
    /// looked for in the line, which is what keeps the breakdown underneath out
    /// of the results — `84% of your usage was at >150k context` is a
    /// percentage on a line with a colon, and a looser pattern read it as a
    /// limit window.
    static func window(inLine line: String, now: Date, calendar: Calendar) -> LimitWindow? {
        guard let match = limitLine.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let label = capture(1, in: match, of: line),
              let percent = capture(2, in: match, of: line).flatMap(Double.init)
        else { return nil }

        let id = id(forLabel: label)
        let resets = capture(3, in: match, of: line)
            .flatMap { resetDate(from: $0, now: now, calendar: calendar) }

        return LimitWindow(id: id, label: self.label(forID: id),
                           usedFraction: percent / 100, resetsAt: resets)
    }

    private static let limitLine = try! NSRegularExpression(
        pattern: #"^\s*([^:]+?):\s*([0-9]+(?:\.[0-9]+)?)%\s+used(?:\s*[·.]\s*resets\s+(.+?))?\s*$"#,
        options: [.caseInsensitive]
    )

    // MARK: - Naming

    /// The printed label, turned back into the id the endpoint used to give.
    ///
    /// The ids matter beyond tidiness: archived readings, the hover bands and
    /// the headline are all keyed by them, so "session" and "weekly_all" have
    /// to keep meaning what they meant when the numbers came from
    /// `/api/oauth/usage`. Anything else is derived from the label, so a window
    /// Anthropic adds later still gets a stable id rather than a position.
    static func id(forLabel label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        if lowered == "current session" { return "session" }
        if lowered.hasPrefix("current week") {
            guard let open = trimmed.firstIndex(of: "("),
                  let close = trimmed.lastIndex(of: ")"), open < close
            else { return "weekly_all" }
            let model = trimmed[trimmed.index(after: open)..<close].lowercased()
            return model == "all models" ? "weekly_all" : "weekly_\(slug(model))"
        }
        return slug(lowered)
    }

    /// The frame's wording, for the kinds it drew. Unchanged from the endpoint
    /// era on purpose — the notch has always called these things these names.
    static func label(forID id: String) -> String {
        switch id {
        case "session":       return "Current session"
        case "weekly_all":    return "All models"
        case "weekly_opus":   return "Opus"
        case "weekly_sonnet": return "Sonnet"
        default:
            return id
                .replacingOccurrences(of: "weekly_", with: "")
                .replacingOccurrences(of: "_", with: " ")
                .capitalized
        }
    }

    private static func slug(_ text: String) -> String {
        let allowed = text.map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(allowed)
    }

    /// Session first, then the weekly windows — the order the frame shows.
    static func displayOrder(_ a: LimitWindow, _ b: LimitWindow) -> Bool {
        func rank(_ id: String) -> Int {
            if id == "session" { return 0 }
            if id == "weekly_all" { return 1 }
            return 2
        }
        let (ra, rb) = (rank(a.id), rank(b.id))
        return ra == rb ? a.id < b.id : ra < rb
    }

    // MARK: - When it rolls over

    /// `Sep 12 at 11:20pm (Asia/Ulaanbaatar)` → a `Date`.
    ///
    /// Built from components rather than with a `DateFormatter`, because the
    /// printed form fights every formatter worth using: the meridiem is
    /// lowercase and unspaced, the minutes vanish on the hour ("10pm"), and
    /// **there is no year at all**. The endpoint gave an ISO timestamp; this is
    /// the price of not holding the token.
    ///
    /// The missing year is inferred as the nearest sensible one, so a window
    /// resetting in January read in December lands in the right place instead
    /// of eleven months in the past.
    static func resetDate(from phrase: String, now: Date, calendar: Calendar) -> Date? {
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        guard let match = resetPhrase.firstMatch(in: phrase,
                                                 range: NSRange(phrase.startIndex..., in: phrase)),
              let hour = capture(4, in: match, of: phrase).flatMap(Int.init)
        else { return nil }

        var calendar = calendar
        // The vendor names the zone it formatted in, and it is not always the
        // one this Mac is set to — someone on a work profile abroad gets both.
        if let zone = capture(7, in: match, of: phrase).flatMap(TimeZone.init(identifier:)) {
            calendar.timeZone = zone
        }

        let minute = capture(5, in: match, of: phrase).flatMap(Int.init) ?? 0
        let isPM = capture(6, in: match, of: phrase)?.lowercased() == "p"
        // 12am is hour 0 and 12pm is hour 12; the plain `hour + 12` both of
        // those invite is wrong at exactly the two times people check.
        let hour24 = (hour % 12) + (isPM ? 12 : 0)

        var components = DateComponents()
        components.hour = hour24
        components.minute = minute

        if let relative = capture(1, in: match, of: phrase)?.lowercased() {
            let day = calendar.date(byAdding: .day, value: relative == "tomorrow" ? 1 : 0, to: now) ?? now
            let ymd = calendar.dateComponents([.year, .month, .day], from: day)
            components.year = ymd.year
            components.month = ymd.month
            components.day = ymd.day
            return calendar.date(from: components)
        }

        guard let monthName = capture(2, in: match, of: phrase),
              let month = monthNumber(monthName),
              let day = capture(3, in: match, of: phrase).flatMap(Int.init)
        else { return nil }

        components.month = month
        components.day = day

        // No year in the text. Try this one, then its neighbours, and keep
        // whichever lands nearest to now — a reset is days away, never months.
        let thisYear = calendar.component(.year, from: now)
        return [thisYear, thisYear + 1, thisYear - 1]
            .compactMap { year -> Date? in
                var candidate = components
                candidate.year = year
                return calendar.date(from: candidate)
            }
            .min { abs($0.timeIntervalSince(now)) < abs($1.timeIntervalSince(now)) }
    }

    private static let resetPhrase = try! NSRegularExpression(
        pattern: #"^(?:(today|tomorrow)|([A-Za-z]{3,})\s+(\d{1,2}))\s+at\s+(\d{1,2})(?::(\d{2}))?\s*([ap])\.?m\.?(?:\s*\(([^)]+)\))?"#,
        options: [.caseInsensitive]
    )

    /// `Sep` or `September` → 9. Matched against the POSIX names first: the
    /// text comes from a tool that prints English, whatever this Mac's locale
    /// is set to, and a French `Locale` would otherwise fail to see "Sep".
    static func monthNumber(_ name: String) -> Int? {
        let name = name.lowercased()
        for formatter in [posix, DateFormatter()] {
            let names = (formatter.shortMonthSymbols ?? []) + (formatter.monthSymbols ?? [])
            if let index = names.firstIndex(where: { $0.lowercased() == name }) {
                return index % 12 + 1
            }
        }
        return nil
    }

    private static let posix: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func capture(_ index: Int, in match: NSTextCheckingResult,
                                of text: String) -> String? {
        guard let range = Range(match.range(at: index), in: text) else { return nil }
        return String(text[range])
    }
}
