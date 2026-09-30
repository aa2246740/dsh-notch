# DSH Notch

[中文](README.md) · [English](README.en.md)

**DSH Notch is a macOS plugin for DeepSeek Harness.** It puts real session activity, questions, and unread results at the screen edge. Answer questions in the panel, open the matching DSH conversation, and watch the robot while idle.

Installation has two parts: a **Host plugin inside DSH** that supplies session state, and a **native Notch application** that displays it. Install both using the steps below.

## Installation

**DSH Notch 0.3.4 supports official DeepSeek Harness `0.2.0-rc.2`.** Install `dsh-notch@0.3.4` and `dsh-notch-focus@0.1.2` from npm. The native macOS helper remains version 0.3.3 and is included in the release below. This release changes npm packaging and installation instructions; its runtime code matches 0.3.3.

### 1. Download the release

Download from [v0.3.4](https://github.com/aa2246740/dsh-notch/releases/tag/v0.3.4):

| File | Purpose |
| --- | --- |
| `dsh-notch-0.3.4.tgz` | Host plugin for status, questions, and native connectivity |
| `dsh-notch-focus-0.1.2.tgz` | Client companion for navigation and reading acknowledgements |
| `dsh-notch-0.3.3-macos-arm64.tar.gz` | Native executable and robot resources; macOS 14+, Apple Silicon |
| `SHA256SUMS` | Place beside the downloads and run `shasum -a 256 -c SHA256SUMS` |

Prebuilt packages do not require Swift or DSHX. Other architectures require a source build and are not covered by this binary release.

### 2. Install both plugin packages

**Official Desktop:** enter `dsh-notch@0.3.4` and `dsh-notch-focus@0.1.2` through the app's Plugins page, enable them, follow the app's loading instructions, then reopen the page. The app owns the Desktop profile.

**Web:** use the same `DSH_HOME` as the running Host, then run from your download directory:

```sh
dsh plugin --profile web add dsh-notch@0.3.4
dsh plugin --profile web add dsh-notch-focus@0.1.2
```

Both packages declare official `dsh.bundle.patch` entries. Follow the plugin manager's loading guidance and reopen the page. Do not add a second manual insert. Update existing entries when migrating older installations so a Bundle and an old manual patch do not mount the same plugin twice.

A loaded Host writes `$DSH_HOME/dsh-notch/runtime.json`. This is a private connection file managed by the plugin; do not fill it in or share it. Check Host loading errors if it is absent.

### 3. Extract and start the native helper

```sh
tar -xzf dsh-notch-0.3.3-macos-arm64.tar.gz
cd dsh-notch-0.3.3-macos-arm64
./dsh-notch --verify-idle-resources
./dsh-notch
```

The resource check should print `IDLE_RESOURCES=10/10`. Keep the terminal open for the first run. If a desktop launcher already manages a Notch helper, update that executable instead. Always keep `dsh-notch` and `DshNotch_DshNotch.bundle` together when moving them. A custom `DSH_HOME` must match the Host's Home.

Optionally set the Host plugin's `helperPath` configuration to the absolute path of the extracted executable and follow the app's plugin loading guidance. The Host then supervises that helper; do not also start another copy manually.

### 4. Confirm synchronization

- Running primary sessions show a blue count; completions, failures, and questions show their corresponding states.
- Clicking a Notch session opens the matching conversation in DSH.
- Opening a completed session in foreground DSH clears that result from Notch. Running tasks remain visible.
- Reading all results returns Notch to the idle robot.

The native helper exits with its Host. Temporary request failures do not close it. Closing only the window keeps it alive if the Host still runs. See [desktop helper ownership](desktop/README.md) for lifecycle integration.

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

The Host plugin requires `sessions`, `webServer`, `approval`, `userQuestions`, and `agents`. It targets a local DSH Web Host on the same Mac. Native foregrounding prefers official `com.deepseek.dsh` and retains compatibility with `local.dsh.desktop`. Successful package installation alone does not certify multiple Homes, remote Hosts, or every DSH version.

## Updates and development

After updating source, rebuild the native helper. Native-only changes require updating and relaunching Notch. Changes under `src/` also require the appropriate Host module activation.

Maintainers using [dshx](https://github.com/aa2246740/dsh-external-plugin-devkit) can inspect `dshx activation-plan dsh-notch --change artifact` or `--change server`, according to the changed surface. Package synchronization and live activation are separate checks.

Source builds require Node.js 24 and Swift 6 / Command Line Tools:

```sh
npm ci --ignore-scripts --legacy-peer-deps
npm run build
npm run build:macos
```

See the [companion README](companions/dsh-notch-focus/README.md) for its DSHX 0.9.2 build against a `dsh-v0.2.0-rc.2` checkout. Release consumers do not need DSHX.

Development checks:

```sh
npm ci --ignore-scripts --legacy-peer-deps
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

More: [motion contracts](macos/STATUS-MOTION.md), [design notes](DESIGN.md), [0.3.3 changes](docs/releases/v0.3.3.md), [0.3.2 changes](docs/releases/v0.3.2.md), [0.3.0 changes](docs/releases/v0.3.0.md), and [optional desktop-shell diagnostics](tools/desktop-shell/README.md).

## License

[MIT](LICENSE). Robot resources derive from [OpenBotMotion](https://github.com/aa2246740/open-bot-motion); its original [MIT notice](tools/idle/LICENSE.open-bot-motion) is retained. This is a community-maintained DSH plugin.

See the [Desktop 0.1.7-rc.2 verification record](docs/desktop-017rc2.md). `DSH_NOTCH_RUNTIME_FILE` selects the connection only. Use explicit `--demo` or `--elastic-preview` modes for offline presentation.
