import Foundation
import os

/// Reads Claude Code's usage by asking Claude Code.
///
/// One instance per `ClaudeProfile`: a work login kept under `~/.claude-work`
/// has its own token, its own limits and its own ring, and `CLAUDE_CONFIG_DIR`
/// is what selects between them.
///
/// The numbers are Anthropic's, fetched live by Anthropic's own tool, so this
/// stays `.official` — the tooltip shows them unqualified. What it costs is
/// spelled out in `ClaudeCLI`: a process spawn per reading, and a printout to
/// parse instead of JSON. What it buys is that Codenotch never reads, holds or
/// sends the user's credential. Nothing here can prompt for a keychain item,
/// because nothing here opens one.
actor ClaudeCLIProvider: UsageProvider {
    nonisolated let profile: ClaudeProfile
    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let glyph = ProviderGlyph.claude

    /// How the printout is obtained. Injected for the reason the old provider's
    /// credential source was: the path that spawns a process cannot run in a
    /// test, and the parsing on the other side of it is the part most likely to
    /// break when Claude Code rewords a line.
    private let readUsage: @Sendable (ClaudeProfile) throws -> String

    init(profile: ClaudeProfile = .default(),
         readUsage: (@Sendable (ClaudeProfile) throws -> String)? = nil) {
        self.profile = profile
        self.id = profile.id
        self.displayName = profile.displayName
        self.readUsage = readUsage ?? Self.runCLI
    }

    /// What the card says when the CLI is missing.
    ///
    /// Says what is absent and what it is for, because installing it is the
    /// whole of the fix — there is no fallback to a stored token, by design.
    /// Exposed so the card's height budget is measured against the real
    /// sentence rather than a copy of it that can drift.
    static let missingCLIMessage =
        "Claude Code's CLI wasn't found. Codenotch reads your limits by running "
        + "`claude -p /usage`, so it needs the CLI on this Mac."

    /// Production's reader: find the CLI, run `/usage` against this profile.
    private static let runCLI: @Sendable (ClaudeProfile) throws -> String = { profile in
        guard let executable = ClaudeCLI.executable() else {
            throw UsageProviderError.unavailable(missingCLIMessage)
        }
        return try ClaudeCLI.usageText(executable: executable, profile: profile)
    }

    func fetchSnapshot() async throws -> ProviderSnapshot {
        // Off the actor: spawning a process and waiting on a pipe is blocking
        // work that takes seconds, and doing it here would stall every other
        // read this provider owes.
        let readUsage = self.readUsage
        let profile = self.profile
        let text = try await Task.detached(priority: .utility) {
            try readUsage(profile)
        }.value

        let windows = try ClaudeUsageText.windows(in: text)
        Log.usage.debug("\(self.id, privacy: .public): /usage gave \(windows.count) window(s)")

        return ProviderSnapshot(
            id: id,
            displayName: displayName,
            glyph: glyph,
            fidelity: .official,
            // No staleness to weigh, unlike Codex's rollout: `/usage` asks
            // Anthropic on every run, so a reading that came back at all came
            // back current.
            status: .ok,
            windows: windows,
            headlineID: "session"
        )
    }

    nonisolated var signInRoute: SignInRoute {
        // Names the command for a profile, because that is the only way to
        // reach it: plain `claude` signs the default one in, not this.
        .guidance("Run `\(profile.signInCommand)` once — it signs this account in. "
                  + "Codenotch then reads your limits by running its /usage command.")
    }

    nonisolated func account() -> ProviderAccount? {
        ClaudeAccountFile.account(for: profile)
    }
}
