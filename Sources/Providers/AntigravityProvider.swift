import Foundation
import os

/// Gemini, as Antigravity sees it.
///
/// **Everything here is local.** This used to read Antigravity's OAuth token
/// out of the login keychain and call Google with it. It no longer reads any
/// credential at all — the last one in the app — so nothing Codenotch does can
/// raise a keychain prompt, and there is no secret of anyone else's in this
/// process.
///
/// What replaces it is what was already the *preferred* source: Antigravity's
/// own language server, running on this machine, which holds the credential and
/// the client identity Google insists on and answers with the same figure
/// Antigravity's own panel shows. See `AntigravityBridge` — Antigravity does
/// not call Google for this either.
///
/// What that costs is the direct `:retrieveUserQuotaSummary` call, which needed
/// the token and only ever answered for a licensed account; the language server
/// outranked it whenever both could answer. Where neither can, the honest
/// remainder is a local request *count* — never a percentage, because Google
/// publishes no limit to divide by, and a confident 0% is worse than an
/// admitted blank in something people pay for.
actor AntigravityProvider: UsageProvider {
    // The id stays `gemini`: it keys the archive and the user's connection
    // choice, and changing it would silently discard both.
    nonisolated static let providerID = "gemini"
    nonisolated let id = AntigravityProvider.providerID
    nonisolated let displayName = "Antigravity"
    nonisolated let glyph = ProviderGlyph.antigravity

    /// Trusts loopback only. It is the sole network session this provider has,
    /// and it never leaves the machine.
    private let localSession: URLSession
    /// Re-discovering the port and token means spawning `ps` and `lsof`, which
    /// is not something to do every minute. Cached until it stops working.
    private var bridge: AntigravityBridge.Endpoint?
    /// Whether the language server has ever answered.
    ///
    /// Once it has, a failure is Antigravity being closed or restarted — its
    /// port changes every launch — not an account that cannot be read. Falling
    /// back to the request count then *replaces* a percentage with a plain
    /// number, and a ring that reads 8% one minute and 31 the next looks broken
    /// rather than degraded.
    private var everBridged: Bool

    init(archive: UsageArchive = UsageArchive()) {
        self.localSession = URLSession(configuration: .ephemeral,
                                       delegate: LocalhostTrust(),
                                       delegateQueue: nil)
        // Picked back up from the archive, not started at false.
        //
        // The app builds a new provider on every launch, so a flag that begins
        // false forgets — every time — that the language server has ever
        // answered. Quit with Antigravity closed and the next launch takes the
        // fallback branch, *succeeds* with a request count, and the store files
        // that as the last good reading: the archived percentage is not dimmed,
        // it is overwritten. The guard below only works if it outlives a quit,
        // and the remembered reading's own fidelity is the record of it.
        self.everBridged = Self.hasBridgedBefore(archive: archive)
    }

    /// Whether a remembered reading came from the language server.
    ///
    /// `.official` is only ever written by the bridge branch — every other path
    /// through `fetchSnapshot` is `.derived` — so the archived fidelity is a
    /// faithful record of whether it has answered on this machine.
    static func hasBridgedBefore(archive: UsageArchive) -> Bool {
        archive.load()[providerID]?.snapshot.fidelity == .official
    }

    /// Exposed so a test can prove the flag survives a relaunch rather than
    /// having to simulate one.
    var everBridgedForTesting: Bool { everBridged }

    nonisolated var signInRoute: SignInRoute {
        .openApp(bundleID: "com.google.antigravity", name: "Antigravity")
    }

    /// Whose readings these are — as far as anything local can say.
    ///
    /// The plan used to come off the token's `auth_method`. Nothing local
    /// carries it, so the row now says only which tool the numbers are borrowed
    /// from. That is a real loss and the right trade: the alternative is
    /// opening someone's credential to print one word.
    ///
    /// Antigravity having actually run here is the evidence that there is an
    /// account at all — it writes these transcripts on first use.
    nonisolated func account() -> ProviderAccount? {
        guard FileManager.default.fileExists(atPath: AntigravityActivity.transcriptRoot.path)
        else { return nil }
        return ProviderAccount(
            label: nil,   // nothing local carries the address
            plan: nil,    // nor the plan
            source: "Antigravity",
            manageURL: URL(string: "https://antigravity.google")
        )
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Antigravity's own language server, and now only that. It answers with
        // the figure Antigravity's own panel shows, and it needs nothing from
        // us — no token, no keychain, no prompt.
        if let windows = await localQuota(), !windows.isEmpty {
            everBridged = true
            return ProviderSnapshot(id: id, displayName: displayName, glyph: glyph,
                                    fidelity: .official, status: .ok, windows: windows,
                                    headlineID: "gemini-weekly")
        }

        // Antigravity has answered before and is not answering now: keep the
        // last percentage, dimmed and dated, rather than swapping in a count.
        // `notAnswering` is the store's word for "still true, just old".
        if everBridged { throw UsageProviderError.notAnswering }

        // Nothing has ever run here. Signed out and never installed look the
        // same from outside, and both are answered by the same sentence, so
        // there is nothing to be gained by telling them apart.
        guard FileManager.default.fileExists(atPath: AntigravityActivity.transcriptRoot.path)
        else { throw UsageProviderError.needsAuth }

        // Installed and used, but not running — so no percentage is available.
        // Our own count is the only number left, reported as a *count* with no
        // `usedFraction`: the cell prints the number and the ring draws its
        // track with no arc, because there is no limit to be a fraction of.
        let activity = AntigravityActivity.read()
        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            // Ours, not Google's. The tooltip prefixes a `~` on the strength of
            // this, which is exactly the claim being made.
            fidelity: .derived,
            status: .ok,
            windows: [
                LimitWindow(id: "requests",
                            label: "Requests today · no limit published",
                            used: activity.requestsToday)
            ]
        )
    }

    /// Ask Antigravity's language server, if it is running.
    ///
    /// Returns nil rather than throwing when it is not: Antigravity being
    /// closed is the ordinary case, not a fault, and the caller has an honest
    /// answer to fall back to.
    private func localQuota() async -> [LimitWindow]? {
        if let bridge, let windows = try? await AntigravityBridge.quota(
            from: bridge, session: localSession
        ), !windows.isEmpty {
            return windows
        }
        // Cached endpoint gone or never found: the port changes every time
        // Antigravity restarts, so a stale one is expected, not exceptional.
        guard let fresh = AntigravityBridge.discover() else {
            bridge = nil
            return nil
        }
        bridge = fresh
        return try? await AntigravityBridge.quota(from: fresh, session: localSession)
    }
}
