import XCTest
@testable import Codenotch

/// What `claude -p "/usage"` actually printed, captured from a live run.
///
/// The whole Claude reading now rests on parsing this, so the fixture is the
/// real thing rather than a tidied version of it — including the breakdown
/// underneath, which is local telemetry about *this machine* and must never be
/// mistaken for a limit.
private let livePrintout = """
You are currently using your subscription to power your Claude Code usage

Current session: 0% used · resets Sep 12 at 11:20pm (Asia/Ulaanbaatar)
Current week (all models): 49% used · resets Sep 15 at 10pm (Asia/Ulaanbaatar)
Current week (Fable): 50% used · resets Sep 15 at 10pm (Asia/Ulaanbaatar)

What's contributing to your limits usage?
Approximate, based on local sessions on this machine — does not include other devices or claude.ai. Behaviors are independent characteristics, not a breakdown.

Last 24h · 235 requests · 8 sessions
  84% of your usage was at >150k context
  46% of your usage came from sessions active for 8+ hours
  Top MCP servers: sentry 12%, claude-in-chrome 7%

Last 7d · 7963 requests · 49 sessions
  84% of your usage was at >150k context
  51% of your usage came from subagent-heavy sessions
  Top skills: /claude-in-chrome 3%, /artifact-diagramming 2%
"""

final class ClaudeUsageTextTests: XCTestCase {
    private var ulaanbaatar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Ulaanbaatar")!
        return calendar
    }

    private func now(_ year: Int, _ month: Int, _ day: Int) -> Date {
        ulaanbaatar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func testReadsTheLivePrintout() throws {
        let windows = try ClaudeUsageText.windows(in: livePrintout,
                                                  now: now(2026, 9, 12), calendar: ulaanbaatar)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all", "weekly_fable"])
        XCTAssertEqual(windows.map(\.label), ["Current session", "All models", "Fable"])
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(windows[1].usedFraction ?? -1, 0.49, accuracy: 0.0001)
        XCTAssertEqual(windows[2].usedFraction ?? -1, 0.50, accuracy: 0.0001)
    }

    /// The regression this exists to prevent: `84% of your usage was at >150k
    /// context` is a percentage on a line with a colon above it, and a looser
    /// pattern read those lines as limit windows. They are percentages of a
    /// completely different denominator — putting one in a ring is a lie.
    func testTheBreakdownUnderneathIsNotAWindow() throws {
        let windows = try ClaudeUsageText.windows(in: livePrintout,
                                                  now: now(2026, 9, 12), calendar: ulaanbaatar)
        XCTAssertEqual(windows.count, 3, "only the three limit lines are windows")
        XCTAssertFalse(windows.contains { $0.label.contains("context") })
    }

    func testReadsTheResetInstant() throws {
        let windows = try ClaudeUsageText.windows(in: livePrintout,
                                                  now: now(2026, 9, 12), calendar: ulaanbaatar)
        let session = try XCTUnwrap(windows.first?.resetsAt)
        let parts = ulaanbaatar.dateComponents([.year, .month, .day, .hour, .minute], from: session)
        XCTAssertEqual(parts.month, 9)
        XCTAssertEqual(parts.day, 12)
        XCTAssertEqual(parts.hour, 23, "11:20pm is 23:20")
        XCTAssertEqual(parts.minute, 20)
    }

    /// The minutes vanish on the hour — `10pm`, not `10:00pm`.
    func testAWholeHourHasNoMinutes() throws {
        let date = try XCTUnwrap(ClaudeUsageText.resetDate(from: "Sep 15 at 10pm (Asia/Ulaanbaatar)",
                                                           now: now(2026, 9, 12), calendar: ulaanbaatar))
        let parts = ulaanbaatar.dateComponents([.day, .hour, .minute], from: date)
        XCTAssertEqual(parts.day, 15)
        XCTAssertEqual(parts.hour, 22)
        XCTAssertEqual(parts.minute, 0)
    }

    /// Noon and midnight are where a plain `hour + 12` goes wrong, and they are
    /// exactly the two times a session window tends to roll over.
    func testMiddayAndMidnight() throws {
        func hour(_ phrase: String) throws -> Int? {
            let date = try XCTUnwrap(ClaudeUsageText.resetDate(from: phrase, now: now(2026, 9, 12),
                                                               calendar: ulaanbaatar))
            return ulaanbaatar.dateComponents([.hour], from: date).hour
        }
        XCTAssertEqual(try hour("Sep 12 at 12am (Asia/Ulaanbaatar)"), 0)
        XCTAssertEqual(try hour("Sep 12 at 12pm (Asia/Ulaanbaatar)"), 12)
        XCTAssertEqual(try hour("Sep 12 at 1am (Asia/Ulaanbaatar)"), 1)
    }

    /// There is no year in the printed date. Read on New Year's Eve, a window
    /// resetting in January must not land eleven months in the past.
    func testTheMissingYearIsInferredAcrossNewYear() throws {
        let date = try XCTUnwrap(ClaudeUsageText.resetDate(from: "Jan 2 at 9am (Asia/Ulaanbaatar)",
                                                           now: now(2026, 12, 31), calendar: ulaanbaatar))
        let parts = ulaanbaatar.dateComponents([.year, .month, .day], from: date)
        XCTAssertEqual(parts.year, 2027)
        XCTAssertEqual(parts.month, 1)
        XCTAssertEqual(parts.day, 2)
    }

    /// And the other way: a window that reset yesterday, read on New Year's Day.
    func testAJustPassedResetStaysInTheOldYear() throws {
        let date = try XCTUnwrap(ClaudeUsageText.resetDate(from: "Dec 31 at 9am (Asia/Ulaanbaatar)",
                                                           now: now(2027, 1, 1), calendar: ulaanbaatar))
        XCTAssertEqual(ulaanbaatar.dateComponents([.year], from: date).year, 2026)
    }

    /// The zone the vendor formatted in wins over this Mac's, so a work profile
    /// read from abroad does not silently shift by the offset between them.
    func testTheNamedZoneWins() throws {
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let date = try XCTUnwrap(
            ClaudeUsageText.resetDate(from: "Sep 15 at 10pm (Asia/Ulaanbaatar)",
                                      now: now(2026, 9, 12), calendar: tokyo)
        )
        XCTAssertEqual(ulaanbaatar.dateComponents([.hour], from: date).hour, 22)
    }

    /// A login billing by API cost gets a cost summary instead of limits. That
    /// is a true answer to a different question — reporting "couldn't read
    /// usage" would send someone to fix a CLI that is working perfectly.
    func testACostSummarySaysSoRatherThanReadingZero() {
        let costOnly = """
        Total cost:            $12.4100
        Total duration (API):  0s
        Usage:                 0 input, 0 output, 0 cache read, 0 cache write
        """
        XCTAssertThrowsError(try ClaudeUsageText.windows(in: costOnly, now: Date())) { error in
            guard case UsageProviderError.unavailable(let why) = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
            XCTAssertTrue(why.contains("API cost"), why)
        }
    }

    /// Fails closed. Prose we cannot read is not a reading of zero.
    func testUnrecognisedOutputThrows() {
        XCTAssertThrowsError(try ClaudeUsageText.windows(in: "Hello! How can I help?", now: Date()))
    }

    /// Archived readings, the hover bands and the headline are all keyed by
    /// these ids, so they have to keep meaning what they meant when the numbers
    /// came from `/api/oauth/usage`.
    func testIDsSurviveTheMoveOffTheEndpoint() {
        XCTAssertEqual(ClaudeUsageText.id(forLabel: "Current session"), "session")
        XCTAssertEqual(ClaudeUsageText.id(forLabel: "Current week (all models)"), "weekly_all")
        XCTAssertEqual(ClaudeUsageText.id(forLabel: "Current week (Opus)"), "weekly_opus")
        XCTAssertEqual(ClaudeUsageText.id(forLabel: "Current week (Sonnet)"), "weekly_sonnet")
    }

    /// A model family nobody has heard of yet still gets a stable id rather
    /// than a position in the list.
    func testAnUnknownModelStillGetsAnIDAndALabel() {
        XCTAssertEqual(ClaudeUsageText.id(forLabel: "Current week (Fable)"), "weekly_fable")
        XCTAssertEqual(ClaudeUsageText.label(forID: "weekly_cowork"), "Cowork")
    }

    /// Session first, whatever order it was printed in — that is the order the
    /// frame draws.
    func testSessionSortsFirst() throws {
        let reversed = """
        Current week (all models): 49% used · resets Sep 15 at 10pm (Asia/Ulaanbaatar)
        Current session: 3% used · resets Sep 12 at 11:20pm (Asia/Ulaanbaatar)
        """
        let windows = try ClaudeUsageText.windows(in: reversed, now: now(2026, 9, 12),
                                                  calendar: ulaanbaatar)
        XCTAssertEqual(windows.map(\.id), ["session", "weekly_all"])
    }

    /// A line with no reset is still a reading — the percentage is the part the
    /// ring draws, and losing it because the countdown is missing would be
    /// throwing away the more important half.
    func testAWindowWithoutAResetStillCounts() throws {
        let windows = try ClaudeUsageText.windows(in: "Current session: 12% used",
                                                  now: Date(), calendar: ulaanbaatar)
        XCTAssertEqual(windows.count, 1)
        XCTAssertNil(windows[0].resetsAt)
        XCTAssertEqual(windows[0].usedFraction ?? -1, 0.12, accuracy: 0.0001)
    }
}

/// The JSON envelope `--output-format json` wraps the printout in.
final class ClaudeCLIEnvelopeTests: XCTestCase {
    private func envelope(_ json: String) -> Data { Data(json.utf8) }

    func testReadsTheResultOfALocalCommand() throws {
        let data = envelope(#"{"subtype":"success","result":"Current session: 4% used","local_command":"usage","type":"result"}"#)
        XCTAssertEqual(ClaudeCLI.result(inEnvelope: data), "Current session: 4% used")
    }

    /// The check that matters. Without `local_command`, a build that no longer
    /// recognises `/usage` would send the prompt to the model instead, and the
    /// reply — prose about limits — would be accepted as a usage report.
    func testAModelReplyIsNotAUsageReport() {
        let data = envelope(#"{"subtype":"success","result":"Your session limit resets at 11pm.","type":"result","num_turns":1}"#)
        XCTAssertNil(ClaudeCLI.result(inEnvelope: data))
    }

    func testFindsTheResultAmongOtherLines() throws {
        let data = envelope("""
        {"type":"system","subtype":"init"}
        {"type":"assistant","message":{}}
        {"result":"Current session: 9% used","local_command":"usage","type":"result"}
        """)
        XCTAssertEqual(ClaudeCLI.result(inEnvelope: data), "Current session: 9% used")
    }

    func testGarbageIsNotAnAnswer() {
        XCTAssertNil(ClaudeCLI.result(inEnvelope: envelope("command not found: claude")))
        XCTAssertNil(ClaudeCLI.result(inEnvelope: Data()))
    }

    /// The regression a live run caught: pointing `CLAUDE_CONFIG_DIR` at
    /// `~/.claude` looks like a no-op and is not. Claude Code keeps the default
    /// profile's account in `~/.claude.json`, beside the directory; naming the
    /// directory moves that lookup inside it, where there is no account — so it
    /// stops seeing the subscription and `/usage` answers with a cost summary
    /// instead of limits. The default profile must inherit no override at all.
    func testTheDefaultProfileOverridesNothing() {
        let home = URL(fileURLWithPath: "/Users/vinz")
        XCTAssertNil(ClaudeProfile.default(home: home).configDirectoryOverride)

        let work = ClaudeProfile(slug: "work",
                                 configDirectory: home.appendingPathComponent(".claude-work"))
        XCTAssertEqual(work.configDirectoryOverride, "/Users/vinz/.claude-work")
    }

    /// A GUI app inherits none of the shell's `PATH`, so every install location
    /// has to be named. The native install is what `claude install` writes and
    /// what most people now have, so it is looked for first.
    func testTheNativeInstallIsSearchedFirst() {
        let paths = ClaudeCLI.candidatePaths(home: "/Users/vinz").map(\.path)
        XCTAssertEqual(paths.first, "/Users/vinz/.local/bin/claude")
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/claude"))
        XCTAssertTrue(paths.contains("/usr/local/bin/claude"))
    }
}

/// The provider, with the process spawn stubbed out.
final class ClaudeCLIProviderTests: XCTestCase {
    private func provider(returning text: String) -> ClaudeCLIProvider {
        ClaudeCLIProvider(profile: .default(home: URL(fileURLWithPath: "/Users/vinz")),
                          readUsage: { _ in text })
    }

    func testBuildsAnOfficialSnapshotLedByTheSession() async throws {
        let snapshot = try await provider(returning: livePrintout).fetchSnapshot()
        XCTAssertEqual(snapshot.id, "claude")
        XCTAssertEqual(snapshot.fidelity, .official, "these are Anthropic's own numbers")
        XCTAssertEqual(snapshot.headlineID, "session")
        XCTAssertEqual(snapshot.headline?.id, "session")
        XCTAssertEqual(snapshot.windows.count, 3)
        XCTAssertEqual(snapshot.status, .ok)
    }

    /// Unlike Codex's rollout, `/usage` asks Anthropic on every run — so a
    /// reading that came back at all came back current, and there is no
    /// staleness to weigh.
    func testAReadingIsNeverBornStale() async throws {
        let snapshot = try await provider(returning: livePrintout).fetchSnapshot()
        XCTAssertFalse(snapshot.status.isStale)
    }

    /// The profile, not a guess at a keychain item name, is what selects the
    /// account — and it is passed through to whatever runs the CLI.
    func testTheProfileReachesTheReader() async throws {
        let work = ClaudeProfile(slug: "work",
                                 configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        let seen = UncheckedBox<String?>(nil)
        let provider = ClaudeCLIProvider(profile: work, readUsage: { profile in
            seen.value = profile.configDirectory.path
            return livePrintout
        })
        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(seen.value, "/Users/vinz/.claude-work")
        XCTAssertEqual(snapshot.id, "claude-work")
        XCTAssertEqual(snapshot.displayName, "Claude (work)")
    }

    func testAMissingCLISurfacesAsSomethingToFix() async {
        let provider = ClaudeCLIProvider(
            profile: .default(home: URL(fileURLWithPath: "/Users/vinz")),
            readUsage: { _ in throw UsageProviderError.unavailable("Claude Code's CLI wasn't found.") }
        )
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected the missing CLI to throw")
        } catch UsageProviderError.unavailable {
            // Expected.
        } catch {
            XCTFail("expected .unavailable, got \(error)")
        }
    }

    /// A tool we can no longer run is a number we can no longer re-read, so the
    /// remembered reading has to go rather than sit there dimmed for ever.
    @MainActor
    func testAnUnavailableToolDropsTheRememberedReading() {
        let status = UsageStore.statusForTesting(UsageProviderError.unavailable("not installed"))
        XCTAssertEqual(status, .unsupported("not installed"))
        XCTAssertTrue(UsageStore.supersedesHistory(status))
    }

    /// The sign-in route is guidance, not a window: Codenotch cannot sign
    /// anyone in, and the only honest instruction is the command that does.
    func testTheRouteNamesTheCommandThatSignsInThisProfile() {
        let work = ClaudeProfile(slug: "work",
                                 configDirectory: URL(fileURLWithPath: "/Users/vinz/.claude-work"))
        guard case .guidance(let text) = ClaudeCLIProvider(profile: work).signInRoute else {
            return XCTFail("a profile has no window to open")
        }
        XCTAssertTrue(text.contains("CLAUDE_CONFIG_DIR=") && text.contains(".claude-work claude"),
                      "plain `claude` signs the default profile in, not this one: \(text)")
    }
}

/// Whose readings these are, now that there is no token to ask.
final class ClaudeAccountFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeAccountFileTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ json: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
    }

    private let config = """
    { "oauthAccount": { "emailAddress": "vinz@example.com", "organizationType": "claude_max",
                        "accountUuid": "…" } }
    """

    /// The default profile keeps its config beside the directory, not inside it.
    func testReadsTheFileBesideTheDirectory() throws {
        let profile = ClaudeProfile(slug: nil, configDirectory: directory.appendingPathComponent(".claude"))
        try write(config, to: directory.appendingPathComponent(".claude.json"))

        let account = try XCTUnwrap(ClaudeAccountFile.account(for: profile))
        XCTAssertEqual(account.label, "vinz@example.com")
        XCTAssertEqual(account.plan, "max")
    }

    /// A `CLAUDE_CONFIG_DIR` profile keeps it within.
    func testReadsTheFileInsideTheDirectory() throws {
        let inside = directory.appendingPathComponent(".claude-work")
        let profile = ClaudeProfile(slug: "work", configDirectory: inside)
        try write(config, to: inside.appendingPathComponent(".claude.json"))

        let account = try XCTUnwrap(ClaudeAccountFile.account(for: profile))
        XCTAssertEqual(account.label, "vinz@example.com")
        XCTAssertEqual(account.source, "Claude Code in \(ClaudeProfile.tilde(inside.path))")
    }

    /// An address is worth more than the old token's plan-with-nobody-attached:
    /// a notch faithfully reporting somebody else's numbers is exactly what
    /// `ProviderAccount` exists to catch.
    func testNoFileMeansNoAccountRatherThanAWrongOne() {
        let profile = ClaudeProfile(slug: nil, configDirectory: directory.appendingPathComponent(".absent"))
        XCTAssertNil(ClaudeAccountFile.account(for: profile))
    }

    func testPlanNames() {
        XCTAssertEqual(ClaudeAccountFile.planName("claude_max"), "max")
        XCTAssertEqual(ClaudeAccountFile.planName("claude_pro"), "pro")
        XCTAssertNil(ClaudeAccountFile.planName(nil))
        XCTAssertNil(ClaudeAccountFile.planName(""))
        XCTAssertEqual(ClaudeAccountFile.planName("something_new"), "something new",
                       "an unrecognised plan shows as itself rather than vanishing")
    }
}

/// A reference box, so a stubbed closure can record what it was handed.
private final class UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
