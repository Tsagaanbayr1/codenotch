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
/// A profile is *discovered* by the convention `~/.claude-<slug>`, never by the
/// environment variable: the app is launched from Finder, so the alias's
/// variable never reaches it, and the directories are the only trace the
/// profiles leave. Once found, the directory is handed back to Claude Code as
/// `CLAUDE_CONFIG_DIR` whenever `ClaudeCLI` asks it for a reading — the same
/// mechanism the alias uses, which is what makes the two agree on whose limits
/// are being shown.
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
    /// "Actually used" is judged by the files Claude Code writes on its first
    /// run — an empty directory, or a stray one someone made by hand, would
    /// otherwise put a permanent "sign in" ring in the notch for an account
    /// that does not exist.
    static func discover(home: URL = homeDirectory,
                         fileManager: FileManager = .default) -> [ClaudeProfile] {
        let names = (try? fileManager.contentsOfDirectory(atPath: home.path)) ?? []
        let extras = names.compactMap { name -> ClaudeProfile? in
            guard let slug = slug(fromDirectoryName: name) else { return nil }
            let directory = home.appendingPathComponent(name)
            guard isProfileDirectory(directory, fileManager: fileManager) else { return nil }
            return ClaudeProfile(slug: slug, configDirectory: directory)
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

    /// What `CLAUDE_CONFIG_DIR` must be for a child `claude` to read *this*
    /// profile — and nil for the default, which needs it **unset**.
    ///
    /// Setting it to `~/.claude` is not the no-op it looks like. Claude Code
    /// keeps the default profile's account details in `~/.claude.json`, beside
    /// the directory; naming the directory explicitly moves that lookup inside
    /// it, to a `~/.claude/.claude.json` that holds machine settings and no
    /// account at all. Claude Code then cannot see the subscription, and
    /// `/usage` answers with a cost summary — an entirely believable printout
    /// that says nothing about limits. The reading was lost for the default
    /// profile, which is nearly everyone, and lost *quietly*.
    var configDirectoryOverride: String? {
        slug == nil ? nil : configDirectory.path
    }
}
