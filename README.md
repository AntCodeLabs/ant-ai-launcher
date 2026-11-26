# Clauncher – the Claude Launcher

A macOS menu bar app for people who run Claude under more than one account. Keep each Claude Desktop and Claude Code login separate, open sessions in the right folder with the right login, and see every running session at a glance.

By [AntCodeLabs Limited](https://antcodelabs.ai). Not affiliated with Anthropic. The icon is an original drawing of a pistol shrimp, the real animal that snaps its oversized claw hard enough to fire a bubble.

## Install

*Clauncher was called Ant AI Launcher before 1.2.0. If you're updating, quit the old app, delete it from Applications and install Clauncher; your settings carry over.*

1. Download the latest `Clauncher-<version>.zip` from [Releases](https://github.com/AntCodeLabs/ant-ai-launcher/releases/latest).
2. Unzip it and drag **Clauncher** to Applications.
3. Open it. The ant appears in the menu bar, and Settings opens so you can add folders.

Needs macOS 14 or later, on Apple silicon or Intel, and [Claude Desktop](https://claude.ai/download). Terminal sessions also need [Claude Code](https://docs.claude.com/en/docs/claude-code) (`claude`).

If the menu bar is too full to show the ant, press **⌃⌥⌘C** to open the menu at the pointer, or open the app again to show Settings.

## Logins

Each login is a separate Claude sign-in:

- **Claude Desktop** runs as its own instance with `--user-data-dir`, for example `~/Library/Application Support/Claude-Work`. Leave it empty for Claude's normal profile.
- **Claude Code in Terminal** runs `claude` with `CLAUDE_CONFIG_DIR`, for example `~/.claude-work`. Shell aliases for `claude` don't override it.

On first run the app adds Claude's normal profile, plus any other `Claude-<name>` Desktop profiles and `~/.claude-<name>` config folders it finds. To add another login, press **+** in Settings, open it from the menu, and sign in.

## Launch

- **Open Claude** starts or shows that login's Claude Desktop. The green dot means it's running.
- **A folder** starts a new Claude Code session there, in Claude Desktop or Terminal (you choose per folder).
  - Hold **⌥** to open it in the other app.
  - Hold **⇧** to run `claude --continue` there.
- **Open Folder…** works for any folder. **Recent ▸** lists folders the login used lately.
- **New Session with Prompt…** starts a session with your prompt. Terminal sends it straight away; Desktop fills it in. Prompts can be saved per folder.
- **Shortcuts:** give a folder **⌃⌥⌘1…9** in Settings to open it from anywhere.
- **Start My Day** opens every folder you've marked for it.
- **New Cloud Session…** runs `claude --cloud "<task>"` from a repo folder, signed in as that login. **More ▸ Claude Code on the Web** opens claude.ai/code, where cloud sessions live (the app can't list them: they don't run on your Mac).

## Monitor

- **Sessions** at the top of the menu lists every running Claude Code session, Desktop and Terminal, with its folder, login and state:
  - *needs you*: waiting on a question or permission
  - *done*: finished since you last looked
  - *working* or *idle*
  - *starting*: for example, at the "trust this folder?" question

  Click a session to jump to it: Desktop opens that exact session, Terminal brings its tab forward, and a background session (`claude --bg`) opens in Terminal with `claude attach`. ⌃-click stops a Terminal session. **More ▸ Background Sessions** opens Claude Code's agent view.
- The **ant shows a count** when sessions need you or have finished.
- Each login shows who Claude Desktop and Claude Code are signed in as, today's tokens, and Claude Desktop's memory and CPU. **More ▸** and Settings show 7-day usage.
- **More ▸ Configuration** opens each login's `settings.json`, `CLAUDE.md`, `.claude.json` (MCP servers) and Desktop MCP config.

## Privacy

Everything is read from files Claude already keeps on your Mac:

- `<config>/sessions/*.json` for session state
- the `usage` numbers in `<config>/projects/**.jsonl`
- Desktop's `claude-code-sessions/`
- the `oauthAccount` email in `.claude.json`

The app never reads tokens, passwords or conversation text, and it never changes Claude's settings. Its only network request is a daily check of this repository's latest release.

The first time you open a folder in a running Claude, or focus a Terminal tab, macOS asks to let Clauncher control that app. That permission is what lets it hand Claude the folder.

## Command line

```bash
AL="/Applications/Clauncher.app/Contents/MacOS/Clauncher"
"$AL" --launch Work --folder ~/code/my-project --terminal
```

```bash
"$AL" --status
```

The first command starts a session for a login, in a configured folder name or any path (leave out `--terminal` for Claude Desktop). The second prints logins, sign-ins, live sessions, recent folders and usage.

Settings live in `~/Library/Application Support/Clauncher/config.json`. You can edit them in **Settings…** or by hand; the menu re-reads the file each time it opens.

## Build from source

Only Apple's Command Line Tools are needed (`xcode-select --install`).

```bash
./build.sh            # universal build into build/
./build.sh install    # build, copy to ~/Applications and open
```

## Releasing

Releases are signed with a Developer ID, notarized by Apple and published as GitHub Releases.

One-time setup:

1. Create a **Developer ID Application** certificate for the team, at developer.apple.com → Certificates or in Xcode → Settings → Accounts → Manage Certificates. It must be in your login keychain.
2. Create an app-specific password at account.apple.com, then save notarization credentials:
   ```bash
   xcrun notarytool store-credentials ant-ai-launcher --apple-id <apple id> --team-id <team id>
   ```

Each release:

```bash
echo 1.0.1 > VERSION && git commit -am "Release 1.0.1"
./release.sh --publish
```

`release.sh` does the following:

- builds the app
- checks it for local paths and secrets
- signs it with the hardened runtime
- notarizes and staples it
- zips it with a SHA-256 checksum
- creates the GitHub Release

Use `./release.sh --dry-run` to test everything except signing and notarization.

## License

MIT © 2026 AntCodeLabs Limited. Claude is a trademark of Anthropic.
