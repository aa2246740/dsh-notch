# DSH Notch

[中文](README.md) · [English](README.en.md)

**DSH Notch is a macOS plugin for DeepSeek Harness.** It puts real session activity, questions, and unread results at the screen edge. Answer questions in the panel, open the matching DSH conversation, and watch the robot while idle.

Installation has two parts: a **Host plugin inside DSH** that supplies session state, and a **native Notch application** that displays it. Install both using the steps below.

## Installation

### Requirements

- macOS 14 or later.
- A working local DSH Web Host, with `dsh`, `pnpm`, and `git` available in your terminal.
- Swift 6 or later through Command Line Tools. Check with `swift --version`; use `xcode-select --install` if the developer tools are missing.

These instructions use the default `web` profile and `~/.dsh`. For a custom `DSH_HOME`, run plugin installation with that same environment and edit that Home's profile in step 2.

### 1. Download and install the Host plugin

```sh
git clone https://github.com/aa2246740/dsh-notch.git
cd dsh-notch
dsh plugin --profile web add "$PWD"
```

This links the local package into DSH's Web profile. Keep the checkout: it is also where you build the native application.

The warning `declares no dsh.bundle — installed as a plain dependency` is expected for this package. **Continue with step 2 to activate it.** The current package has no automatic bundle registration, so `plugin add` alone does not start Notch.

If you run DSH from source without a global `dsh` command, run this from the Harness checkout, then return to the Notch checkout:

```sh
pnpm dsh plugin --profile web add /absolute/path/to/dsh-notch
```

### 2. Activate the plugin in DSH

Append this item to the YAML list in `~/.dsh/profiles/web/cordis.patch.yml`. Create the file if absent. **Keep existing configuration, and add this ID only once.**

```yaml
- insert:
    - id: dsh-notch
      name: dsh-notch
```

`name: dsh-notch` resolves the profile dependency from step 1. Do not copy the repository's `cordis.yml` directly into this location; its relative paths serve a different purpose.

The standard Web profile watches this file and loads the plugin after saving. If DSH is not running yet, start it using your usual launcher. Successful loading emits `[my-plugins/dsh-notch] loaded` in the Host log and creates `~/.dsh/dsh-notch/runtime.json`.

The plugin manages this private connection file automatically. Do not fill it in manually or paste its contents into a chat. If it is absent, resolve YAML, module-resolution, or missing-service errors in the Host before continuing.

### 3. Build and start the real Notch

From the Notch checkout:

```sh
swift build --package-path macos -c release
macos/.build/release/dsh-notch --verify-idle-resources
macos/.build/release/dsh-notch
```

The resource check should print `IDLE_RESOURCES=10/10`. The last command starts the application connected to real DSH sessions. Keep this terminal open during the first run.

If your DSH.app already manages a Notch helper, update that copy instead of starting a duplicate. When moving the executable or integrating it into a desktop shell, keep `dsh-notch` and `DshNotch_DshNotch.bundle` from the same build together in the destination directory, then relaunch the helper. Installing the Host plugin does not configure login startup or replace a desktop shell's existing executable.

### 4. Confirm it works

- With no active work or unread results, the robot appears at the screen edge.
- Existing running sessions produce a blue count; questions and results produce their corresponding states.
- Clicking a session opens it in DSH. When a question appears, answer it directly in Notch.

Use existing sessions for these checks; a new model task is unnecessary. Seeing the robot alone does not prove Host connectivity: confirm that real session state updates too.

## Usage

| State or action | Meaning |
| --- | --- |
| Blue number | Running sessions |
| Yellow exclamation mark | A question or decision needs attention |
| Green number | Unread completed results |
| Red number | Failed results |
| Click an option | Submit that choice; follow the panel for multiple questions or selections |
| Click the question title | Open the full conversation in DSH |
| Read all results | Return to the idle robot |
| Drag and release Notch | Hide it elastically at the screen edge; drag it out again to restore |
| New completion, failure, or decision while hidden | Bounce back to the normal compact view; repeated polls of the same event do not reveal it again |

Ordinary running-state and size updates keep a hidden Notch tucked away. An attention event received during a drag waits until release. Screen work-area changes, including a right-side macOS Dock, do not move the hidden cap away from the physical display edge.

The interface uses native AppKit, SwiftUI, and Canvas. Animation itself never calls a model. The panel grows with content, scrolls at the screen-height cap, and respects Reduced Motion.

Counts represent user conversations. Workflow workers and nested subagents belong to their owning conversation; they do not add separate running, success, or failure indicators. A background worker keeps its owner running, while result indicators come from the owner's final outcome. Child questions appear on the owner's yellow indicator and answers return to the original requester, with multiple questions handled in order. User-created forks remain independent conversations.

External Codex, Claude Code, ACP, and DSH SDK children registered as official background jobs also keep their owner active. Observation never consumes job completion notices. The [dsh-notch-focus companion](companions/dsh-notch-focus/README.md) handles browser navigation and cold-session mirroring; existing installations can keep their current directory. See the [source compatibility audit](docs/subagent-compatibility.md) for entry paths, cancellation, resumption, and verification limits.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Package installed, but no Notch | Both Host activation in step 2 and native startup in step 3 are required. |
| Robot appears, but tasks do not | Check Host plugin loading, `runtime.json`, and whether the current Host is still running. |
| Cannot resolve `dsh-notch` | Use the same Home and profile for installation and activation; keep the linked source directory in place. |
| Fewer than `10/10` resources | Rebuild and keep the resource bundle with the executable. |
| Two Notches | Check for both a manually started and a desktop-shell-managed copy. |
| Old behavior after updating source | Rebuild and replace the executable actually running; `git pull` does not replace an existing native process. |

The Host plugin requires `sessions`, `webServer`, `approval`, `userQuestions`, and `agents`. It targets a local DSH Web Host on the same Mac. Native foregrounding looks for a DSH.app with bundle ID `local.dsh.desktop`; other desktop shells need an adapter. Successful package installation alone does not certify multiple Homes, remote Hosts, or every DSH version.

## Updates and development

After updating source, rebuild the native helper. Native-only changes require updating and relaunching Notch. Changes under `src/` also require the appropriate Host module activation.

Maintainers using [dshx](https://github.com/aa2246740/dsh-external-plugin-devkit) can inspect `dshx activation-plan dsh-notch --change artifact` or `--change server`, according to the changed surface. Initial activation above uses a watched patch; restarting the whole Host does not replace a missing installation step.

```sh
npm ci
npm test
npm run test:outcome
npm run test:motion
npm run test:geometry
npm run test:scrollbar
npm run test:expanded-height
npm run test:idle
npm run build:macos
```

Try the elastic edge-hiding gesture in the [standalone native preview](tools/elastic-preview/README.md), built with `npm run build:elastic-preview`. It uses local fixtures, makes no model requests, and does not replace an installed Notch.

### Optional recording demo

For animation review and video recording, separate from plugin installation:

```sh
npm run build:demo
open "dist/DSH Notch Demo.app"
```

The demo contains 36 bilingual scenes driven by local fixtures. It does not connect to DSH. See the [demo controls](tools/recording/README.md).

More: [motion contracts](macos/STATUS-MOTION.md), [design notes](DESIGN.md), [0.3.0 changes](docs/releases/v0.3.0.md), and [optional desktop-shell diagnostics](tools/desktop-shell/README.md).

## License

[MIT](LICENSE). Robot resources derive from [OpenBotMotion](https://github.com/aa2246740/open-bot-motion); its original [MIT notice](tools/idle/LICENSE.open-bot-motion) is retained. This is a community-maintained DSH plugin.
