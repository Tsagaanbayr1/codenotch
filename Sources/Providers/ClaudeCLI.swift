import Foundation
import os

/// Runs Claude Code's own `/usage` command and hands back what it printed.
///
/// **Why this exists.** The reading used to come from `GET /api/oauth/usage`,
/// with the OAuth token read out of the login keychain. The token went nowhere
/// but Anthropic, so nothing leaked — but it meant Codenotch held a credential
/// it does not own, needed a place on that keychain item's access list, and
/// put a macOS prompt in front of anyone who had not granted it. None of that
/// is worth paying for a number the owning tool will print on request.
///
/// `claude -p "/usage" --output-format json` runs the same local command the
/// TUI's `/usage` panel draws. It is *local*: the envelope comes back with
/// `local_command: "usage"`, `num_turns: 0` and `total_cost_usd: 0`, so this
/// costs no tokens and spends none of the user's quota.
///
/// It is the same bargain as `CodexBridge`: the number comes from the vendor's
/// own tool, so the vendor's own tool has to be installed.
enum ClaudeCLI {
    /// Where to look for the binary, in order.
    ///
    /// A GUI app inherits none of the shell's `PATH` — it is launched by
    /// `launchd`, not by a login shell — so the directories a person would say
    /// are "on the path" have to be named here. Native install first: it is
    /// what `claude install` writes and what the installer puts in front of
    /// everyone now.
    static func candidatePaths(home: String = NSHomeDirectory()) -> [URL] {
        let home = URL(fileURLWithPath: home)
        return [
            home.appendingPathComponent(".local/bin/claude"),
            home.appendingPathComponent(".claude/local/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            home.appendingPathComponent(".bun/bin/claude"),
            home.appendingPathComponent(".volta/bin/claude")
        ]
    }

    static func executable(fileManager: FileManager = .default) -> URL? {
        let found = candidatePaths().first { fileManager.isExecutableFile(atPath: $0.path) }
        if found == nil {
            Log.usage.notice("claude: no CLI found in any known install location")
        }
        return found
    }

    /// The directories added to the child's `PATH`.
    ///
    /// The CLI is a native binary and `/usage` touches nothing else, but a
    /// child process launched from a GUI app starts with `/usr/bin:/bin` and
    /// little else, and a version of Claude Code that shells out for anything
    /// during start-up would fail in a way that is very hard to read from here.
    static let searchPath = [
        "\(NSHomeDirectory())/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
        "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ].joined(separator: ":")

    // MARK: - Asking

    /// Everything `/usage` printed, for one profile.
    ///
    /// `CLAUDE_CONFIG_DIR` is what selects the account for every profile but
    /// the default — see `ClaudeProfile.configDirectoryOverride` for why the
    /// default must have it *unset* rather than set to `~/.claude`. It is
    /// removed rather than left alone, so a Codenotch launched from a shell
    /// that had it set still reads the profile it was asked for.
    ///
    /// Runs in a temporary directory on purpose: started in a project, Claude
    /// Code would pick up that project's `CLAUDE.md` and settings for a command
    /// that has no use for either.
    static func usageText(executable: URL,
                          profile: ClaudeProfile,
                          timeout: TimeInterval = 30) throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = ["-p", "/usage", "--output-format", "json"]
        process.currentDirectoryURL = FileManager.default.temporaryDirectory

        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = profile.configDirectoryOverride
        environment["PATH"] = searchPath
        process.environment = environment

        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // A watchdog, because a CLI that never exits would otherwise hold the
        // read below open for ever. Terminating it closes the pipe, which is
        // what ends the read.
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer {
            watchdog.cancel()
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        Log.usage.debug("claude: asking \(executable.path, privacy: .public) for /usage")
        let data = output.fileHandleForReading.readDataToEndOfFile()

        guard let text = result(inEnvelope: data) else {
            // Whatever it did say, so a change in the envelope is visible
            // rather than silently becoming "no reading".
            Log.usage.error("claude: unreadable answer to /usage; said: \(String(decoding: data.prefix(400), as: UTF8.self), privacy: .public)")
            throw UsageProviderError.unavailable("Claude Code's /usage command gave no answer")
        }
        return text
    }

    /// The printed text out of `--output-format json`.
    ///
    /// The envelope is checked for `local_command: "usage"` before its `result`
    /// is believed. Without that check any *model* reply would be accepted as a
    /// usage report — which is what a future build that stops recognising
    /// `/usage` would produce, and it would arrive looking like prose about
    /// limits rather than like an error.
    static func result(inEnvelope data: Data) -> String? {
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["local_command"] as? String == "usage",
                  let result = object["result"] as? String
            else { continue }
            return result
        }
        return nil
    }
}
