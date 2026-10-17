# Claude Bubble for anyone: design

## Goal

Anyone on macOS 14+ can download Claude Bubble, open it, connect it to Claude Code in one click, and remove it
cleanly. Nothing assumes the author's machine: no Xcode or Python, no Homebrew, no personal names.

Distribution is an **unsigned (ad-hoc signed) zip on GitHub Releases** (user's choice). Notarization is out of scope.

## A. A hook that needs nothing installed

Today the hook is bash with embedded Python run through `/usr/bin/python3`. On a Mac without the Command Line
Tools, that shim pops an "install developer tools" dialog on every tool call and the bubble sees nothing.

**Design**

- Port the hook's logic to Swift as `HookRecorder` in `ClaudeBubbleCore`, a pure function:
  `record(event: [String: Any], previous: [String: Any]?, now: Double, pid: Int32, env: HookEnvironment) -> Outcome`
  where `Outcome` is `.ignore`, `.delete`, or `.write([String: Any])`. Behaviour matches the Python hook line for
  line (states, pending permissions, replay window, details, motion/in-flight, counters, subagent TTL).
- A new executable target `claude-bubble-hook` (Foundation only) reads stdin, loads the previous record, calls
  `HookRecorder`, and writes atomically (temp file + rename). It finds the owning Claude process with `sysctl`
  (`KERN_PROC_PID`: parent pid and command name), walking past shells, with no `ps` processes.
  Respects `CLAUDE_BUBBLE_DIR`, `CLAUDE_BUBBLE_REPLAY_WINDOW`, `CLAUDE_BUBBLE_SUBAGENT_TTL`, `CLAUDE_BUBBLE_PID`.
  It never fails Claude: there's no output and the exit code is always 0.
- `hook.sh` shrinks to a stable shim that settings.json keeps pointing at:
  `B="${CLAUDE_BUBBLE_HOOK_BIN:-$HOME/.claude-bubble/bin/claude-bubble-hook}"; [ -x "$B" ] && exec "$B"; exit 0`
- The app bundle carries the binary at `Contents/Resources/claude-bubble-hook`. Install and the launch-time refresh
  copy it to `~/.claude-bubble/bin/claude-bubble-hook` (0755) and strip `com.apple.quarantine` from the copy, so a
  binary from a downloaded zip isn't blocked by Gatekeeper. The refresh happens only when a hook is already
  installed, and only if the file differs.
- Record format is unchanged for the fields the app reads. `tool_ids` becomes a list of `[key, id]` pairs (JSON
  objects don't keep order, and eviction needs oldest-first); a dict from the older hook is still read. The tool
  fingerprint becomes a CRC32 of the tool name plus its sorted-key JSON input.
- `python-path` is deleted on refresh. It was the Python hook's cache.

**Tests**: XCTest for `HookRecorder` (each rule above). `Tests/hook_test.sh` runs unchanged against the shim with
`CLAUDE_BUBBLE_HOOK_BIN` pointed at the built binary. The test script may keep using python3 to read fields
(a development-only dependency).

## B. Onboarding and uninstall

- **Welcome window** on first launch while no hook is installed. It is also reachable from the quick panel's
  advanced page as "Setup…". It shows:
  - what the bubble is, with the five states as coloured dots (working, needs you, done, error, idle);
  - a **Connect to Claude Code** button, which runs the existing install (hooks + status line wrapper + binary);
  - a live checklist:
    - Hooks installed;
    - Status line connected (for usage);
    - GitHub CLI found (optional, for PR and issue status).
  - Each line has a short explanation, plus "Open Claude Code settings" to reveal `~/.claude/settings.json`.
  - A note that Claude Code sessions already running pick the hooks up when restarted.
- **Disconnect from Claude Code** (advanced page; confirm first):
  - removes every hook entry whose command is our `hook.sh`;
  - restores the status line from `statusline-inner` (or removes it if that's empty);
  - deletes `hook.sh`, `statusline.sh`, `statusline-inner`, `bin/` and `python-path`;
  - edits the real file behind a symlinked settings.json;
  - leaves everything else in settings.json untouched;
  - the settings backup is kept.
- **gh discovery**: Homebrew paths, then `/usr/bin`, then the user's login-shell `PATH` (resolved once, in the
  background).

**Tests**: `HookInstaller.uninstall(settings:hookCommand:inner:)` cases (only our entries removed, empty groups and
events pruned, status line restored or removed, unrelated settings untouched, wrapper-free settings unchanged).

## C. Neutral identity

- Bundle ID `dev.claudebubble.app`. On first launch under the new ID, if its defaults are empty and
  `com.brentmiller.ClaudeBubble` has values, copy them over once. The launch-at-login registration is re-done if
  it was enabled.
- Test fixtures and comments use neutral names (`acme/widgets`, `octocat`), not real orgs or people.

## D. README, license, release

- `README.md`:
  - what it is, with screenshots rendered offscreen (orb, island, session list, hover card);
  - install from the zip;
  - Gatekeeper first-launch steps: right-click → Open, or System Settings → Privacy & Security → Open Anyway on
    macOS 15+, or `xattr -dr com.apple.quarantine`;
  - connecting, features, privacy (everything stays local; `gh` is optional and uses the user's own login);
  - building from source, and uninstalling.
- `LICENSE`: MIT, © 2026 Brent Miller.
- `scripts/release.sh`:
  - builds a universal (arm64 + x86_64) release;
  - bundles the app and hook binary, ad-hoc signs it;
  - zips with `ditto` to `build/ClaudeBubble-<version>.zip` and prints its SHA-256.

## Out of scope

Notarization and a Developer ID, a Homebrew cask, auto-update, and renaming the app.
