# DSH Notch

[中文](README.md) · [English](README.en.md)

**DSH Notch 是 DeepSeek Harness 的 macOS 插件。** 它把真实会话的运行状态、待回答问题和未读结果放在屏幕边缘：查看任务、直接回答问题、点击回到对应会话；空闲时显示待机机器人。

插件包含两部分：**装进 DSH 的 Host 插件**负责同步会话，**原生 Notch 程序**负责显示和交互。下面的安装步骤会装好这两部分。

## 安装

**0.3.2 正式适配 DeepSeek Harness 0.1.7-rc.2 Desktop / Web。** 在 DSH 前台打开已完成的会话，Notch 会同步清除未读结果；从 Notch 点击会话，也能回到 DSH。

### 1. 下载发布包

从 [v0.3.2 Release](https://github.com/aa2246740/dsh-notch/releases/tag/v0.3.2) 下载：

| 文件 | 用途 |
| --- | --- |
| `dsh-notch-0.3.2.tgz` | Host 插件，提供状态、问题和原生程序连接 |
| `dsh-notch-focus-0.1.1.tgz` | 客户端同步助手，负责双向会话跳转与已读同步 |
| `dsh-notch-0.3.2-macos-arm64.tar.gz` | macOS 14+、Apple Silicon 原生程序及机器人资源 |
| `SHA256SUMS` | 下载校验；与上述文件放在同一目录后执行 `shasum -a 256 -c SHA256SUMS` |

预编译包无需 Swift 或 DSHX。其他架构需从源码构建，尚未提供验收过的预编译包。

### 2. 在 DSH 安装两个插件包

**官方 Desktop：** 在应用内插件管理页安装 Host 和同步助手的两个 `.tgz`，确认都已启用，按应用提示完成加载，再重新打开页面。Desktop profile 由应用管理。

**Web：** 对运行中的 Host 使用相同的 `DSH_HOME`，在下载目录执行：

```sh
dsh plugin --profile web add "$PWD/dsh-notch-0.3.2.tgz"
dsh plugin --profile web add "$PWD/dsh-notch-focus-0.1.1.tgz"
```

两个包都声明了官方 `dsh.bundle.patch`。按插件管理器的提示加载，并重新打开页面；不要再手工追加同名 `insert`。已有安装应更新原条目，避免 Bundle 与旧手动配置重复挂载。

Host 加载后生成 `$DSH_HOME/dsh-notch/runtime.json`。这是插件管理的私有连接文件，不需要填写或分享。找不到它时，先检查 Host 插件的加载错误。

### 3. 解压并启动原生程序

```sh
tar -xzf dsh-notch-0.3.2-macos-arm64.tar.gz
cd dsh-notch-0.3.2-macos-arm64
./dsh-notch --verify-idle-resources
./dsh-notch
```

资源检查应输出 `IDLE_RESOURCES=10/10`。首次运行请保持终端打开；如果已有桌面启动器管理 Notch，更新它使用的那份程序即可。移动时始终把 `dsh-notch` 和 `DshNotch_DshNotch.bundle` 放在一起。使用自定义 `DSH_HOME` 时，原生程序和 Host 必须指向同一 Home。

可在 Host 插件配置中把 `helperPath` 设为已解压的 `dsh-notch` 的绝对路径，让插件随 Host 管理辅助进程；配置后按应用的插件加载提示生效。请勿同时手工启动另一份。

### 4. 确认同步正常

- 正在运行的主会话显示蓝色计数；完成、失败或等待回答显示对应状态。
- 点击 Notch 的会话，DSH 打开对应对话。
- 在 DSH 前台打开已完成的会话，Notch 清除该条未读状态；仍在运行的任务继续保留。
- 全部结果读完后，Notch 回到机器人待机。

Notch 跟随连接文件中的 Host 进程退出。临时请求失败不会让它退出；只关闭窗口而 Host 仍在后台运行时，它会继续显示任务。[桌面托管说明](desktop/README.md)介绍了辅助程序的退出与快速重启联动。

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

## Claude Code CLI / Desktop 插件

同一个原生 Notch 也可以显示 Claude Code 的会话、权限确认和 AskUserQuestion，并在面板里直接作答。插件位于 [`claude-code/`](claude-code/README.md)，本仓库本身就是插件市场：

```
/plugin marketplace add aa2246740/dsh-notch
/plugin install dsh-notch@dsh-notch
```

原生 helper 不需要改动；插件用本地 bridge 提供相同的 `/dsh-notch/*` 接口。详见 [插件说明](claude-code/README.md)。

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

从源码构建 Host 和原生程序需要 Node.js 24、Swift 6 / Command Line Tools：

```sh
npm ci --ignore-scripts --legacy-peer-deps
npm run build
npm run build:macos
```

同步助手的源码构建需要指向 RC2 checkout 的 DSHX；步骤见[助手说明](companions/dsh-notch-focus/README.md)。预编译发布包不需要这些开发工具。

开发检查：

```sh
npm ci --ignore-scripts --legacy-peer-deps
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

更多：[动效说明](macos/STATUS-MOTION.md) · [设计说明](DESIGN.md) · [0.3.2 更新记录](docs/releases/v0.3.2.md) · [0.3.0 更新记录](docs/releases/v0.3.0.md) · [可选 App 壳诊断](tools/desktop-shell/README.md)。

## 许可

[MIT](LICENSE)。机器人资源基于 [OpenBotMotion](https://github.com/aa2246740/open-bot-motion)，保留了原始 [MIT 许可声明](tools/idle/LICENSE.open-bot-motion)。这是社区维护的 DSH 插件。

官方桌面版的原生启动适配与验证见 [0.1.7-rc.2 验证记录](docs/desktop-017rc2.md)。`DSH_NOTCH_RUNTIME_FILE` 只指定连接文件，绝不触发演示偏移；演示使用显式的 `--demo` 或 `--elastic-preview` 入口。
