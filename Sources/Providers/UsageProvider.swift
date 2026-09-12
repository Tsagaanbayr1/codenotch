import Foundation

/// One source of usage numbers. Each adapter declares how trustworthy it is,
/// and the UI never dresses a derived number up as an official one.
protocol UsageProvider {
    var id: String { get }
    /// Enough to draw the cell even when a fetch has never succeeded.
    var displayName: String { get }
    var glyph: ProviderGlyph { get }
    func fetchSnapshot() async throws -> ProviderSnapshot
    /// Whose readings these are. Declared here rather than only in an extension:
    /// a method that exists solely in a protocol extension is dispatched
    /// *statically*, so calling it through `any UsageProvider` would always land
    /// on the default and never on the implementation — which is exactly what
    /// happened, and it failed silently by reporting every account as absent.
    func account() -> ProviderAccount?
    /// Where the user goes to sign in, when there is no account to read. A
    /// requirement for the same reason `account()` is.
    var signInRoute: SignInRoute { get }
    /// Discard whatever credential *this app* holds for the provider.
    ///
    /// For a borrowed credential there is nothing here to discard — the session
    /// belongs to Claude Code or Cursor, and ending it is their business, not
    /// ours. For a session Codenotch created itself (`WebSessionProvider`) this
    /// is a real logout. A requirement, not an extension member, for the reason
    /// spelled out above `account()`.
    func signOut() async
    /// Open whatever sign-in this provider can present.
    ///
    /// Only a `WebSessionProvider` has a modal of its own to show — it owns the
    /// session, so it can create one. Everyone else borrows a credential, and
    /// the nearest thing is launching the app that holds it, which is why the
    /// route matters as much as this call. A requirement, not an extension
    /// member, for the reason spelled out above `account()`.
    func presentSignIn()
}

enum UsageProviderError: Error {
    /// No usable credential — the user has to sign in again.
    ///
    /// Always the owning tool's credential, never one of ours: Codenotch reads
    /// none. This is what "that tool is not signed in" looks like from here.
    case needsAuth
    /// The tool answered before and is not answering now — it was quit, or
    /// restarted onto a different port. Not the same as being signed out, and
    /// not the same as being gone: the last reading is still true, just old, so
    /// the store ages it rather than discarding it.
    ///
    /// Named for the condition, not for a credential. It was `credentialExpired`
    /// while the app still read tokens; it never reads one now, so a name about
    /// expiry would describe something that cannot happen.
    case notAnswering
    /// The endpoint answered, but not with anything we understand.
    case badResponse(status: Int)
    /// Asked to slow down. Carries the server's own retry hint when it gave one.
    case rateLimited(retryAfter: TimeInterval)
    /// The account is readable, but there is genuinely no quota being counted —
    /// Cursor's free plan reports an included limit of zero. Not an error, and
    /// it must not be shown as one.
    case nothingMetered(String)
    /// The tool this provider borrows its numbers from is not installed, or no
    /// longer answers in a shape we understand. Distinct from `needsAuth`,
    /// which means the tool is there and signed out: telling someone to sign in
    /// when the CLI is simply missing sends them to fix the wrong thing. Like
    /// `nothingMetered`, it supersedes any remembered reading — a number we can
    /// no longer re-read is a number we should stop showing.
    case unavailable(String)
}
