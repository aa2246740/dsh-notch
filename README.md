# DSH Notch

A **native macOS helper** plus a **Host row**. This is not a stock one-command Host plugin.

原生 macOS 任务胶囊，外加一行 Host 侧服务。**不是**一条 `dsh plugin add` 就能装完的官方插件。

Official DeepSeek Harness **0.1.5-rc.2** has no Creator Mode and no DSHX. Do **not** treat this as a complete install:

```sh
dsh plugin --profile web add github:aa2246740/dsh-notch
```

That command does not build or launch the helper. This package does not declare `dsh.bundle.patch`, so stock Host will not mount the row from that add.

官方 0.1.5-rc.2 没有创造模式，也没有 DSHX。上面这条命令不会编译或启动 helper，也不会把这一行写进 `dsh.profile.bundles`。

The helper does not run a browser or call a model. Click a choice to answer; click a question title to jump back into DSH for context.

Helper 不跑浏览器、不调模型。点击选项直接回答，点击问题标题返回 DSH 查看上下文。

## What this is / 这是什么

- **Helper:** AppKit, SwiftUI, and Canvas on macOS 14+. Live task counts, decisions, results, and an idle robot.
- **Host row:** `src/dsh-notch.ts` uses the Host you already run (`sessions`, `webServer`, `approval`, `userQuestions`, `agents`). Once that row is loaded, it writes `~/.dsh/dsh-notch/runtime.json` so the helper can attach. It never starts another DSH server.

## Install the helper / 安装原生 helper

This is the real install path. You need macOS 14+, Swift 6 Command Line Tools, and clone access to this repository.

```sh
git clone https://github.com/aa2246740/dsh-notch.git
cd dsh-notch
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
swift build --package-path macos -c release
macos/.build/release/dsh-notch --verify-idle-resources
macos/.build/release/dsh-notch
```

`--verify-idle-resources` should print `IDLE_RESOURCES=10/10`. When you copy the binary elsewhere, keep `DshNotch_DshNotch.bundle` next to `dsh-notch`. Do not launch a second helper while another copy is already running.

Native-helper updates replace the executable **and its resource bundle**, then relaunch only that helper. Copying a file does not reload Host modules.

The helper reads the loopback origin and token from `~/.dsh/dsh-notch/runtime.json`. Keep that file private. Until a loaded Host row has written it, there is nothing live to attach to — use the recording demo below to see the motion offline.

## Host row (secondary) / Host 行（第二步）

The helper is the product. The Host row is a separate TypeScript insert (`src/dsh-notch.ts`, watched overlay in `cordis.yml`). It is **not** a boot-captured `dsh.bundle`.

If you already run `dsh web` and have **pnpm** on `PATH`, official `dsh plugin --profile web add github:aa2246740/dsh-notch` (or `npx @deepseek-ai/dsh …`) can add the Node package to the `web` profile. That is a **secondary** step only. It is not a Host bundle install and not a complete product install:

- no `dsh.bundle.patch` — stock Host does not append this to `dsh.profile.bundles`
- no compiled `lib/` and no `prepare` — TypeScript source does not boot as a stock bundle
- the helper is a Swift binary; `dsh plugin add` never builds it
- add writes the profile; restart that Host and reload the page; it is not live
- this repository is private; `github:` fails if you cannot clone it
- DSH.app Plugin Manager accepts npm package specs only, not `github:`

直到 Host 真正加载这一行并写出 `runtime.json`，helper 连不上真实任务。不要把 `dsh plugin add` 当成装完。

DSHX and `my-plugins/` are not required to build or run the helper. Skip them unless you already use DSHX to mount a watched TypeScript insert.

## Try the recording demo / 先看演示

Requires macOS 14+, Swift 6 Command Line Tools, and Python 3. Native visual checks must be run on macOS.

```sh
git clone https://github.com/aa2246740/dsh-notch.git
cd dsh-notch
export DEVELOPER_DIR=/Library/Developer/CommandLineTools
sh tools/recording/build.sh
open "dist/DSH Notch Demo.app"
```

The demo copies the current production animation sources at build time and substitutes a local transport stub. It does not connect to DSH, send real answers, or spend model tokens.

| Key | Action / 操作 |
| --- | --- |
| ← / → | Previous / next group · 上一组 / 下一组 |
| S | Grid / single scene · 六格 / 单场景 |
| R | Replay · 重播 |
| H | Show / hide controls · 显示 / 隐藏控制栏 |
| Control + Command + F | Full screen · 全屏 |

Only the visible scenes animate. Disable “全部连播” to loop one group. See [recording instructions](tools/recording/README.md).

## What's new in 0.3.0 / 本次更新

- Running → decision shares the travelling brush used for success and failure. Single-task and concurrent-task cases preserve the right counts.
- Decision → running has a continuous return path. Fast replies queue behind the outgoing stroke; stale callbacks cannot replay a completed transition.
- Nine idle motions, blinking, and the chameleon easter egg share the production robot renderer. Idle pauses last 5–10 seconds; dance lasts 3–5 seconds.
- A standalone recording app includes **36 scenes with Chinese and English titles**, in a six-tile grid or a single-scene view.
- Long questions grow to the screen limit, then scroll; short questions shrink again. Long Markdown keeps its choices below the scrolling detail.

蓝色到黄色、黄色返回蓝色已接入正式 helper，覆盖单任务、多个任务和快速回复。机器人、成功与失败、未读清除、任务增减都可在离线演示里循环录屏。

## Motion and layout / 动效与布局

A short brush leaves the current blue orbit and paints the destination: green above for done, red below for failed, yellow for a decision. It returns to blue only while work remains. Outbound status motion takes 0.95 seconds. Replies preserve the source count until the stroke rejoins the running orbit.

The idle robot uses sampled vector outlines with per-frame interpolation. Incoming work interrupts its current pose, folds the robot back into a point, and draws the new status. After every result is read, the robot rotates and grows back into view. Reduced Motion presents static final states.

Compact height follows visible status slots. Expanded height follows content, capped by equal top and bottom screen insets. The native panel preserves its upper-right anchor during resizing.

See [motion contracts](macos/STATUS-MOTION.md), [design notes](DESIGN.md), and [robot resources](tools/idle/).

## Development / 开发验证

Node.js with `--import` support is required for Host unit tests. Native tests need macOS and Swift Command Line Tools.

```sh
npm ci
npm test
npm run test:outcome
npm run test:motion
npm run test:geometry
npm run test:scrollbar
npm run test:idle
npm run build:macos
npm run build:demo
```

These checks use offline fixtures. They cover state transitions, brush continuity, fast replies, cancellation, window geometry, and robot resources. Actual session focus, Host approvals, keyboard input, and multiple displays need separate live acceptance.

Optional desktop renderer diagnostics and recovery tools live in [tools/desktop-shell](tools/desktop-shell/README.md). They belong to the desktop shell, not the native animation runtime. Logging or reloading a blank renderer does not establish its underlying cause.

Compatibility depends on the Host interfaces named above; this release is not a blanket certification of every DSH version or desktop shell.

## License / 开源许可

[MIT](LICENSE). Robot assets derive from [OpenBotMotion](https://github.com/aa2246740/open-bot-motion); its original [MIT notice](tools/idle/LICENSE.open-bot-motion) is retained. This is an independent community companion, not an official DeepSeek application.
