# Claude Bubble

A little orb for your Mac that shows what your [Claude Code](https://claude.com/claude-code) sessions are doing, so
you can look away until one needs you.

![The orb's states: working, needs you, error, done](docs/images/states.png)

- **At a glance.** The orb's colour and motion show the state of your sessions: working (and with which kind of tool),
  waiting on you, failed, or done. One pip per session sits under it.
- **Every session in one list.** Hover the orb for what each session is doing, how long it's been at it, and its
  context size.
- **Pull requests and issues.** Each session shows the GitHub issue and PR it's working on, with live checks and
  review status. Hover a chip for the details.
- **Usage.** Your 5-hour usage and time to reset, with a heads-up before you run low.
- **Stays out of the way.** Float the orb anywhere, or dock it as an island at any screen edge. Quiet mode, "hide for
  an hour", and 15 colour themes are one right-click away.
- **Keeps itself up to date.** New versions show up in the app; one click installs them.

![Session list and a pull request's hover card](docs/images/sessions.png)

## Install

You need macOS 14 or later (Apple silicon or Intel) and Claude Code.

1. Download `ClaudeBubble-<version>.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **Claude Bubble.app** to your Applications folder.
3. Open it. The app isn't notarized by Apple, so the first launch needs one extra step:
   - **macOS 15 and later:** open the app; when it says "Claude Bubble" Not Opened, click **Done** (not Move to
     Trash). Then go to **System Settings → Privacy & Security**, scroll down to "Claude Bubble was blocked", click
     **Open Anyway**, and confirm.
   - **macOS 14:** right-click the app, choose **Open**, then click **Open**.
   - **Or, in Terminal:** `xattr -dr com.apple.quarantine "/Applications/Claude Bubble.app"`
4. The setup window opens, and your bubble plays a short sample session beside it so you can see each state. Choose
   **Orb** or **Island**, turn on **Launch at login** if you like, and click **Connect to Claude Code**.
5. Restart any Claude Code sessions that are already running, so they start reporting to the bubble.

You can open setup again any time: right-click the orb, then **Settings… → Setup…**.

### What connecting changes

Connecting adds hooks to `~/.claude/settings.json` that tell the bubble about session events. It also routes your
status line through a small wrapper that saves usage for the bubble and then runs your own status line exactly as
before. Your original settings are backed up to `settings.json.claude-bubble.bak` first. Claude Bubble's own files
live in `~/.claude-bubble`.

### Optional: GitHub status

For live pull request and issue status, install the [GitHub CLI](https://cli.github.com) and sign in:

```sh
brew install gh
gh auth login
```

## Using it

| | |
|---|---|
| Hover the orb | Every session, its status, links and time |
| Click a session | Brings its terminal to the front |
| Hover a PR or issue chip | Its title, checks, review and labels |
| Right-click the orb | Themes, size, island or orb, quiet mode, hide for an hour, settings |
| Drag the orb (or island) | Anywhere, even mostly off the edge of the screen; the island docks to any edge |

## Updates

Claude Bubble checks this repository's releases about once a day. When there's a new version you'll see a
notification and an **Update** button at the top of the right-click menu; it shows what's new, then downloads,
verifies (the checksum published with the release, the app's identity and its code signature), installs and
relaunches. Your settings and connection carry over. You can check now, or turn automatic checks off, under
**Settings…**.

## Privacy

Everything stays on your Mac. The bubble reads:

- the session files its hook writes;
- Claude Code's local session state and transcripts, to find issue numbers;
- `git` in your project folders, for branch names.

It makes two kinds of network request, both to GitHub:

- **Update checks**, about once a day, to this repository's public releases (no account, nothing about you sent). You
  can turn them off in **Settings…**.
- **Pull request and issue status**, through the GitHub CLI with your own login, only if you've installed it.

## Uninstall

Right-click the orb, open **Settings…**, and choose **Uninstall Claude Bubble…**. It removes Claude Bubble's hooks
from Claude Code (your other hooks and your status line stay as they are), deletes its files and preferences, and
moves the app to the Trash. Restart any Claude Code sessions that are still running afterwards.

To stop it reporting to the bubble but keep the app, choose **Disconnect from Claude Code…** instead.

## Build from source

You need Xcode 16 or later.

```sh
git clone https://github.com/BrentWMiller/claude-bubble.git
cd claude-bubble
scripts/bundle.sh      # builds and installs ~/Applications/Claude Bubble.app
swift test             # unit tests
bash Tests/hook_test.sh
```

`scripts/release.sh` builds the universal release zip.

## License

MIT. Claude Bubble is an independent project, not made by or affiliated with Anthropic.
