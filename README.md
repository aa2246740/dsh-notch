# DSH Notch

[中文](README.md) · [English](README.en.md)

**DSH Notch 是 DeepSeek Harness 的 macOS 插件。** 它把真实会话的运行状态、待回答问题和未读结果放在屏幕边缘：查看任务、直接回答问题、点击回到对应会话；空闲时显示待机机器人。

插件包含两部分：**装进 DSH 的 Host 插件**负责同步会话，**原生 Notch 程序**负责显示和交互。下面的安装步骤会装好这两部分。

## 安装

### 准备条件

- macOS 14 或更新版本。
- DeepSeek Harness `0.1.7-rc.2`。本包对 `@deepseek-ai/dsh` 与所用 `@deepseek-ai/dsh-*` 的 peer 是 `>=0.1.7-rc.1 <0.1.8`，该范围包含 `0.1.7-rc.1` 与 `0.1.7-rc.2`。
- 本机已有正常运行的 DSH Web Host；终端能使用 `dsh`、`pnpm` 和 `git`。
- Swift 6 或更新版本的 Command Line Tools。用 `swift --version` 检查；没有开发工具时先运行 `xcode-select --install`。

当前适配官方桌面版 **DSH 0.1.7-rc.2**，保留 Web profile 支持。官方桌面版的 `desktop` profile 由应用独占管理，安装和启用请使用应用内插件管理页；不要用 CLI 修改 desktop profile。下面的 CLI 命令仅用于 Web profile。自定义 `DSH_HOME` 时，Host 和 Notch 必须指向同一 Home。

### 1. 下载并安装 Host 插件

```sh
git clone https://github.com/aa2246740/dsh-notch.git
cd dsh-notch
npm ci --ignore-scripts --legacy-peer-deps
npm run build
dsh plugin --profile web add "$PWD"
```

这条命令把本地插件目录链接到 DSH 的 Web profile。请保留这个目录，后面还要在这里构建 Notch。

当前包声明了 `dsh.bundle`，Host 入口是预编译的 `lib/index.mjs`。官方桌面版用户完成构建后，在应用内插件管理页安装这个目录或打包后的插件。请保留源码目录，后面还要在这里构建原生 Notch。

<details>
<summary>从 Harness 源码运行，没有全局 dsh 命令？</summary>

在 Harness checkout 里运行它自己的 CLI，使用刚下载插件的绝对路径：

```sh
pnpm dsh plugin --profile web add /absolute/path/to/dsh-notch
```

然后回到 `dsh-notch` 目录继续下面的步骤。

</details>

### 2. 在 DSH 中启用插件

在插件管理页确认 DSH Notch 已启用。包自带 `cordis.patch.yml`，不要再重复添加同名 `insert`；旧版已有挂载的安装应更新原来的条目。

成功加载后，Host 生成 `$DSH_HOME/dsh-notch/runtime.json`。这份私有连接文件由插件管理，不需要手工填写或发送给 Agent。若未生成，先检查插件管理页和 Host 的加载错误。安装包和原生程序是两步，只有 Host 插件不会自动出现 Notch。

### 3. 构建并启动正式 Notch

在刚下载的 `dsh-notch` 目录执行：

```sh
swift build --package-path macos -c release
macos/.build/release/dsh-notch --verify-idle-resources
macos/.build/release/dsh-notch
```

资源检查应输出 `IDLE_RESOURCES=10/10`。最后一条命令启动连接真实 DSH 会话的 Notch；首次启动时保持这个终端窗口打开。

Notch 会跟随 `runtime.json` 中的 Host 进程：收到进程退出通知后立即关闭，不再人为等待 2 秒，单独热更新启动的 Notch 也一样。临时请求失败不会让它退出。仅关闭 DSH 的窗口、但 Host 仍在后台运行时，Notch 会继续显示任务；再次启动 Host 后，按原来的入口启动 Notch。离线演示不受这条规则影响。App 壳可接入 [退出与快速重启联动](desktop/README.md)，接管已有 Notch，并在它恰好退出时补开一份。

如果你使用的 DSH.app 已经在管理一份 Notch，只更新那份程序，避免同时启动两个。移动程序或接入 App 壳时，要把 `dsh-notch` 和同一构建目录的 `DshNotch_DshNotch.bundle` 一起放到目标目录，再重新启动 Notch 程序。单独安装 Host 插件不会自动配置登录启动，也不会替换某个 App 壳里的旧程序。

### 4. 确认安装成功

- 没有活跃任务和未读结果时，屏幕边缘出现机器人。
- 已有会话运行时出现蓝色计数；完成、失败或等待决定时显示对应状态。
- 点击会话能回到 DSH；出现问题时可以直接在 Notch 里选择回答。

可以用已有会话检查，不必为了测试新开一个模型任务。仅出现机器人还不能证明已经连接 Host；还要确认真实会话状态能同步。

## 使用

| 状态 / 操作 | 含义 |
| --- | --- |
| 蓝色数字 | 正在运行的会话数量 |
| 黄色感叹号 | 有待处理的问题或决定 |
| 绿色数字 | 未读的完成结果 |
| 红色数字 | 失败结果 |
| 点击问题选项 | 直接提交该选项；多选或多题按面板提示完成 |
| 点击问题标题 | 回到 DSH 查看完整上下文 |
| 全部结果读完 | 回到机器人待机 |
| 拖动 Notch 后松手 | 弹性收纳到屏幕边缘；再拖出即可恢复 |
| 隐藏时出现新完成、错误或待审批问题 | 自动弹回正常紧凑状态；同一提醒不会因轮询反复弹出 |

隐藏状态下，普通运行和尺寸更新不打扰你。鼠标正在拖动时收到新提醒，会先保持跟手，等松手再恢复。右侧系统 Dock 或显示工作区变化不会改变 Notch 对物理屏幕边缘的定位。

Notch 使用原生 AppKit / SwiftUI / Canvas 渲染。动画本身不调用模型。窗口随内容展开，达到屏幕高度上限后滚动；系统开启“减少动态效果”时呈现静态状态。

计数以用户的主对话为单位：workflow 和普通子代理（包括嵌套子代理）归到所属主对话，不会各自增加蓝色数字或生成完成、失败灯。后台子代理仍在工作时，主任务继续显示运行中；结果灯以主对话的最终结果为准。子代理需要你回答的问题会显示在主任务的黄色状态下，回答送回原请求，多个问题依次处理。用户手动 fork 出来的对话仍独立计数。

外部 Codex、Claude Code、ACP、DSH SDK 子代理转入官方后台任务后，也会归到所属主对话。Notch 只读取状态，不消费后台任务的完成通知。浏览器跳转和未加载会话的同步由 [dsh-notch-focus 助手](companions/dsh-notch-focus/README.md)提供；已有安装保留原目录更新即可。入口、取消与恢复路径的检查范围见[源码兼容性审计](docs/subagent-compatibility.md)。

## 常见安装问题

| 现象 | 检查位置 |
| --- | --- |
| `plugin add` 成功，但没有 Notch | 第二步是否激活了 Host 插件，第三步是否启动了原生程序？两者都需要。 |
| 只有机器人，真实任务不出现 | Host 插件是否加载、`runtime.json` 是否生成、当前 Host 是否仍在运行？ |
| 找不到 `dsh-notch` 模块 | 确认第一步和第二步使用同一个 `DSH_HOME` 与 `web` profile；本地源码目录不能删除或移动。 |
| `IDLE_RESOURCES` 少于 `10/10` | 重新构建；移动程序时同时携带资源 bundle。 |
| 屏幕上出现两个 Notch | 检查是否同时启动了手动版本和 App 壳管理的版本，只保留预期的那一份。 |
| 更新源码后仍是旧效果 | 重新构建，并更新实际运行的可执行文件；只 `git pull` 不会替换已启动的原生进程。 |

若状态灯叠影、点击后才恢复，可按发生时间查看 `~/.dsh/dsh-notch/presentation.jsonl`。日志只记录计数、动画阶段、布局和进程编号，不记录对话正文、标题或认证信息；达到 256 KiB 后轮换，只保留当前和上一份。刷新时会检查过期的转场并补做收尾，菜单交互期间也继续推进状态与布局计时器。

当前 Host 插件依赖 `sessions`、`webServer`、`approval`、`userQuestions`、`agents` 服务，面向同一台 Mac 上的 DSH Web Host。原生界面的会话跳转优先唤起官方 `com.deepseek.dsh` 桌面版，并保留旧 `local.dsh.desktop` 壳的兼容。多 Home、远程 Host 和各版本 DSH 的兼容性不能只凭安装成功判断。

## 更新与开发

更新已安装的源码后，重新构建原生程序。只改原生界面时，更新并重新启动 Notch 即可；若改了 `src/` 下的 Host 插件代码，先 `npm run build` 更新 `lib/index.mjs`，再做对应的服务端热加载。

使用 [dshx](https://github.com/aa2246740/dsh-external-plugin-devkit) 的维护者可先执行 `dshx activation-plan dsh-notch --change artifact` 或 `--change server`，按实际修改范围更新。激活要匹配实际 Host 和挂载方式，不能把复制原生二进制当作 Host 模块热更新。

开发检查：

```sh
npm ci
npm test
npm run test:outcome
npm run test:motion
npm run test:geometry
npm run test:scrollbar
npm run test:expanded-height
npm run test:host-lifetime
npm run test:idle
npm run build:macos
```

弹性收纳交互可在 [独立原生预览](tools/elastic-preview/README.md) 中试用；运行 `npm run build:elastic-preview` 构建，不连接 DSH、不调用模型，也不替换当前安装。

### 录屏 Demo（可选）

用于开发、检查动画或录制演示视频，**不属于插件安装步骤**：

```sh
npm run build:demo
open "dist/DSH Notch Demo.app"
```

Demo 提供 36 个中英双语场景，使用本地假任务，不连接 DSH。录屏控制与快捷键见 [Demo 文档](tools/recording/README.md)。

更多：[动效说明](macos/STATUS-MOTION.md) · [设计说明](DESIGN.md) · [0.3.0 更新记录](docs/releases/v0.3.0.md) · [可选 App 壳诊断](tools/desktop-shell/README.md)。

## 许可

[MIT](LICENSE)。机器人资源基于 [OpenBotMotion](https://github.com/aa2246740/open-bot-motion)，保留了原始 [MIT 许可声明](tools/idle/LICENSE.open-bot-motion)。这是社区维护的 DSH 插件。

官方桌面版的原生启动适配与验证见 [0.1.7-rc.2 验证记录](docs/desktop-017rc2.md)。`DSH_NOTCH_RUNTIME_FILE` 只指定连接文件，绝不触发演示偏移；演示使用显式的 `--demo` 或 `--elastic-preview` 入口。
