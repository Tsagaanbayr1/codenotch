import XCTest
@testable import Codenotch

/// The token path of `ClaudeOAuthProvider`.
///
/// It had no tests at all — only the pure helpers (`backoff`, `retryAfter`) were
/// covered — which is how a back-off that re-stamped itself on every failed tick
/// shipped and locked the provider until the app was restarted.
///
/// Every assertion here is about one question: **after a failure, does the next
/// tick actually go and ask again?** Hence the counters. Asserting on the returned
/// error is not enough — the broken version returned exactly the right error while
/// never touching the keychain or the network.
final class ClaudeOAuthProviderTests: XCTestCase {

    // MARK: - Back-off against the refresh tick

    /// A window that opens in 15ms is open. Refusing it does not delay the
    /// fetch by 15ms — the caller is a timer, so it delays it by a whole
    /// refresh interval, and the server's 60s penalty becomes 120s.
    private func makeProvider(cli: ClaudeUsageCLI? = nil,
                              cliRefreshInterval: TimeInterval = 5 * 60,
                              profile: ClaudeProfile = .default(),
                              desktopCache: ClaudeDesktopUsageCache? = nil,
                              desktopFreshness: TimeInterval = 30 * 60,
                              desktopRescanInterval: TimeInterval = 5 * 60) -> ClaudeOAuthProvider {
        let name = "ClaudeOAuthProviderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)

        // Neither source is left to find the real thing. Allowed to, these
        // tests would answer off whatever Claude Code and Claude Desktop happen
        // to hold on the machine running them, and every assertion below would
        // depend on the developer's own setup rather than on the code.
        return ClaudeOAuthProvider(profile: profile,
                                   archive: UsageArchive(defaults: defaults),
                                   cli: cli,
                                   cliRefreshInterval: cliRefreshInterval,
                                   desktopCache: desktopCache,
                                   desktopFreshness: desktopFreshness,
                                   desktopRescanInterval: desktopRescanInterval)
    }

    // MARK: - The CLI path

    /// The point of the whole thing: when `claude "/usage"` answers, nothing
    /// asks macOS for a credential, because there is no longer any code that
    /// could: the token path is gone.
    func testTheCLIAnswersOnItsOwn() async throws {
        let provider = makeProvider(cli: Self.cli(answering: Self.cliUsage))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(snapshot.fidelity, .official)
    }

    /// A CLI that cannot answer used to fall through to the endpoint. There is
    /// nothing behind it now, so the refresh fails — and must fail *saying so*,
    /// rather than with a status that reads as "signed out" and sends someone
    /// to fix an account that is fine.
    func testAFailingCLILeavesNothingBehindIt() async throws {
        let provider = makeProvider(cli: Self.cli(answering: "Please run /login first"))

        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("a silent CLI should not produce a reading")
        } catch UsageProviderError.unavailable(let why) {
            XCTAssertTrue(why.contains("Claude Code"), why)
        }
    }

    /// The two situations have different remedies, so they must not share one
    /// sentence: installing what you already have is how a card stops being read.
    func testTheMissingSourceMessageNamesTheRightRemedy() {
        XCTAssertTrue(ClaudeOAuthProvider.noSourceMessage(hasCLI: false).contains("wasn't found"))
        XCTAssertTrue(ClaudeOAuthProvider.noSourceMessage(hasCLI: true).contains("sign in"))
    }

    /// `UsageStore` polls every 60s while a session is busy, and each ask is a
    /// subprocess. The windows do not move enough in a minute to be worth one.
    func testTheCLIIsNotSpawnedOnEveryTick() async throws {
        let spawns = Counter()
        let provider = makeProvider(cli: Self.cli { spawns.increment(); return Self.cliUsage })

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 1, "the CLI was spawned again inside its own interval")
    }

    /// And it is asked again once the interval has passed, or the ring would
    /// show one reading for the rest of the session.
    func testTheCLIIsAskedAgainOnceTheIntervalPasses() async throws {
        let spawns = Counter()
        let provider = makeProvider(cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    cliRefreshInterval: 0)

        _ = try await provider.fetchSnapshot()
        _ = try await provider.fetchSnapshot()

        XCTAssertEqual(spawns.value, 2)
    }

    // MARK: - The Claude Desktop cache path

    /// Why the whole source exists. On this machine `claude "/usage"` prints a
    /// cost summary and no windows at all, and the keychain token has not been
    /// re-minted since Claude Code last ran — so both existing paths fail while
    /// Claude Desktop sits there displaying the real numbers. Reading its cache
    /// has to be enough on its own, without a keychain read and without a request.
    func testAFreshDesktopSnapshotNeedsNoKeychainAndNoRequest() async throws {
        let provider = makeProvider(profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.status, .ok)
        XCTAssertEqual(snapshot.windows.map(\.id), ["session", "weekly_all"])
        XCTAssertEqual(snapshot.usedFraction, 0.30, "the headline is not Desktop's session window")
    }

    /// Desktop is preferred over the CLI, not merely over the token: it is the
    /// cheaper of the two and cannot be refused, and on the machine this was
    /// written for the CLI is the source that lies by omission.
    func testDesktopIsPreferredOverTheCLI() async throws {
        let spawns = Counter()
        let provider = makeProvider(cli: Self.cli { spawns.increment(); return Self.cliUsage },
                                    profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        // 30% is Desktop's; 38% would be the CLI's.
        XCTAssertEqual(snapshot.usedFraction, 0.30)
        XCTAssertEqual(spawns.value, 0, "a subprocess was spawned even though the cache answered")
    }

    /// The honesty requirement. Once Desktop stops updating, its numbers may not
    /// keep being presented as live — so a snapshot past the window is not
    /// returned at all, and the existing sources take over. Whatever the last
    /// good reading was is then `UsageStore`'s to re-show, dimmed and dated.
    func testAStaleDesktopSnapshotFallsThroughToTheExistingSources() async throws {
        let provider = makeProvider(profile: desktopProfile(),
                                    desktopCache: desktopCache(age: 4 * 3600))

        let snapshot = try await provider.fetchSnapshot()

        // The endpoint's fixture is 42%; Desktop's stale one is 30%.
        XCTAssertEqual(snapshot.usedFraction, 0.42, "a stale cache reading was shown as live")
    }

    /// Claude Desktop is signed into one account; Codenotch draws a ring per
    /// Claude Code profile. A profile whose organization does not match the
    /// cached URL gets nothing from Desktop — the alternative is the personal
    /// account's session percentage on the work ring.
    func testACacheForAnotherOrganizationIsNotUsed() async throws {
        let provider = makeProvider(
            profile: desktopProfile(organization: "99999999-8888-7777-6666-555555555555"),
            desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42, "another account's reading reached this ring")
    }

    /// A profile Claude Code has never signed in to has no organization to match
    /// on, and must not fall back to "whatever is in the cache".
    func testAProfileWithNoRecordedOrganizationIsNotMatched() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-nohome-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider(profile: .default(home: home),
                                    desktopCache: desktopCache(age: 0))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42)
    }

    /// With no Claude Desktop at all — no directory, nothing cached — the
    /// provider behaves exactly as it did before this source existed.
    func testNoDesktopCacheLeavesTheOldBehaviourIntact() async throws {
        let absent = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-absent-\(UUID().uuidString)", isDirectory: true)
        let provider = makeProvider(profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: absent))

        let snapshot = try await provider.fetchSnapshot()

        XCTAssertEqual(snapshot.usedFraction, 0.42)
    }

    /// `UsageStore` polls every 60s while a session is busy, and a miss means a
    /// scan of a few thousand directory entries. Missing once must not mean
    /// scanning on every tick afterwards.
    ///
    /// Asserted by behaviour rather than by counting: an entry that appears
    /// during the interval is not picked up, which is only true if no scan
    /// happened. It is also the cost of the throttle, stated plainly — a Desktop
    /// that has just started writing again waits out one interval.
    func testAMissSuppressesTheNextScan() async throws {
        let directory = makeCacheDirectory()
        let provider = makeProvider(profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory))

        // Nothing cached yet: a miss, which arms the throttle.
        _ = try await provider.fetchSnapshot()
        writeUsageEntry(into: directory, age: 0)

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction, 0.42, "the cache was rescanned inside the interval")
    }

    /// And the scan does happen once the interval has passed, or a Desktop that
    /// comes back would never be noticed.
    func testTheScanHappensAgainOnceTheIntervalPasses() async throws {
        let directory = makeCacheDirectory()
        let provider = makeProvider(profile: desktopProfile(),
                                    desktopCache: ClaudeDesktopUsageCache(directory: directory),
                                    desktopRescanInterval: 0)

        _ = try await provider.fetchSnapshot()
        writeUsageEntry(into: directory, age: 0)

        let snapshot = try await provider.fetchSnapshot()
        XCTAssertEqual(snapshot.usedFraction, 0.30, "the cache was never looked at again")
    }

    // MARK: - Desktop helpers

    /// A profile whose `.claude.json` records `organization`, so the provider has
    /// something to match a cache entry against. Nothing else about it is real.
    private func desktopProfile(
        organization: String = ClaudeDesktopUsageCacheTests.organization
    ) -> ClaudeProfile {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-home-\(UUID().uuidString)", isDirectory: true)
        let config = home.appendingPathComponent(".claude")
        try? FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        let json = #"{"oauthAccount":{"emailAddress":"someone@example.com","organizationUuid":"\#(organization)"}}"#
        try? Data(json.utf8).write(to: home.appendingPathComponent(".claude.json"))
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return .default(home: home)
    }

    /// A cache directory holding one usage entry, written `age` seconds ago.
    private func desktopCache(age: TimeInterval) -> ClaudeDesktopUsageCache {
        let directory = makeCacheDirectory()
        writeUsageEntry(into: directory, age: age)
        return ClaudeDesktopUsageCache(directory: directory)
    }

    /// An empty throwaway directory shaped like `Cache_Data`.
    private func makeCacheDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codenotch-cache-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func writeUsageEntry(into directory: URL, age: TimeInterval) {
        var entry = ClaudeDesktopUsageCacheTests.Entry()
        // No `Date:` header, so the entry's modification time is what dates it —
        // which is the half a test can control.
        entry.responseDate = nil
        let file = directory.appendingPathComponent("entry_0")
        try? entry.data().write(to: file)
        try? FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-age)], ofItemAtPath: file.path)
    }

    private static let cliUsage = """
    Current session: 38% used · resets Sep 7 at 2:59pm (Asia/Jakarta)
    Current week (all models): 4% used · resets Sep 14 at 5:59am (Asia/Jakarta)
    """

    private static func cli(answering text: String) -> ClaudeUsageCLI {
        cli { text }
    }

    private static func cli(_ answer: @escaping @Sendable () -> String) -> ClaudeUsageCLI {
        // The path is never run — `output` is what the provider reaches.
        ClaudeUsageCLI(binary: URL(fileURLWithPath: "/nonexistent/claude")) { _ in answer() }
    }

    private func assertNeedsAuth(from provider: ClaudeOAuthProvider,
                                 file: StaticString = #filePath,
                                 line: UInt = #line) async {
        do {
            _ = try await provider.fetchSnapshot()
            XCTFail("expected needsAuth, got a snapshot", file: file, line: line)
        } catch UsageProviderError.needsAuth {
            // expected
        } catch {
            XCTFail("expected needsAuth, got \(error)", file: file, line: line)
        }
    }
}

/// How many times the CLI was actually asked. "Did it spawn again?" is the
/// question the throttle exists to answer, and only a count answers it.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock(); count += 1; lock.unlock()
    }

    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}

/// `account()` answers from Claude Code's own config — a file that names the
/// signed-in address and holds no secret.
///
/// It used to read the keychain, which is what made a test unable to build a
/// real provider without touching the login keychain: on a test host rebuilt
/// with a fresh ad-hoc signature that means an authorization prompt, and a
/// prompt nobody answers hangs the whole suite. Now there is nothing to touch.
final class ClaudeAccountSourceTests: XCTestCase {
    private func provider(profile: ClaudeProfile) -> ClaudeOAuthProvider {
        let name = "ClaudeAccountSourceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return ClaudeOAuthProvider(profile: profile,
                                   archive: UsageArchive(defaults: defaults),
                                   cli: nil,
                                   desktopCache: nil)
    }

    /// A directory Claude Code has never signed in to has no address recorded,
    /// so there is no account to show — and, crucially, no crash and no prompt.
    func testADirectoryWithNoAccountIsNoAccount() throws {
        let empty = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ClaudeAccountSourceTests.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }

        let profile = ClaudeProfile(slug: "empty", configDirectory: empty)
        XCTAssertNil(provider(profile: profile).account())
    }
}
