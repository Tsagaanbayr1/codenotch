import CryptoKit
import Foundation

/// One Claude Code configuration directory, and so one account.
///
/// Claude Code keeps everything for an account under a single directory:
/// `~/.claude` by default, or wherever `CLAUDE_CONFIG_DIR` points. People who
/// keep a personal and a work login apart do it by aliasing the second one to
/// `~/.claude-work`, `~/.claude-client`, and so on — each with its own token in
/// the keychain and its own `sessions` folder. Reading only `~/.claude` showed
/// one of those accounts and was blind to the others: a work session never
/// spun the ring, and the work limit was never drawn at all.
///
/// A profile is the *convention* `~/.claude-<slug>`, not the environment
/// variable: the app is launched from Finder, so the alias's variable never
/// reaches it, and the directories are the only trace the profiles leave.
struct ClaudeProfile: Equatable, Hashable {
    /// The provider id the default profile has always had. Kept so archived
    /// readings, connection choices and the hover-band keys survive the change.
    static let defaultID = "claude"
    /// What every profile directory starts with.
    static let directoryPrefix = ".claude"

    /// Nil for `~/.claude`; the part after `.claude-` otherwise.
    let slug: String?
    let configDirectory: URL

    /// `~/.claude`, whether or not it exists — the app has always read it.
    static func `default`(home: URL = homeDirectory) -> ClaudeProfile {
        ClaudeProfile(slug: nil,
                      configDirectory: home.appendingPathComponent(directoryPrefix))
    }

    static var homeDirectory: URL { URL(fileURLWithPath: NSHomeDirectory()) }

    /// The default profile followed by every `~/.claude-<slug>` that Claude
    /// Code has actually used, slugs in alphabetical order so the rings never
    /// swap places between launches.
    ///
    /// "Actually used" is judged twice over. The files Claude Code writes on
    /// its first run rule out an empty directory or a stray one someone made
    /// by hand; a token filed under the directory's own service name rules out
    /// everything else that has learned to live at `~/.claude-<slug>`.
    ///
    /// The second test is what keeps plugins out. `claude-mem` keeps its state
    /// in `~/.claude-mem` and writes every one of the first-run names above, so
    /// the filename rules pass it and it is not an account: Claude Code has
    /// never signed in there and never will, so the ring could only ever read
    /// "Sign in to Claude Code in ~/.claude-mem to read your usage" — advice
    /// that cannot be followed, for a limit that does not exist. Filenames
    /// alone cannot tell the two apart, and a denylist of plugin names would
    /// only postpone the next one. The signed-in account can: no account, no
    /// ring.
    ///
    /// `hasAccount` is injected so discovery stays testable, and the real one
    /// reads Claude Code's own config rather than the login keychain. The
    /// keychain answered this question first, and answered it well — but the
    /// app opens no keychain item for anything now, and the config file settles
    /// it just as firmly: a directory Claude Code has actually signed in to has
    /// an address recorded in it, and a plugin's data directory does not.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default,
                         hasAccount: (ClaudeProfile) -> Bool = { $0.signedInAddress() != nil })
    -> [ClaudeProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> ClaudeProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            let candidate = ClaudeProfile(slug: slug, configDirectory: directory)
            guard hasAccount(candidate) else {
                Log.usage.debug("ignoring \(candidate.displayPath, privacy: .public): looks like a profile but has no account signed in")
                return nil
            }
            return candidate
        }
        return [ClaudeProfile.default(home: home)]
            + extras.sorted { $0.slug! < $1.slug! }
    }
    /// `.claude-work` → `work`; anything else → nil. The bare `.claude` is the
    /// default and is handled separately; `.claude.json` is a file that lives
    /// beside it and is not a profile at all.
    static func slug(fromDirectoryName name: String) -> String? {
        let prefix = directoryPrefix + "-"
        guard name.hasPrefix(prefix) else { return nil }
        let slug = String(name.dropFirst(prefix.count))
        return slug.isEmpty ? nil : slug
    }

    /// Any of the files Claude Code creates the first time it runs against a
    /// directory. One is enough: they are not all present on every version.
    private static let markers = ["sessions", "projects", "settings.json",
                                  "history.jsonl", ".claude.json"]

    static func isProfileDirectory(_ url: URL, fileManager: FileManager = .default) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return markers.contains {
            fileManager.fileExists(atPath: url.appendingPathComponent($0).path)
        }
    }

    // MARK: - Identity

    /// `claude` for the default, `claude-<slug>` for the rest. Doubles as the
    /// usage provider id and the activity monitor key, so a profile's sessions
    /// land in its own ring.
    var id: String { slug.map { "\(Self.defaultID)-\($0)" } ?? Self.defaultID }

    /// `Claude`, or `Claude (work)`. The cell draws the same glyph for every
    /// profile; this is what tells them apart in the tooltip and in Settings.
    var displayName: String { slug.map { "Claude (\($0))" } ?? "Claude" }

    /// Whether a provider id names a Claude profile, default or otherwise.
    static func isClaude(providerID: String) -> Bool {
        providerID == defaultID || providerID.hasPrefix(defaultID + "-")
    }

    /// The slug back out of a provider id, for code that only has the id.
    static func slug(fromProviderID id: String) -> String? {
        guard id.hasPrefix(defaultID + "-") else { return nil }
        let slug = String(id.dropFirst(defaultID.count + 1))
        return slug.isEmpty ? nil : slug
    }

    /// The directory as a person would type it.
    var displayPath: String {
        Self.tilde(configDirectory.path)
    }

    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        guard path.hasPrefix(home + "/") else { return path }
        return "~" + path.dropFirst(home.count)
    }

    // MARK: - What Claude Code keeps where

    /// Where Claude Code writes one file per running process.
    var sessionsDirectory: URL { configDirectory.appendingPathComponent("sessions") }

    /// Where it writes each session's transcript, one directory per working
    /// directory. The registry says which sessions exist; this says what they
    /// are doing — see `ClaudeTranscript`.
    var projectsDirectory: URL { configDirectory.appendingPathComponent("projects") }

    /// Claude Code's own settings file, which carries the signed-in address.
    ///
    /// The default profile keeps it *beside* the directory, at `~/.claude.json`;
    /// a profile reached through `CLAUDE_CONFIG_DIR` keeps it *inside* its own
    /// directory. Reading the wrong one shows the personal account against the
    /// work ring, so the distinction matters more than it looks.
    var accountFileURL: URL {
        slug == nil
            ? configDirectory.deletingLastPathComponent().appendingPathComponent(".claude.json")
            : configDirectory.appendingPathComponent(".claude.json")
    }

    /// As much of Claude Code's own record of the account as is read here.
    private struct AccountFile: Decodable {
        struct Account: Decodable {
            let emailAddress: String?
            let organizationUuid: String?
        }
        let oauthAccount: Account?
    }

    /// Claude Code's record of who is signed in for this profile, or nil.
    ///
    /// Readable without a keychain prompt, which is the whole point of asking
    /// here rather than of the token.
    private func account() -> AccountFile.Account? {
        guard let data = try? Data(contentsOf: accountFileURL),
              let config = try? JSONDecoder().decode(AccountFile.self, from: data)
        else { return nil }
        return config.oauthAccount
    }

    /// Who is signed in, read from that file.
    ///
    /// Worth having because the keychain token does not carry an address, so
    /// until now the settings row could not say *which* account a ring was for
    /// — the one question two Claude rings actually raise. It is also readable
    /// without a keychain prompt, which is the whole point of asking here.
    func signedInAddress() -> String? {
        guard let address = account()?.emailAddress, !address.isEmpty else { return nil }
        return address
    }

    /// Which Anthropic organization this profile's account belongs to.
    ///
    /// The one thing that can tie a Claude *Desktop* cache entry to a Claude
    /// *Code* profile: the cached usage URL is `/api/organizations/<uuid>/usage`,
    /// and this is the same uuid. Without it, Desktop's numbers would be handed
    /// to whichever ring asked first — the personal account's session percentage
    /// drawn on the work ring. See `ClaudeDesktopUsageCache`.
    func organizationID() -> String? {
        guard let uuid = account()?.organizationUuid, !uuid.isEmpty else { return nil }
        return uuid
    }

    static let defaultKeychainService = "Claude Code-credentials"

    static func keychainSuffix(forPath path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(8).description
    }

    // MARK: - Copy

    /// Which tool the credential is borrowed from, said so that two Claude rows
    /// in Settings can be told apart.
    var sourceName: String {
        slug == nil ? "Claude Code" : "Claude Code in \(displayPath)"
    }

    /// The command that signs this profile in, for the row that has no button.
    var signInCommand: String {
        slug == nil ? "claude" : "CLAUDE_CONFIG_DIR=\(displayPath) claude"
    }
}
