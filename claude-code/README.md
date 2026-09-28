# Bot Notch for Claude Code

Bot Notch shows Claude Code CLI and Desktop sessions in a native macOS notch (the same helper app as DSH Notch). Running sessions, permission prompts, AskUserQuestion questions, and unread results appear at the screen edge. You can approve, reject, or answer from Notch, and clicking a session brings its terminal or app to the front.

The native helper is unchanged. The plugin runs a small local bridge that serves the same `/dsh-notch/*` HTTP contract as the DSH Host plugin. The helper finds the bridge through `DSH_NOTCH_RUNTIME_FILE`.

```
Claude Code hooks ──► hook.mjs ──► bridge.mjs (127.0.0.1, token) ◄── native helper (dsh-notch executable)
 (SessionStart / UserPromptSubmit / PermissionRequest / Stop / StopFailure / SessionEnd …)
```

## Installation

Requirements: macOS 14+ on Apple Silicon (for the native helper), Node.js 18+ on `PATH`, and a recent Claude Code.

1. Download and extract the native helper `dsh-notch-<version>-macos-arm64.tar.gz` from Releases. Keep `dsh-notch` and `DshNotch_DshNotch.bundle` in the same folder.
2. Install the plugin in Claude Code:

   ```
   /plugin marketplace add aa2246740/dsh-notch
   /plugin install bot-notch@bot-notch
   ```

   For local development, use `claude --plugin-dir ./claude-code` instead.
3. When the plugin is enabled, set **Notch helper executable** to the absolute path of the extracted `dsh-notch`. You can change it later in `/config`. With this set, the plugin starts and supervises the helper.

The Code tab in Claude Desktop runs the same Claude Code and reads the same user-level plugins, so it works the same way after installation.

To start the helper yourself instead, leave `helper_path` empty and run:

```sh
DSH_NOTCH_RUNTIME_FILE="$HOME/.claude/bot-notch/runtime.json" ./dsh-notch
```

## Behavior

| Claude Code event | Notch |
| --- | --- |
| `UserPromptSubmit` | Blue: running. Sending a new message also marks the previous result as read |
| `PermissionRequest` (Bash / Edit / MCP …) | Yellow: the approval card shows the tool and command; Allow or Reject answers it |
| `PermissionRequest` (AskUserQuestion) | Yellow: questions and options, answered in the panel (multi-select and custom text supported) |
| `PermissionRequest` (ExitPlanMode) | Yellow: "Approve plan: <title>" |
| `Stop` | Green: unread completed result. A running background subagent/workflow keeps it blue |
| `StopFailure` (rate_limit / server_error …) | Red: failed result |
| `SessionEnd`, or the Claude Code process exits | The session is removed |

- **Answering in either place is fine (by design).** The dialog in the terminal or Desktop and the Notch card race, and whichever answers first wins. This relies on Claude Code showing its own dialog while the hook runs, which has not yet been verified with a live model on a real Mac. If the terminal dialog only appears after the Notch window ends, lower `approval_wait_seconds`. After `approval_wait_seconds` (default 300) with no answer from Notch, the card is withdrawn and Claude Code's own dialog carries on. Set it to `0` to show status only, with no answering from Notch.
- **Opening a session:** the bridge records the session's host app (`__CFBundleIdentifier` / `TERM_PROGRAM`, for example Terminal, iTerm2, VS Code, Ghostty, Claude Desktop) and brings it forward with `open -b`. It cannot jump to a specific tab.
- **Subagents** belong to the conversation that owns them. Their permission prompts appear on the owner's yellow light and do not count as separate sessions.
- **Lifecycle:** there is one bridge per user. It exits about a minute after every tracked Claude Code process has exited, and the helper (which follows the `pid` in the runtime file) exits with it. The next Claude Code session starts it again.

## Files

Default location `~/.claude/bot-notch/` (follows `CLAUDE_CONFIG_DIR`; override with `BOT_NOTCH_HOME`). The helper executable is still called `dsh-notch`, and `/dsh-notch/*` and `DSH_NOTCH_RUNTIME_FILE` are the helper's protocol names, so they keep the old spelling.

| File | Purpose |
| --- | --- |
| `runtime.json` | Bridge address, one-time token, pid (0600, do not share) |
| `seen.json` | Read timestamps, kept for 30 days |
| `bridge.log` / `helper.log` | Bridge and helper logs |

The bridge listens on 127.0.0.1 only, and every endpoint requires the Bearer token from the runtime file.

## Known limitations

- **Alongside an existing DSH Notch install:** files, ports and settings do not collide (`~/.dsh/dsh-notch/` vs `~/.claude/bot-notch/`, each with its own random port and token). But while DSH and Claude Code both run, two helper windows open at the same screen position and overlap, and the hidden-at-edge state is shared between them. If DSH itself launches Claude Code as a child, that child also shows up in Bot Notch as a separate session.
- `PermissionRequest` does not fire for network requests from sandboxed commands, so those still have to be answered in Claude Code.
- The helper's "open DSH" action is a no-op when DSH is not running. The Claude Code terminal or app is activated by the bridge.
- Changing `helper_path` takes effect after all Claude Code sessions exit and the bridge restarts.

## Development

```sh
node --test tests/claude-code-board.test.mjs tests/claude-code-bridge.test.mjs
claude plugin validate ./claude-code
claude plugin validate .
```

`scripts/lib/notch-lifecycle.mjs` is a copy of `desktop/notch-lifecycle.mjs`, and the tests check that the two stay identical.
