import XCTest
import Sparkle
@testable import Codenotch

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
        XCTAssertEqual(windows[0].label, "Gemini Models")
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
    private func transcript(_ name: String, modified: Date) throws -> URL {
        let dir = root.appendingPathComponent("\(name)/.system_generated/logs")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("transcript.jsonl")
        try "{}".write(to: file, atomically: true, encoding: .utf8)
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

    /// The first run used to warn that macOS would ask for a saved login. It
    /// never will now, so the note promises that instead — but only that.
    ///
    /// The claim it must *not* make is the tempting one. "Never reads a saved
    /// login" is false while Cursor and GLM still borrow a key from a file, and
    /// a privacy promise that overstates by two rows is worse than none.
    func testTheFirstRunPromiseIsExactlyTrue() {
        let copy = SettingsView.privacyCopy
        XCTAssertTrue(copy.contains("never asks macOS for a saved login"))
        XCTAssertFalse(copy.lowercased().contains("always allow"),
                       "there is no keychain prompt left to explain")
        for borrower in ["Cursor", "GLM"] {
            XCTAssertTrue(copy.contains(borrower),
                          "\(borrower) still borrows a key and the note must say so")
        }
    }
}

/// Antigravity's port changes on every launch, so the bridge failing is a

/// The bridged flag has to outlive a quit.
///
/// `AppDelegate` builds a new provider on every launch. With the flag starting
/// at false, quitting with Antigravity closed meant the next launch took the
/// fallback branch and *succeeded* with a request count — which the store then
/// files as the last good reading, overwriting the archived percentage rather
/// than dimming it. The guard is only worth anything if it survives the quit.
final class BridgedStateTests: XCTestCase {
    private func archive(fidelity: Fidelity?) -> UsageArchive {
        let name = "BridgedStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let archive = UsageArchive(defaults: defaults)
        guard let fidelity else { return archive }
        archive.save([
            AntigravityProvider.providerID: (
                ProviderSnapshot(id: AntigravityProvider.providerID,
                                 displayName: "Antigravity", glyph: .antigravity,
                                 fidelity: fidelity, status: .ok,
                                 windows: [LimitWindow(id: "gemini-weekly",
                                                       label: "Weekly",
                                                       usedFraction: 0.31)]),
                Date()
            )
        ])
        return archive
    }

    /// A remembered percentage can only have come from the language server.
    func testAnOfficialReadingSaysItHasBridged() {
        XCTAssertTrue(AntigravityProvider.hasBridgedBefore(archive: archive(fidelity: .official)))
    }

    /// A remembered *count* does not: that is the fallback, and it says nothing
    /// about whether the server has ever answered.
    func testADerivedReadingDoesNot() {
        XCTAssertFalse(AntigravityProvider.hasBridgedBefore(archive: archive(fidelity: .derived)))
    }

    func testAnEmptyArchiveDoesNot() {
        XCTAssertFalse(AntigravityProvider.hasBridgedBefore(archive: archive(fidelity: nil)))
    }

    /// And the provider actually picks it up, rather than merely being able to.
    func testTheProviderStartsBridgedAfterARelaunch() async {
        let restarted = AntigravityProvider(archive: archive(fidelity: .official))
        let bridged = await restarted.everBridgedForTesting
        XCTAssertTrue(bridged, "a relaunch forgot that the server had answered")

        let fresh = AntigravityProvider(archive: archive(fidelity: nil))
        let neverBridged = await fresh.everBridgedForTesting
        XCTAssertFalse(neverBridged)
    }
}

/// routine event — the app was restarted, not the account lost.
@MainActor
final class AntigravityFallbackTests: XCTestCase {
    /// `notAnswering` is the store's word for "still true, just old", and
    /// it keeps the previous reading instead of discarding it. Anything that
    /// supersedes history would throw away the percentage.
    func testTheAwayStateKeepsTheLastReading() {
        let status = UsageStore.statusForTesting(UsageProviderError.notAnswering)
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



