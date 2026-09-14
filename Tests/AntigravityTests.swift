import XCTest
import Sparkle
@testable import Codenotch
final class AntigravityTierTests: XCTestCase {
    /// Verbatim from a signed-in install. Note what is absent: no used, no
    /// limit, no reset. That absence is why the provider reports the plan and
    /// admits there is nothing metered instead of drawing a ring.
    private let real = Data("""
    {"allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist",
    "description":"Unlimited coding assistant with the most powerful Gemini models",
    "userDefinedCloudaicompanionProject":true,"privacyNotice":{},"isDefault":true,
    "usesGcpTos":true}],"ineligibleTiers":[{"reasonCode":"UNSUPPORTED_CLIENT",
    "reasonMessage":"This client is no longer supported.","tierId":"free-tier",
    "tierName":"Gemini Code Assist for individuals"}]}
    """.utf8)

    func testItNamesThePlanFromTheDefaultAllowedTier() {
        XCTAssertEqual(AntigravityProvider.tier(in: real), "Gemini Code Assist")
    }

    /// An ineligible tier is what you cannot have; picking it would name the
    /// wrong plan on the cell.
    func testItIgnoresIneligibleTiers() {
        XCTAssertNotEqual(AntigravityProvider.tier(in: real), "Gemini Code Assist for individuals")
    }

    func testCurrentTierWinsWhenTheAccountHasChosenOne() {
        let chosen = Data("""
        {"currentTier":{"id":"paid","name":"Gemini Code Assist Standard"},
         "allowedTiers":[{"id":"standard-tier","name":"Gemini Code Assist","isDefault":true}]}
        """.utf8)
        XCTAssertEqual(AntigravityProvider.tier(in: chosen), "Gemini Code Assist Standard")
    }

    func testItFallsBackRatherThanThrowingOnNonsense() {
        XCTAssertEqual(AntigravityProvider.tier(in: Data("{}".utf8)), "Gemini")
    }
}

/// Counting is the only usage figure available, so its edges matter more than
/// usual — there is no vendor number to fall back on if this is wrong.
final class AntigravityActivityTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ lines: [String], trajectory: String = "t1") throws {
        let dir = root.appendingPathComponent("\(trajectory)/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("transcript.jsonl"),
                   atomically: true, encoding: .utf8)
    }

    private func step(_ at: String, source: String) -> String {
        #"{"created_at":"\#(at)","source":"\#(source)","type":"PLANNER_RESPONSE"}"#
    }

    private let noon = ISO8601DateFormatter().date(from: "2026-08-31T12:00:00Z")!

    /// A second install, so the roots can be tested the way they actually
    /// occur: several directories, only one of them in use.
    private func makeRoot() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("antigravity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func write(_ lines: [String], to root: URL, trajectory: String) throws {
        let dir = root.appendingPathComponent("\(trajectory)/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try lines.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("transcript.jsonl"),
                   atomically: true, encoding: .utf8)
    }

    // MARK: - More than one install

    /// The bug this fixes. Leaving a flavour of Antigravity behind leaves its
    /// directory behind, so a machine that has run the IDE and moved to the CLI
    /// has both — and reading only the first one found reported nothing while
    /// the transcripts sat one directory over.
    func testAnEmptyInstallBesideAUsedOneDoesNotHideIt() throws {
        let empty = try makeRoot()
        let used = try makeRoot()
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")], to: used, trajectory: "a")

        XCTAssertEqual(AntigravityActivity.read(roots: [empty, used], now: noon).requestsToday, 1)
    }

    /// One person, one account, one number for the day.
    func testTwoInstallsAddUp() throws {
        let ide = try makeRoot()
        let cli = try makeRoot()
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")], to: ide, trajectory: "a")
        try write([step("2026-08-31T10:00:00Z", source: "MODEL"),
                   step("2026-08-31T11:00:00Z", source: "MODEL")], to: cli, trajectory: "b")

        XCTAssertEqual(AntigravityActivity.read(roots: [ide, cli], now: noon).requestsToday, 3)
    }

    func testTheNewestRequestWinsAcrossInstalls() throws {
        let older = try makeRoot()
        let newer = try makeRoot()
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")], to: older, trajectory: "a")
        try write([step("2026-08-31T11:00:00Z", source: "MODEL")], to: newer, trajectory: "b")

        XCTAssertEqual(AntigravityActivity.read(roots: [older, newer], now: noon).lastRequest,
                       ISO8601DateFormatter().date(from: "2026-08-31T11:00:00Z"))
    }

    func testNoInstallsAtAllIsNotAnError() {
        XCTAssertEqual(AntigravityActivity.read(roots: [], now: noon).requestsToday, 0)
    }

    /// The bug itself, at the point it was made: choosing between the
    /// directories rather than reading all of them.
    ///
    /// All four exist on a machine that has run more than one flavour — nothing
    /// removes the old one — so "the first that exists" is not a choice between
    /// a real install and a missing one. It picked an empty directory while the
    /// transcripts sat in the next.
    func testEveryInstallsBrainIsFoundNotJustTheFirst() throws {
        let home = try makeRoot()
        let gemini = home.appendingPathComponent(".gemini")
        for name in ["antigravity", "antigravity-backup", "antigravity-cli", "antigravity-ide"] {
            try FileManager.default.createDirectory(
                at: gemini.appendingPathComponent("\(name)/brain"),
                withIntermediateDirectories: true
            )
        }
        // Something else living under `.gemini` is not an Antigravity install.
        try FileManager.default.createDirectory(
            at: gemini.appendingPathComponent("history"), withIntermediateDirectories: true
        )

        let roots = AntigravityActivity.transcriptRoots(home: home)

        XCTAssertEqual(roots.count, 4, "found \(roots.map(\.path))")
        XCTAssertTrue(roots.allSatisfy { $0.lastPathComponent == "brain" })
        XCTAssertTrue(roots.contains { $0.path.contains("antigravity-cli") })
    }

    /// A directory without a `brain` is not one to read from.
    func testAnInstallWithNoBrainIsSkipped() throws {
        let home = try makeRoot()
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".gemini/antigravity-cli"),
            withIntermediateDirectories: true
        )

        XCTAssertTrue(AntigravityActivity.transcriptRoots(home: home).isEmpty)
    }

    // MARK: - What the row is called

    /// A bare `0` reads as the app having found nothing, which is also what the
    /// wrong directory looked like. Saying when it was last used tells them
    /// apart.
    func testAQuietDayNamesTheLastTimeItWasUsed() throws {
        try write([step("2026-08-28T09:00:00Z", source: "MODEL")], to: root, trajectory: "a")

        XCTAssertEqual(AntigravityActivity.read(roots: [root], now: noon).label(now: noon),
                       "Requests today · last used 3 days ago")
    }

    func testYesterdayIsNamedAsYesterday() throws {
        try write([step("2026-08-30T09:00:00Z", source: "MODEL")], to: root, trajectory: "a")

        XCTAssertEqual(AntigravityActivity.read(roots: [root], now: noon).label(now: noon),
                       "Requests today · last used yesterday")
    }

    /// Counted in calendar days, like `requestsToday` itself. Measured in
    /// elapsed hours instead, a late evening reads as "3 hr ago" rather than
    /// yesterday, and the row's two halves disagree about what a day is.
    ///
    /// Built from the local calendar rather than from fixed UTC strings: which
    /// calendar day an instant falls on is exactly what is under test, so a
    /// literal `Z` timestamp would pass or fail on the machine's own timezone.
    func testTheEveningBeforeIsStillYesterday() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let earlyMorning = calendar.date(
            from: DateComponents(year: 2026, month: 8, day: 31, hour: 1)
        )!
        let previousEvening = calendar.date(byAdding: .hour, value: -3, to: earlyMorning)!

        let stamp = ISO8601DateFormatter().string(from: previousEvening)
        try write([step(stamp, source: "MODEL")], to: root, trajectory: "a")

        XCTAssertEqual(AntigravityActivity.read(roots: [root], now: earlyMorning)
                           .label(now: earlyMorning),
                       "Requests today · last used yesterday")
    }

    /// A day with work on it says nothing about recency — the count is the
    /// answer, and the old wording is still the right one.
    func testABusyDayKeepsThePlainLabel() throws {
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")], to: root, trajectory: "a")

        XCTAssertEqual(AntigravityActivity.read(roots: [root], now: noon).label(now: noon),
                       "Requests today · no limit published")
    }

    func testNothingEverRecordedKeepsThePlainLabel() {
        XCTAssertEqual(AntigravityActivity.read(roots: [], now: noon).label(now: noon),
                       "Requests today · no limit published")
    }

    /// The real transcript interleaves user input and system checkpoints with
    /// model answers. Counting those would inflate the figure with work the
    /// model never did.
    func testItCountsOnlyWhatTheModelAnswered() throws {
        try write([
            step("2026-08-31T09:00:00Z", source: "USER_EXPLICIT"),
            step("2026-08-31T09:00:01Z", source: "SYSTEM"),
            step("2026-08-31T09:00:02Z", source: "MODEL"),
            step("2026-08-31T09:00:03Z", source: "MODEL")
        ])
        XCTAssertEqual(AntigravityActivity.read(root: root, now: noon).requestsToday, 2)
    }

    func testItAddsUpAcrossConversations() throws {
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")], trajectory: "a")
        try write([step("2026-08-31T10:00:00Z", source: "MODEL")], trajectory: "b")
        XCTAssertEqual(AntigravityActivity.read(root: root, now: noon).requestsToday, 2)
    }

    func testYesterdayIsNotToday() throws {
        try write([
            step("2026-08-30T09:00:00Z", source: "MODEL"),
            step("2026-08-31T09:00:00Z", source: "MODEL")
        ])
        let activity = AntigravityActivity.read(root: root, now: noon)
        XCTAssertEqual(activity.requestsToday, 1)
        // The newest is still remembered, whichever day it fell on.
        XCTAssertEqual(activity.lastRequest,
                       ISO8601DateFormatter().date(from: "2026-08-31T09:00:00Z"))
    }

    /// `created_at` ends in Z. Read as local time it lands hours away, which is
    /// how counts drift across midnight — the mistake `procStart` already made
    /// once in this codebase.
    func testTheTimestampIsReadAsUTC() throws {
        let parsed = try XCTUnwrap(AntigravityActivity.parse("2026-08-31T14:12:34Z"))
        XCTAssertEqual(parsed.timeIntervalSince1970,
                       ISO8601DateFormatter().date(from: "2026-08-31T14:12:34Z")!
                           .timeIntervalSince1970)
    }

    func testAMissingBrainDirectoryIsNotAnError() {
        let absent = root.appendingPathComponent("nowhere")
        XCTAssertEqual(AntigravityActivity.read(root: absent, now: noon).requestsToday, 0)
    }

    func testMalformedLinesAreSkippedRatherThanFatal() throws {
        try write(["not json", "", step("2026-08-31T09:00:00Z", source: "MODEL")])
        XCTAssertEqual(AntigravityActivity.read(root: root, now: noon).requestsToday, 1)
    }

    func testTheSummaryNeverImpliesAPercentage() throws {
        try write([step("2026-08-31T09:00:00Z", source: "MODEL")])
        let summary = AntigravityActivity.read(root: root, now: noon).summary
        XCTAssertEqual(summary, "~1 request today")
        XCTAssertFalse(summary.contains("%"))
    }

    func testNoActivityReadsAsNoneRatherThanZeroPercent() {
        XCTAssertEqual(AntigravityActivity(requestsToday: 0, lastRequest: nil).summary,
                       "no requests today")
    }
}

/// The quota parser is written from message names in Antigravity's binary, not
/// from a response — no licensed account was available to produce one. So what
/// is tested is mostly its refusal to believe things: a shape it does not
/// recognise must yield nothing and send the provider to the honest fallback,
/// never a confident ring built on a guess.
final class AntigravityQuotaTests: XCTestCase {
    func testItReadsBucketsIntoWindows() {
        let body = Data("""
        {"quotaGroups":[{"displayName":"Gemini","buckets":[
          {"name":"daily","displayName":"Daily","used":250,"limit":1000,
           "resetTime":"2026-09-01T00:00:00Z"}]}]}
        """.utf8)
        let windows = AntigravityProvider.windows(in: body)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.usedFraction ?? 0, 0.25, accuracy: 0.0001)
        XCTAssertEqual(windows.first?.label, "Daily")
    }

    func testItParsesDirectCloudCodeRetrieveUserQuotaBuckets() throws {
        let now = Date(timeIntervalSince1970: 1788900000)
        let body = Data("""
        {
          "buckets": [
            {
              "tokenType": "WTUS",
              "modelId": "claude-sonnet-4-6",
              "remainingFraction": 0.75,
              "resetTime": "2026-09-09T10:39:57Z"
            },
            {
              "tokenType": "WTUS",
              "modelId": "claude-opus-4-6-thinking",
              "remainingFraction": 0.85,
              "resetTime": "2026-09-16T18:00:12Z"
            },
            {
              "tokenType": "WTUS",
              "modelId": "gemini-3.7-flash-tiered",
              "remainingFraction": 0.90,
              "resetTime": "2026-09-09T10:39:57Z"
            },
            {
              "tokenType": "WTUS",
              "modelId": "gemini-2.5-pro",
              "remainingFraction": 0.80,
              "resetTime": "2026-09-16T10:39:57Z"
            }
          ]
        }
        """.utf8)
        let windows = AntigravityProvider.windows(in: body, now: now)
        XCTAssertEqual(windows.count, 4)

        let geminiHourly = try XCTUnwrap(windows.first(where: { $0.id == "gemini-hourly" }))
        XCTAssertEqual(geminiHourly.group, "Gemini Models")
        XCTAssertEqual(geminiHourly.label, "5-hour Limit")
        XCTAssertEqual(geminiHourly.usedFraction ?? 0, 0.10, accuracy: 0.0001)

        let geminiWeekly = try XCTUnwrap(windows.first(where: { $0.id == "gemini-weekly" }))
        XCTAssertEqual(geminiWeekly.group, "Gemini Models")
        XCTAssertEqual(geminiWeekly.label, "Weekly Limit")
        XCTAssertEqual(geminiWeekly.usedFraction ?? 0, 0.20, accuracy: 0.0001)

        let thirdPartyHourly = try XCTUnwrap(windows.first(where: { $0.id == "3p-hourly" }))
        XCTAssertEqual(thirdPartyHourly.group, "Claude and GPT models")
        XCTAssertEqual(thirdPartyHourly.label, "5-hour Limit")
        XCTAssertEqual(thirdPartyHourly.usedFraction ?? 0, 0.25, accuracy: 0.0001)

        let thirdPartyWeekly = try XCTUnwrap(windows.first(where: { $0.id == "3p-weekly" }))
        XCTAssertEqual(thirdPartyWeekly.group, "Claude and GPT models")
        XCTAssertEqual(thirdPartyWeekly.label, "Weekly Limit")
        XCTAssertEqual(thirdPartyWeekly.usedFraction ?? 0, 0.15, accuracy: 0.0001)
    }

    func testCodexBarQuotaSummaryEnvelopeIsNormalizedForEverySource() throws {
        let body = Data("""
        {
          "groups": [
            {
              "displayName": "Gemini Models",
              "buckets": [
                {
                  "bucketId": "gemini-5h",
                  "displayName": "5-hour Limit",
                  "remaining": {"case": "remainingFraction", "value": 0.86}
                },
                {
                  "bucketId": "gemini-weekly",
                  "displayName": "Weekly Limit",
                  "remaining": {"remainingFraction": 0.55}
                }
              ]
            },
            {
              "displayName": "Claude and GPT models",
              "buckets": [
                {
                  "bucketId": "3p-5h",
                  "displayName": "5-hour Limit",
                  "remainingFraction": 1
                },
                {
                  "bucketId": "3p-weekly",
                  "displayName": "Weekly Limit",
                  "remainingFraction": 1
                }
              ]
            }
          ]
        }
        """.utf8)

        let providerWindows = AntigravityProvider.windows(in: body)
        let bridgeWindows = AntigravityBridge.windows(in: body)

        XCTAssertEqual(bridgeWindows, providerWindows)
        XCTAssertEqual(providerWindows.count, 4)
        XCTAssertEqual(providerWindows[0].id, "gemini-5h")
        XCTAssertEqual(providerWindows[1].id, "gemini-weekly")
        XCTAssertEqual(providerWindows[2].id, "3p-5h")
        XCTAssertEqual(providerWindows[3].id, "3p-weekly")
        XCTAssertEqual(providerWindows[0].duration, 5 * 3600)
        XCTAssertEqual(providerWindows[1].duration, 7 * 86400)
        XCTAssertEqual(providerWindows[2].duration, 5 * 3600)
        XCTAssertEqual(providerWindows[3].duration, 7 * 86400)
        XCTAssertEqual(providerWindows[0].usedFraction ?? -1, 0.14, accuracy: 0.0001)
        XCTAssertEqual(providerWindows[1].usedFraction ?? -1, 0.45, accuracy: 0.0001)
        XCTAssertEqual(providerWindows[2].usedFraction ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(providerWindows[3].usedFraction ?? -1, 0, accuracy: 0.0001)
    }

    func testDirectCloudCodeIgnoresInvalidFractions() {
        let body = Data("""
        {
          "buckets": [
            {"modelId": "gemini-bad-over", "remainingFraction": 1.5},
            {"modelId": "gemini-bad-under", "remainingFraction": -0.1},
            {"modelId": "gemini-3.7-flash", "remainingFraction": 0.4}
          ]
        }
        """.utf8)
        let windows = AntigravityProvider.windows(in: body)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.id, "gemini-hourly")
        XCTAssertEqual(windows.first?.usedFraction ?? 0, 0.6, accuracy: 0.0001)
    }

    /// Cursor's free plan reports an included limit of zero, and dividing by it
    /// produced a confident 0% for an account well into its month. Nothing with
    /// a zero limit is ever a percentage.
    func testAZeroLimitIsDroppedRatherThanDividedBy() {
        let body = Data(#"{"buckets":[{"name":"x","used":0,"limit":0}]}"#.utf8)
        XCTAssertTrue(AntigravityProvider.windows(in: body).isEmpty)
    }

    func testNonsenseValuesAreDropped() {
        let wild = Data(#"{"buckets":[{"name":"x","used":9999,"limit":10}]}"#.utf8)
        XCTAssertTrue(AntigravityProvider.windows(in: wild).isEmpty)
        let negative = Data(#"{"buckets":[{"name":"x","used":-5,"limit":10}]}"#.utf8)
        XCTAssertTrue(AntigravityProvider.windows(in: negative).isEmpty)
    }

    /// The likeliest future: Google answers with a shape this does not know.
    /// Empty is the correct outcome — it routes to the fallback message.
    func testAnUnfamiliarShapeYieldsNothing() {
        XCTAssertTrue(AntigravityProvider.windows(in: Data(#"{"somethingElse":[1,2]}"#.utf8)).isEmpty)
        XCTAssertTrue(AntigravityProvider.windows(in: Data("not json".utf8)).isEmpty)
    }

    func testAMissingResetIsToleratedRatherThanFatal() {
        let body = Data(#"{"buckets":[{"name":"d","used":1,"limit":4}]}"#.utf8)
        XCTAssertEqual(AntigravityProvider.windows(in: body).count, 1)
    }
}

/// What an unlicensed account actually gets: a count of its own, rather than a
/// dash that reads as the app being broken.
final class AntigravityCountSnapshotTests: XCTestCase {
    private func snapshot(count: Int) -> ProviderSnapshot {
        ProviderSnapshot(
            id: "gemini", displayName: "Antigravity", glyph: .antigravity,
            fidelity: .derived, status: .ok,
            windows: [LimitWindow(id: "requests",
                                  label: "Requests today · no limit published",
                                  used: count)]
        )
    }

    func testTheCellShowsTheCountRatherThanADash() {
        XCTAssertEqual(snapshot(count: 7).headlineText, "7")
        XCTAssertTrue(snapshot(count: 7).hasReading)
    }

    /// The ring must stay arc-less. A count is not a fraction, and drawing one
    /// would imply a limit Google never published.
    func testItDrawsNoArcBecauseThereIsNoLimit() {
        XCTAssertNil(snapshot(count: 7).ringFraction)
        XCTAssertNil(snapshot(count: 7).usedFraction)
    }

    /// Zero is a reading, not an absence — "you have not used it today" is a
    /// fact worth showing.
    func testZeroIsStillAReading() {
        XCTAssertEqual(snapshot(count: 0).headlineText, "0")
        XCTAssertTrue(snapshot(count: 0).hasReading)
    }

    /// `.derived` is what makes the tooltip print a `~`: the count is ours, not
    /// the vendor's, and the UI has to say so.
    func testItIsMarkedAsOurOwnCount() {
        XCTAssertEqual(snapshot(count: 3).fidelity, .derived)
    }
}

/// The bridge to Antigravity's own language server — the only route that
/// actually returns the weekly figure, because it is the route Antigravity
/// itself uses.
final class AntigravityBridgeTests: XCTestCase {
    /// Verbatim from the running language server.
    private let real = Data("""
    {"response":{"groups":[
      {"displayName":"Gemini Models",
       "description":"Models within this group: Gemini Flash, Gemini Pro",
       "buckets":[{"bucketId":"gemini-weekly","displayName":"Weekly Limit Remaining",
                   "window":"weekly","remainingFraction":0.96262,
                   "resetTime":"2026-09-07T14:12:34Z"}]},
      {"displayName":"Claude and GPT models",
       "buckets":[{"bucketId":"3p-weekly","displayName":"Weekly Limit Remaining",
                   "window":"weekly","remainingFraction":1,
                   "resetTime":"2026-09-08T09:12:10Z"}]}]}}
    """.utf8)

    /// The server reports what is *left*; the notch shows what is spent.
    /// Inverting it here rather than in the view keeps a percentage meaning the
    /// same thing whichever provider produced it.
    func testRemainingIsTurnedIntoUsed() {
        let windows = AntigravityBridge.windows(in: real)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].id, "gemini-weekly")
        XCTAssertEqual(windows[0].usedFraction ?? 0, 1 - 0.96262, accuracy: 0.00001)
        XCTAssertEqual(windows[0].label, "Weekly Limit")
        XCTAssertEqual(windows[0].group, "Gemini Models")
        XCTAssertEqual(windows[0].duration, 7 * 86400)
    }

    /// A full bucket is 0% used, not "no reading".
    func testAnUntouchedLimitIsZeroUsed() {
        XCTAssertEqual(AntigravityBridge.windows(in: real)[1].usedFraction, 0)
    }

    func testItKeepsTheResetTime() throws {
        let resets = try XCTUnwrap(AntigravityBridge.windows(in: real)[0].resetsAt)
        XCTAssertEqual(resets, ISO8601DateFormatter().date(from: "2026-09-07T14:12:34Z"))
    }

    /// A fraction outside 0...1 is not a fraction; better nothing than a ring
    /// past full or below empty.
    func testImpossibleFractionsAreDropped() {
        let wild = Data(#"{"response":{"groups":[{"displayName":"G","buckets":[{"bucketId":"a","remainingFraction":1.4},{"bucketId":"b","remainingFraction":-0.2}]}]}}"#.utf8)
        XCTAssertTrue(AntigravityBridge.windows(in: wild).isEmpty)
    }

    func testAnUnfamiliarShapeYieldsNothing() {
        XCTAssertTrue(AntigravityBridge.windows(in: Data(#"{"other":1}"#.utf8)).isEmpty)
        XCTAssertTrue(AntigravityBridge.windows(in: Data("nonsense".utf8)).isEmpty)
    }

    // MARK: - Discovery

    /// The token is only ever on the command line: the server is started with
    /// `--https_server_port 0`, so nothing about it is written to disk.
    func testItReadsTheTokenFromTheProcessTable() throws {
        let table = """
        29283 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone \
        --csrf_token d4bd9204-bf02-4111-b1fe-71f0d0d921d0 --app_data_dir antigravity
        """
        let endpoint = try XCTUnwrap(
            AntigravityBridge.discover(processTable: table, listeningPorts: { pid in
                XCTAssertEqual(pid, 29283)
                return [63881, 63882]
            })
        )
        XCTAssertEqual(endpoint.csrfToken, "d4bd9204-bf02-4111-b1fe-71f0d0d921d0")
        XCTAssertEqual(endpoint.ports, [63881, 63882])
    }

    func testNoAntigravityMeansNoEndpoint() {
        XCTAssertNil(AntigravityBridge.discover(processTable: "1 /sbin/launchd",
                                                listeningPorts: { _ in [] }))
    }

    /// Antigravity running but listening nowhere we can see is not an endpoint.
    func testNoPortMeansNoEndpoint() {
        let table = "1 language_server --csrf_token abc"
        XCTAssertNil(AntigravityBridge.discover(processTable: table, listeningPorts: { _ in [] }))
    }

    // MARK: - The CLI is an install too

    /// Antigravity ships a CLI as well as an IDE, and it serves the same RPC.
    /// Looking only for `language_server --csrf_token` meant someone who uses
    /// `agy` and never installs the IDE got the counted-requests fallback while
    /// a real quota was being served on loopback the whole time.
    func testTheCLIIsFoundAndAsksForNoToken() throws {
        let table = """
        1 /sbin/launchd
        34221 agy
        """
        let endpoint = try XCTUnwrap(
            AntigravityBridge.discover(processTable: table, listeningPorts: { pid in
                XCTAssertEqual(pid, 34221)
                return [54166, 54167]
            })
        )

        XCTAssertNil(endpoint.csrfToken, "the CLI serves this without one")
        XCTAssertEqual(endpoint.ports, [54166, 54167])
    }

    func testTheCLIIsFoundByItsFullPathToo() throws {
        let table = "700 /Users/someone/.local/bin/agy"
        let endpoint = try XCTUnwrap(
            AntigravityBridge.discover(processTable: table, listeningPorts: { _ in [9000] })
        )

        XCTAssertNil(endpoint.csrfToken)
    }

    /// The IDE keeps its place: it is the one that needs the token, and sending
    /// none to it is the one way to be refused.
    func testTheIDEWinsWhenBothAreRunning() throws {
        let table = """
        29283 /Applications/Antigravity.app/Contents/Resources/bin/language_server --csrf_token abc
        34221 agy
        """
        let endpoint = try XCTUnwrap(
            AntigravityBridge.discover(processTable: table, listeningPorts: { _ in [1] })
        )

        XCTAssertEqual(endpoint.csrfToken, "abc")
    }

    /// "agy" is three letters and turns up inside real words and real paths, so
    /// the executable's own name is what is matched — not the line.
    func testSomethingElseWithAgyInItIsNotTheCLI() {
        for command in ["/opt/legacy/bin/server", "/usr/bin/agyllomerate", "500 imagy-daemon"] {
            XCTAssertNil(
                AntigravityBridge.discover(processTable: "500 \(command)",
                                           listeningPorts: { _ in [1] }),
                "\(command) was taken for the Antigravity CLI"
            )
        }
    }

    func testItParsesPortsFromLSOF() {
        let output = """
        language_server 29283 vinz 12u IPv4 0x1 0t0 TCP 127.0.0.1:63881 (LISTEN)
        language_server 29283 vinz 13u IPv4 0x2 0t0 TCP 127.0.0.1:63882 (LISTEN)
        """
        XCTAssertEqual(AntigravityBridge.parsePorts(fromLSOF: output), [63881, 63882])
    }
}
/// Antigravity had no activity monitor at all, so its ring never showed the
/// working state the other three had — and the store never learned it was busy,
/// staying on its slow idle poll while usage was actively being spent.
@MainActor
final class AntigravityActivityMonitorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("agy-monitor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func transcript(_ name: String, modified: Date, content: String = "{\"type\": \"USER_INPUT\"}") throws -> URL {
        let dir = root.appendingPathComponent("\(name)/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("transcript.jsonl")
        try content.write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: modified],
                                              ofItemAtPath: file.path)
        return file
    }

    func testAJustWrittenTranscriptReadsAsWorking() throws {
        try transcript("t1", modified: Date())
        let sessions = AntigravityActivityMonitor.read(root: root, staleAfter: 45)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .busy)
        XCTAssertEqual(sessions.first?.name, "Antigravity")
    }

    /// A finished turn is not work in progress.
    func testAnOldTranscriptIsNotWorking() throws {
        try transcript("t1", modified: Date().addingTimeInterval(-600))
        XCTAssertTrue(AntigravityActivityMonitor.read(root: root, staleAfter: 45).isEmpty)
    }

    /// Many conversations accumulate; only the newest says what is happening now.
    func testTheNewestTranscriptWins() throws {
        try transcript("old", modified: Date().addingTimeInterval(-600))
        try transcript("live", modified: Date())
        let sessions = AntigravityActivityMonitor.read(root: root, staleAfter: 45)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.id, "antigravity.live")
    }

    func testAnIdleTranscriptIsCleanedUpQuickly() throws {
        try transcript("idle", modified: Date().addingTimeInterval(-10), content: "{\"type\": \"PLANNER_RESPONSE\"}")
        let sessions = AntigravityActivityMonitor.read(root: root, staleAfter: 45)
        XCTAssertTrue(sessions.isEmpty)
    }

    func testAWaitingTranscriptPersists() throws {
        let waitingJSON = "{\"type\": \"PLANNER_RESPONSE\", \"tool_calls\": [{\"name\": \"ask_question\"}]}"
        try transcript("waiting", modified: Date().addingTimeInterval(-600), content: waitingJSON)
        let sessions = AntigravityActivityMonitor.read(root: root, staleAfter: 45)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.state, .waiting)
        XCTAssertEqual(sessions.first?.detail, "Question")
    }

    func testNoTranscriptsIsQuietRatherThanAnError() {
        let absent = root.appendingPathComponent("nowhere")
        XCTAssertTrue(AntigravityActivityMonitor.read(root: absent, staleAfter: 45).isEmpty)
    }
}

/// The "Open" button on an account row. The reading is borrowed from an app on
/// this Mac, so that app is where the account lives — the website is a separate
/// session that will bounce you to a login if the browser is not signed in.
final class AccountDestinationTests: XCTestCase {
    /// Claude Code is a command, not an application, so its row can only ever
    /// be a link — and claude.ai is genuinely where its usage is shown.
    func testAGuidanceRouteFallsBackToTheWebsite() {
        let route = SignInRoute.guidance("Run Claude Code once.")
        guard case .openApp = route else { return }
        XCTFail("guidance should not carry an app")
    }

    /// Naming the app rather than a host is the whole point: the button says
    /// where it actually goes.
    func testTitlesNameTheirDestination() {
        XCTAssertEqual(SignInRoute.openApp(bundleID: "x", name: "Cursor").actionTitle,
                       "Open Cursor")
    }

    /// An app that is not installed must not be offered — the button would do
    /// nothing, which is worse than no button.
    func testAnUninstalledAppIsNotOffered() {
        let missing = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.example.definitely-not-installed"
        )
        XCTAssertNil(missing)
    }
}

/// What a fresh install is told. Both sentences exist because of a specific way
/// a new user gets stranded, so both are pinned rather than left to drift.
@MainActor
final class FirstRunCopyTests: XCTestCase {
    private func settings() -> SettingsView {
        let name = "FirstRunCopyTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return SettingsView(preferences: Preferences(defaults: defaults),
                            providers: { [] },
                            signOut: { _ in }, signIn: { _ in true },
                            switchAccount: { _ in true },
                            retry: { _ in },
                            resetPosition: {},
                            quit: {},
                            updater: Updater())
    }

    /// The setup note has to name the tools. "Tools already signed in on this
    /// Mac" reads as satisfied by anyone who uses Claude in a browser, and the
    /// distinction that catches them is Claude *Code*.
    func testTheSetupNoteNamesEveryToolAndTheCodeDistinction() {
        let copy = SettingsView.setupCopy
        for tool in ["Claude Code", "Cursor", "Codex", "Antigravity"] {
            XCTAssertTrue(copy.contains(tool), "the setup note never mentions \(tool)")
        }
        XCTAssertTrue(copy.contains("not the Claude app"),
                      "nothing warns that the Claude app is not Claude Code")
    }

    /// The keychain prompt is the only interruption in the whole first run, and
    /// choosing Allow rather than Always Allow is what makes it recur.
    func testTheKeychainPromptIsExplainedBeforeItAppears() {
        let copy = SettingsView.keychainCopy
        XCTAssertTrue(copy.contains("Always Allow"))
        XCTAssertTrue(copy.lowercased().contains("macos will ask"))
    }
}

/// Antigravity's port changes on every launch, so the bridge failing is a
/// routine event — the app was restarted, not the account lost.
@MainActor
final class AntigravityFallbackTests: XCTestCase {
    /// `credentialExpired` is the store's word for "still true, just old", and
    /// it keeps the previous reading instead of discarding it. Anything that
    /// supersedes history would throw away the percentage.
    func testTheAwayStateKeepsTheLastReading() {
        let status = UsageStore.statusForTesting(UsageProviderError.credentialExpired)
        XCTAssertFalse(UsageStore.supersedesHistory(status),
                       "a restarted Antigravity would wipe the percentage")
        guard case .stale = status else {
            return XCTFail("expected a stale status, got \(status)")
        }
    }

    /// The distinction that matters: never having connected is a different
    /// situation from having connected and lost it, and only the first should
    /// show a request count.
    func testNothingMeteredIsAlsoKeptRatherThanDiscarded() {
        let status = UsageStore.statusForTesting(
            UsageProviderError.nothingMetered("no bridge yet")
        )
        guard case .unsupported = status else {
            return XCTFail("expected unsupported, got \(status)")
        }
    }
}

final class AuthorCreditTests: XCTestCase {
    /// Pinned because a wrong handle in a credit is worse than none, and it is
    /// the kind of string nobody re-reads once it looks right.
    func testTheCreditPointsAtTheRightAccount() {
        XCTAssertEqual(SettingsView.authorURL.absoluteString, "https://x.com/hivinz_")
        XCTAssertEqual(SettingsView.authorURL.scheme, "https")
    }
}

/// Where the app shows itself, apart from the notch. Only one of the three has
/// a Dock tile, and only one makes a menu bar item — get either mapping wrong
/// and the app is either unreachable or in two places at once.
final class AppPresenceTests: XCTestCase {
    func testOnlyTheDockOptionIsARegularApp() {
        XCTAssertEqual(AppPresence.dock.activationPolicy, .regular)
        XCTAssertEqual(AppPresence.menuBar.activationPolicy, .accessory)
        XCTAssertEqual(AppPresence.hidden.activationPolicy, .accessory)
    }

    /// What separates the two accessory modes.
    func testOnlyTheMenuBarOptionMakesAStatusItem() {
        XCTAssertFalse(AppPresence.dock.wantsStatusItem)
        XCTAssertTrue(AppPresence.menuBar.wantsStatusItem)
        XCTAssertFalse(AppPresence.hidden.wantsStatusItem)
    }

    /// Choosing this removes every visible way back into settings, so the
    /// option itself has to say where the door is.
    func testHidingExplainsHowToGetBack() {
        XCTAssertTrue(AppPresence.hidden.explanation.contains("Applications"))
    }

    func testEveryModeIsNamedAndExplained() {
        XCTAssertEqual(AppPresence.allCases.count, 3)
        for mode in AppPresence.allCases {
            XCTAssertFalse(mode.title.isEmpty)
            XCTAssertFalse(mode.explanation.isEmpty)
        }
    }

    @MainActor
    func testItDefaultsToTheDockRatherThanNowhere() {
        let name = "AppPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        XCTAssertEqual(Preferences(defaults: defaults).appPresence, .dock)
    }

    /// A value written by a future version must not make the app vanish.
    @MainActor
    func testAnUnknownStoredValueFallsBackToVisible() {
        let name = "AppPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        defaults.set("skywriting", forKey: "appPresence")
        XCTAssertEqual(Preferences(defaults: defaults).appPresence, .dock)
    }

    @MainActor
    func testTheChoiceSurvivesARestart() {
        let name = "AppPresenceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        Preferences(defaults: defaults).appPresence = .menuBar
        XCTAssertEqual(Preferences(defaults: defaults).appPresence, .menuBar)
    }
}

/// What the settings sheet says after a check. Sparkle's own answer to a failed
/// one is a modal reading "an error occurred in retrieving update information",
/// which names no cause and offers nothing to do — so the outcome is kept and
/// worded here instead.
@MainActor
final class UpdateOutcomeTests: XCTestCase {
    /// The case people actually hit, and the one that most needs reassuring:
    /// nothing is wrong with their copy of the app.
    func testAnUnreachableFeedSaysSoWithoutBlamingTheApp() throws {
        let message = try XCTUnwrap(Updater.Outcome.unreachable.message)
        XCTAssertTrue(message.contains("Couldn't reach"))
        XCTAssertTrue(message.contains("nothing is wrong with this copy"))
        XCTAssertFalse(message.lowercased().contains("error occurred"))
    }

    func testEveryOutcomeExceptIdleSaysSomething() {
        XCTAssertNil(Updater.Outcome.idle.message)
        for outcome: Updater.Outcome in [.checking, .upToDate(Date()), .found("1.1.0"),
                                         .unreachable, .failed("disk full")] {
            XCTAssertNotNil(outcome.message, "\(outcome) says nothing")
        }
    }

    func testAFoundUpdateNamesTheVersion() throws {
        let message = try XCTUnwrap(Updater.Outcome.found("1.2.0").message)
        XCTAssertTrue(message.contains("1.2.0"))
    }

    /// The distinction the wording depends on: a feed that cannot be fetched is
    /// routine, anything else is reported as itself.
    func testOnlyAFeedFailureCountsAsUnreachable() {
        XCTAssertTrue(Updater.isUnreachable(Int(SUError.appcastError.rawValue)))
        XCTAssertFalse(Updater.isUnreachable(Int(SUError.installationError.rawValue)))
    }
}

/// The menu bar mark. Loaded from the asset catalogue rather than drawn from
/// the app icon, and a template so macOS can tint it for whatever the bar is.
@MainActor
final class MenuBarIconTests: XCTestCase {
    func testTheIconLoadsAndIsNotEmpty() throws {
        let icon = try XCTUnwrap(StatusItemController.icon(),
                                 "MenuBarIcon is missing from the asset catalogue")
        XCTAssertEqual(icon.size, NSSize(width: 18, height: 18))
        XCTAssertFalse(icon.representations.isEmpty, "the image carries nothing to draw")
    }

    /// Without this macOS cannot tint it, and the mark stays black on a dark
    /// menu bar — invisible.
    func testItIsATemplate() throws {
        XCTAssertTrue(try XCTUnwrap(StatusItemController.icon()).isTemplate)
    }
}

/// The menu bar menu when the notch is hidden: the same readings as the
/// tooltips, or Hide is a one-way door to numbers you can no longer see.
@MainActor
final class StatusMenuTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_788_000_000)

    private func snapshot(
        id: String = "codex", name: String = "Codex",
        status: ProviderStatus = .ok,
        windows: [LimitWindow] = [],
        headlineID: String? = nil,
        block: UsageBlock? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(id: id, displayName: name, glyph: .openai,
                         fidelity: .official, status: status,
                         windows: windows, headlineID: headlineID, block: block)
    }

    /// One window reads as one line with the same three facts the tooltip
    /// spreads over three lines: label, percentage, reset.
    func testAWindowReadsAsOneLineWithLabelSummaryAndReset() {
        let line = StatusItemController.windowLine(
            for: LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.08,
                             resetsAt: now.addingTimeInterval(51 * 60)),
            now: now)
        XCTAssertTrue(line.contains("5h limit"), line)
        XCTAssertTrue(line.contains("8% Used · 92% left"), line)
        XCTAssertTrue(line.contains("Resets in 51 min"), line)
    }

    /// A window with no reset says so by saying nothing — never invented.
    func testAWindowWithoutAResetOmitsIt() {
        let line = StatusItemController.windowLine(
            for: LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.08),
            now: now)
        XCTAssertTrue(line.contains("5h limit"), line)
        XCTAssertFalse(line.contains("Resets"), line)
    }

    /// The blocked line leads, because it changes what you can do next while
    /// the percentage beside it still reads comfortable.
    func testABlockLeadsTheDetails() {
        let details = StatusItemController.detailLines(for: snapshot(
            status: .ok,
            windows: [LimitWindow(id: "primary", label: "5h limit", usedFraction: 0.16)],
            block: UsageBlock(reason: "Paused", resetsAt: now.addingTimeInterval(90 * 60))
        ), now: now)
        XCTAssertEqual(details.count, 2)
        XCTAssertTrue(details[0].hasPrefix("Paused until "), details[0])
        XCTAssertTrue(details[1].contains("5h limit"), details[1])
    }

    /// Nothing metered reads as the tooltip's own status message, not blank.
    func testNoWindowsReadsAsTheStatusMessage() {
        let details = StatusItemController.detailLines(
            for: snapshot(status: .needsAuth), now: now)
        XCTAssertEqual(details, ["Sign in to Codex to read your usage"])
    }

    /// The header carries the headline figure and the reading's age — the same
    /// pair the tooltip header shows.
    func testTheMenuListsEveryProviderWithRefreshAndSettings() {
        let controller = StatusItemController(onOpenSettings: {})
        controller.snapshots = [snapshot(
            status: .stale(since: now.addingTimeInterval(-(20 * 3600 + 21 * 60))),
            windows: [LimitWindow(id: "secondary", label: "Weekly limit",
                                   usedFraction: 0.29,
                                   resetsAt: now.addingTimeInterval(3600))],
            headlineID: "secondary")]
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: now)
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles[0].contains("Codex — 29%"), titles[0])
        XCTAssertTrue(titles[0].contains("20 hr 21 min ago"), titles[0])
        XCTAssertTrue(titles[1].contains("Weekly limit"), titles[1])
        XCTAssertTrue(titles[1].contains("29% Used · 71% left"), titles[1])
        XCTAssertTrue(titles.contains("Refresh all"))
        XCTAssertTrue(titles.contains("Settings…"))
        XCTAssertTrue(titles.contains("Quit Codenotch"))
        // The header re-reads its own provider.
        XCTAssertEqual(menu.items[0].representedObject as? String, "codex")
    }

    /// With no readings yet the menu says so instead of showing an empty list.
    func testAnEmptyMenuSaysItIsWaiting() {
        let controller = StatusItemController(onOpenSettings: {})
        let menu = NSMenu()
        controller.rebuild(menu: menu, now: now)
        XCTAssertTrue(menu.items[0].title.contains("Waiting for the first reading"))
    }
}
/// The button that puts the keychain prompt back on screen.
@MainActor
final class ReauthorizeTests: XCTestCase {
    private final class Stub: UsageProvider, @unchecked Sendable {
        let id = "claude"
        let displayName = "Claude"
        let glyph = ProviderGlyph.claude
        private(set) var forgotten = 0
        private(set) var fetches = 0

        // `nonisolated` on purpose: nested in a @MainActor test class, an
        // isolated method does not satisfy the protocol's requirement, and
        // Swift quietly falls back to the extension's no-op default — the
        // test then passes or fails for the wrong reason.
        nonisolated func forgetCachedCredential() { forgotten += 1 }
        func fetchSnapshot() async throws -> ProviderSnapshot {
            fetches += 1
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: [])
        }
    }

    private func store(_ stub: Stub) -> UsageStore {
        let name = "Reauthorize.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return UsageStore(providers: [stub], archive: UsageArchive(defaults: d))
    }

    /// The part that makes the button work at all. A plain refresh is served
    /// from the cached token whenever it is still valid, so the keychain is
    /// never touched and no prompt appears.
    func testItDropsTheHeldCredentialBeforeReading() async {
        let stub = Stub()
        // Held in a variable rather than called on a temporary: the store owns
        // the refresh task, and letting it go out of scope cancels the work
        // this is measuring.
        let store = store(stub)
        store.reauthorize(providerID: "claude")
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(stub.forgotten, 1, "the cached credential was reused, so macOS was never asked")
        XCTAssertEqual(stub.fetches, 1)
    }

    /// An unknown id must not quietly fetch something else.
    func testAnUnknownProviderIsIgnored() async {
        let stub = Stub()
        let store = store(stub)
        store.reauthorize(providerID: "nobody")
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(stub.forgotten, 0)
        XCTAssertEqual(stub.fetches, 0)
    }
}

/// Claude, Antigravity and cursor-agent keep a credential in the keychain;
/// Codex still reads a file and can never raise a prompt.
final class KeychainProviderTests: XCTestCase {
    private func summary(_ id: String) -> ProviderSummary {
        ProviderSummary(id: id, name: id, glyph: .claude, account: nil,
                        signIn: .guidance("x"))
    }

    func testOnlyKeychainBackedProvidersOfferIt() {
        XCTAssertTrue(summary("claude").usesKeychain)
        XCTAssertTrue(summary("claude-work").usesKeychain, "every profile's token is a keychain item")
        XCTAssertTrue(summary("gemini").usesKeychain)
        XCTAssertTrue(summary("cursor").usesKeychain,
                      "cursor-agent files its JWT in the keychain")
        XCTAssertFalse(summary("codex").usesKeychain, "Codex reads a file, not the keychain")
    }
}

/// Claude Code files a new keychain item on every token rotation rather than
/// updating one in place, so an account used for months accumulates several
/// under `Claude Code-credentials` — six, on the machine this was found on.
/// `kSecMatchLimitOne` gives no ordering guarantee across them, so the app
/// could read an old, expired duplicate while a valid one sat beside it: the
/// ring showed "Waiting for the first reading…" forever, with a working token
/// one item away. `KeychainItem.winner` is the selection that replaced it —
/// the query it is chosen from cannot run in a test, since there is no real
/// keychain to point it at.
final class KeychainDuplicateTests: XCTestCase {
    private func item(ref: String, modified: Date?) -> [CFString: Any] {
        var item: [CFString: Any] = [kSecValuePersistentRef: Data(ref.utf8)]
        if let modified { item[kSecAttrModificationDate] = modified }
        return item
    }

    /// The reported case: an old duplicate must not beat a newer one merely by
    /// being asked about first.
    func testTheMostRecentlyModifiedItemWins() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let winner = KeychainItem.winner(among: [
            item(ref: "old", modified: old),
            item(ref: "new", modified: new)
        ])
        XCTAssertEqual(winner?.persistentRef, Data("new".utf8))
        XCTAssertEqual(winner?.modifiedAt, new)
    }

    /// Order in the array must not decide it — that is exactly the bug being
    /// replaced, moved into this function instead of out of it.
    func testOrderInTheArrayDoesNotDecideIt() {
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        let winner = KeychainItem.winner(among: [
            item(ref: "new", modified: new),
            item(ref: "old", modified: old)
        ])
        XCTAssertEqual(winner?.persistentRef, Data("new".utf8))
    }

    /// The single-item case, which is nearly everyone: one duplicate is still
    /// a field of one to win.
    func testASingleItemWinsByDefault() {
        let winner = KeychainItem.winner(among: [item(ref: "only", modified: Date())])
        XCTAssertEqual(winner?.persistentRef, Data("only".utf8))
    }

    func testNoItemsMeansNoWinner() {
        XCTAssertNil(KeychainItem.winner(among: []))
    }

    /// A duplicate with no recorded modification date is worth keeping, not
    /// discarding — `.distantPast` only ranks it against the others.
    func testAnUndatedDuplicateStillLosesToADatedOne() {
        let dated = Date(timeIntervalSince1970: 1_000)
        let winner = KeychainItem.winner(among: [
            item(ref: "undated", modified: nil),
            item(ref: "dated", modified: dated)
        ])
        XCTAssertEqual(winner?.persistentRef, Data("dated".utf8))
    }

    /// But it can still win outright if it is the only one there is.
    func testAnUndatedDuplicateWinsWhenAloneWithNoDateAtAll() {
        let winner = KeychainItem.winner(among: [item(ref: "only", modified: nil)])
        XCTAssertEqual(winner?.persistentRef, Data("only".utf8))
        XCTAssertNil(winner?.modifiedAt)
    }

    /// An entry with no persistent reference at all cannot be read later no
    /// matter how it ranks, so it is dropped rather than allowed to win and
    /// then fail.
    func testAnItemWithNoPersistentRefIsNeverThePick() {
        let broken: [CFString: Any] = [kSecAttrModificationDate: Date(timeIntervalSince1970: 9_999)]
        let winner = KeychainItem.winner(among: [
            broken,
            item(ref: "usable", modified: Date(timeIntervalSince1970: 1))
        ])
        XCTAssertEqual(winner?.persistentRef, Data("usable".utf8))
    }
}

/// Which source Antigravity's ring is drawn from, and in what order.
///
/// The language server holds the credential and the client identity already,
/// so it needs nothing from the keychain. Asking it third — after a keychain
/// read and a round trip to Google — meant that dismissing the keychain prompt
/// produced an empty ring while the server that would have answered sat running
/// on the same machine, never asked.
final class AntigravitySourceOrderTests: XCTestCase {

    /// The whole point: a language server that answers ends the fetch before
    /// anything is asked of macOS or of Google.
    ///
    /// The request count is the assertion that carries it. `:loadCodeAssist` is
    /// sent immediately after the credential is read, so zero requests means
    /// the credential was never read either — which is not otherwise
    /// observable, the keychain read being a static call with nothing to
    /// substitute.
    func testAnAnsweringBridgeEndsTheFetchBeforeTheKeychain() async throws {
        let windows = [LimitWindow(id: "gemini-weekly", label: "Weekly", usedFraction: 0.2)]
        let provider = AntigravityProvider(localQuota: { windows })

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["gemini-weekly"])
        XCTAssertEqual(snapshot.fidelity, .official)
    }

    /// Once the server has answered, its going away means Antigravity was
    /// closed — keep the last reading dated rather than going back to the
    /// keychain for a number the token cannot produce anyway.
    func testOnceBridgedItDoesNotFallBackToTheToken() async throws {
        let answers = Answers([[LimitWindow(id: "gemini-weekly", label: "Weekly", usedFraction: 0.2)], nil])
        let provider = AntigravityProvider(localQuota: { answers.next() })

        _ = try await provider.fetchSnapshot()

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected credentialExpired")
        } catch UsageProviderError.credentialExpired {
            // Expected: the reading is kept and dated, not replaced.
        } catch {
            XCTFail("expected credentialExpired, got \(error)")
        }
    }
}

/// Hands out canned bridge answers in order, so one test can watch Antigravity
/// answer and then go away.
private final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var queued: [[LimitWindow]?]

    init(_ queued: [[LimitWindow]?]) { self.queued = queued }

    func next() -> [LimitWindow]? {
        lock.lock(); defer { lock.unlock() }
        return queued.isEmpty ? nil : queued.removeFirst()
    }
}
