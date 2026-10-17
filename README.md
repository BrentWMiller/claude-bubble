# Claude Bubble

A little orb for your Mac that shows what your [Claude Code](https://claude.com/claude-code) sessions are doing, so
you can look away until one needs you.

![Working, needs you, error, done](docs/images/states.png)

- Its colour and motion show whether Claude is working, needs you, hit an error, or is done.
- Hover it to see every session, with its GitHub issue or pull request.
- Float it anywhere, or dock it as an island at the edge of the screen.

![The session list](docs/images/sessions.png)

## Install

You need macOS 14 or later and Claude Code.

1. Download the zip from the [latest release](../../releases/latest), unzip it, and move **Claude Bubble.app** to
   Applications.
2. Open it. The app isn't notarized, so macOS blocks it the first time: click **Done**, then go to
   **System Settings → Privacy & Security** and click **Open Anyway**.
3. Click **Connect to Claude Code**, then restart any Claude Code sessions that are already running.

For pull request and issue status, also install the [GitHub CLI](https://cli.github.com) and run `gh auth login`.

Claude Bubble updates itself: new versions show up in the app.

## Privacy

Everything stays on your Mac. The only network requests are a daily update check against this repository's
releases (you can turn it off in Settings), and the GitHub CLI's, if you've installed it.

## Uninstall

Right-click the orb, open **Settings…**, and choose **Uninstall Claude Bubble…**.

## Build from source

```sh
git clone https://github.com/BrentWMiller/claude-bubble.git
cd claude-bubble
scripts/bundle.sh   # builds and installs ~/Applications/Claude Bubble.app (needs Xcode 16)
```

## License

MIT. Claude Bubble is an independent project, not made by or affiliated with Anthropic.
