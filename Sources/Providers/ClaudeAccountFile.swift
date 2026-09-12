import Foundation

/// Whose readings these are, from Claude Code's own config file.
///
/// Claude Code records the signed-in account in `.claude.json` — an ordinary
/// JSON file holding no secret, only who signed in and on what plan. It is read
/// for the settings row and nothing else.
///
/// This replaces what the keychain token used to supply. It is strictly better
/// at it: the token carried a `subscriptionType` and no address at all, so
/// every Claude row in Settings showed a plan with nobody attached to it. That
/// is exactly the failure `ProviderAccount` exists to catch — a notch
/// faithfully reporting the wrong account's numbers.
enum ClaudeAccountFile {
    /// Where to look, in order.
    ///
    /// The default profile keeps its config beside the directory, at
    /// `~/.claude.json`, rather than inside it; a `CLAUDE_CONFIG_DIR` profile
    /// keeps it within. Both shapes are tried because which one a given
    /// install uses has changed across versions, and a missing address is not
    /// worth being wrong about.
    static func candidates(for profile: ClaudeProfile) -> [URL] {
        let directory = profile.configDirectory
        return [
            directory.appendingPathComponent(".claude.json"),
            directory.deletingLastPathComponent()
                .appendingPathComponent(directory.lastPathComponent + ".json")
        ]
    }

    static func account(for profile: ClaudeProfile,
                        fileManager: FileManager = .default) -> ProviderAccount? {
        guard let oauth = candidates(for: profile).lazy.compactMap({ url -> [String: Any]? in
            guard let data = try? Data(contentsOf: url),
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return root["oauthAccount"] as? [String: Any]
        }).first else { return nil }

        return ProviderAccount(
            label: oauth["emailAddress"] as? String,
            plan: planName(oauth["organizationType"] as? String),
            source: profile.sourceName,
            manageURL: URL(string: "https://claude.ai/settings/usage")
        )
    }

    /// `claude_max` → `Max`. Anthropic's own spelling with the prefix taken
    /// off; anything unrecognised is passed through rather than dropped, so a
    /// new plan name shows up as itself instead of disappearing.
    static func planName(_ organizationType: String?) -> String? {
        guard let organizationType, !organizationType.isEmpty else { return nil }
        return organizationType
            .replacingOccurrences(of: "claude_", with: "")
            .replacingOccurrences(of: "_", with: " ")
    }
}
