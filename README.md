# Codenotch

A macOS app that pins a small black notch to a screen edge, showing how much of
each coding assistant's usage limit you have burned — and whether it is still
working, done, or waiting on you.

![Collapsed notch with hover tooltip](docs/design/frame-124-hover-tooltip.png)

Hover a ring for its limit windows and when they reset. Claude's ring shows the
same **current session** window Claude Code's own `/usage` leads with, so the
two never disagree.

## What it reads

| Provider | Source | How |
|---|---|---|
| **Claude Code** | official | Claude Code's own `/usage` command, run headlessly. No credential is read — the CLI uses its own. |
| **Cursor** | official | The editor's own signed-in session, read from its local SQLite state — no separate sign-in. |
| **Codex** | official | Codex's own app server, asked live for the current rate limits. Falls back to its rollout log when Codex isn't running. |
| **Antigravity** | official while it's running, otherwise a request count | Antigravity's own local language server, which holds the credential and answers with the figure its panel shows. A plain count from its transcripts when it isn't running. |
| **GLM** | official | Z.ai's Coding Plan monitor endpoint, with a key borrowed from whichever coding tool already holds one — Claude Code's `settings.json`, ZCode, or OpenCode. |

Codenotch never signs in anywhere, and it **makes no keychain request at all** —
macOS is never asked to hand over a saved login, so there is no prompt at any
point. Claude Code, Codex and Antigravity go further: their numbers come from
running the tool's own command, and no token of yours is read or sent. Cursor
and GLM still borrow a key their own tool wrote to a file on this Mac, because
neither publishes a command that would answer without one.

Install and sign in to any of these tools and its ring appears. Switching a
provider off in Settings stops it being read at all and forgets the readings
taken from it; it does not sign you out of the tool that owns the account, and
the row says so.

It also answers **"is it still working?"** — a thin arc spins inside a
provider's ring while a session is busy, and becomes a pulsing amber ring when
one is blocked waiting on you. Hover for every live session by name, where it
is running, and what it wants.

Two Claude Code logins are two rings. Anyone who keeps a work account apart with
`CLAUDE_CONFIG_DIR=~/.claude-work claude` gets a **Claude (work)** ring beside the
personal one, with its own limits, its own sessions and its own row in Settings.
Any `~/.claude-<slug>` directory Claude Code has run against is found at launch;
the default `~/.claude` always comes first, the rest in alphabetical order, so the
rings never swap places.

## Placement

The notch lives on any of the four screen edges. Right and left keep a
vertical column; top and bottom lay the readings out side by side. It pins
itself to the *usable* edge, so a bottom notch rests on the Dock and follows
when the Dock hides or moves. On a Mac with a hardware notch, the top
placement takes its exact shape, so the two read as one rather than as a bar
parked underneath it.

At rest it is a small pill on the screen edge that unfolds when the pointer
reaches it — configurable in Settings to always show, or to hide entirely.
Settings live in an orb below the notch: an arc at rest, a gear on hover.

The app itself can show a Dock icon, a menu bar icon, or neither.

## Updates

Codenotch updates itself. [Sparkle](https://sparkle-project.org) checks daily
and installs in the background without prompting; Settings says so and can
switch it off. Every update is EdDSA-signed, so nothing installs that wasn't
built and signed by the maintainer.

## Building

```sh
brew install xcodegen   # once
make run                # generate, build, launch a Debug build
make test               # unit tests
```

No signing identity is required for either. `make release` — which archives,
notarizes, and produces a signed auto-update feed — needs a Developer ID
certificate and an App Store Connect notary profile, and is only ever run by
the maintainer to cut an official release. See
[CONTRIBUTING.md](CONTRIBUTING.md).

Run with `CODENOTCH_DEMO=1` to see fixed sample data instead of live readings.

## Architecture

Every provider implements `UsageProvider` (`Sources/Providers/`) and declares
its own `Fidelity` — `.official`, `.derived`, or `.manual` — so the UI never
presents a guess as if a vendor had published it. `UsageStore`
(`Sources/Model/`) polls them on a timer, keeps the last good reading across
launches, and degrades every failure to a visible status rather than a
made-up percentage.

The notch itself works in one-dimensional **stack space** (`along`/`across`)
regardless of which screen edge it's on; `NotchPlacement` is the only place
that maps that back onto real screen coordinates. `NotchLayout` holds every
measurement, quoted from `docs/design/frame-124-hover-tooltip.png` so the
layout can be checked against the design frame directly.

- Design spec: [`docs/specs/2026-08-28-usage-notch-design.md`](docs/specs/2026-08-28-usage-notch-design.md)
- Implementation history: [`TASKS.md`](TASKS.md)

## The honest caveat

No vendor publishes a clean "your session limit is N% used" API for any of
these tools. Each adapter reads whatever the owning app itself reads from —
an internal endpoint, a local database, a language server's own RPC — and
those can change without notice. Every adapter's response shape is pinned by
tests, and every failure degrades to a visible status (`stale`, `needsAuth`,
`error`) rather than an invented number.

**Credentials:** there is no keychain access anywhere in the app — not one
call, for any provider. Claude runs `claude -p "/usage"`, Codex runs `codex
app-server`, and Antigravity is asked through its own language server; each of
those holds its own token and answers with the live figure. `/usage` is a local
command, so it costs no tokens and spends none of your quota.

Two providers are not yet in that state, and the app should not pretend
otherwise. Cursor reads the session token its editor stores in SQLite and sends
it to `cursor.com`; GLM reads a Coding Plan key from `settings.json`, ZCode or
OpenCode and sends it to Z.ai. Both are files rather than keychain items, and
both would stop working if the key moved — the vendors publish no command that
answers without one.

What that costs is honesty about absence. The tool has to actually be there:
where Claude Code's CLI isn't installed, or Antigravity isn't running, the ring
says so instead of falling back to anything. Two smaller things went with the
tokens — Antigravity's plan name, which only its credential carried, and the
direct Google quota call, which only a licensed account could make and which
the language server already outranked whenever both could answer.

**Polling:** a reading spawns a process, so the schedule is deliberately slow —
five minutes while something is running, fifteen when nothing is. Opening the
notch or clicking a ring refreshes immediately, which is when it matters.

**Rate limits:** GLM's endpoint returns 429 if polled too hard. A server's
`Retry-After` is treated as a floor-raiser only — an endpoint that answers `0`
is giving no guidance, and obeying it is what keeps you limited — so the wait
is 60s, doubling per consecutive 429, capped at 15 minutes, and the deadline is
persisted, so relaunching during a penalty waits instead of spending an
attempt on it. Right-clicking the notch offers **Refresh now**.

**Logs:** the app has no window, so anything worth diagnosing goes to the
unified log.

```sh
/usr/bin/log stream --predicate 'subsystem == "com.vinz.codenotch"' --level debug
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
