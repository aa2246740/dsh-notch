# DSH Notch

[中文](README.md) · [English](README.en.md)

**DSH Notch 是 DeepSeek Harness 的 macOS 插件。** 它把真实会话的运行状态、待回答问题和未读结果放在屏幕边缘：查看任务、直接回答问题、点击回到对应会话；空闲时显示待机机器人。

插件包含两部分：**装进 DSH 的 Host 插件**负责同步会话，**原生 Notch 程序**负责显示和交互。下面的安装步骤会装好这两部分。

## 安装

### 准备条件

- macOS 14 或更新版本。
- 本机已有正常运行的 DSH Web Host；终端能使用 `dsh`、`pnpm` 和 `git`。
- Swift 6 或更新版本的 Command Line Tools。用 `swift --version` 检查；没有开发工具时先运行 `xcode-select --install`。

以下以默认的 `web` profile、`~/.dsh` 为例。若你的 DSH 使用自定义 `DSH_HOME`，插件安装命令必须使用同一环境，第二步也要编辑该 Home 下的 profile 文件。

### 1. 下载并安装 Host 插件

```sh
git clone https://github.com/aa2246740/dsh-notch.git
cd dsh-notch
dsh plugin --profile web add "$PWD"
```

这条命令把本地插件目录链接到 DSH 的 Web profile。请保留这个目录，后面还要在这里构建 Notch。

如果看到 `declares no dsh.bundle — installed as a plain dependency`，这是当前包的预期提示：**包已经装入，继续第二步把插件加入运行配置。** 当前版本没有声明自动挂载的 bundle，单独执行 `plugin add` 还不会显示 Notch。

<details>
<summary>从 Harness 源码运行，没有全局 dsh 命令？</summary>

在 Harness checkout 里运行它自己的 CLI，使用刚下载插件的绝对路径：

```sh
pnpm dsh plugin --profile web add /absolute/path/to/dsh-notch
```

然后回到 `dsh-notch` 目录继续下面的步骤。

</details>

### 2. 在 DSH 中激活插件

打开 `~/.dsh/profiles/web/cordis.patch.yml`，在现有 YAML 列表中追加下面这一项。文件不存在时可新建；**保留已有配置，同一个 `id` 只添加一次**。

```yaml
- insert:
    - id: dsh-notch
      name: dsh-notch
```

这里的 `name: dsh-notch` 从第一步安装的 profile 依赖中解析。不要直接复制仓库内的 `cordis.yml`：里面的相对路径用途不同。

标准 Web profile 会监听这份配置并热加载插件。若 DSH 正在运行，保存后等它加载即可；尚未启动 DSH 时，用你原来的启动入口启动它。成功后，Host 日志会出现 `[my-plugins/dsh-notch] loaded`，并生成 `~/.dsh/dsh-notch/runtime.json`。

该文件包含 Notch 的本机连接信息，由插件自动管理，不需要手动填写或把内容发给 Agent。如果没有生成，先检查 Host 是否报 YAML、模块解析或缺少服务的错误，再继续第三步。

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

Notch 使用原生 AppKit / SwiftUI / Canvas 渲染。动画本身不调用模型。窗口随内容展开，达到屏幕高度上限后滚动；系统开启“减少动态效果”时呈现静态状态。

## 常见安装问题

| 现象 | 检查位置 |
| --- | --- |
| `plugin add` 成功，但没有 Notch | 第二步是否激活了 Host 插件，第三步是否启动了原生程序？两者都需要。 |
| 只有机器人，真实任务不出现 | Host 插件是否加载、`runtime.json` 是否生成、当前 Host 是否仍在运行？ |
| 找不到 `dsh-notch` 模块 | 确认第一步和第二步使用同一个 `DSH_HOME` 与 `web` profile；本地源码目录不能删除或移动。 |
| `IDLE_RESOURCES` 少于 `10/10` | 重新构建；移动程序时同时携带资源 bundle。 |
| 屏幕上出现两个 Notch | 检查是否同时启动了手动版本和 App 壳管理的版本，只保留预期的那一份。 |
| 更新源码后仍是旧效果 | 重新构建，并更新实际运行的可执行文件；只 `git pull` 不会替换已启动的原生进程。 |

当前 Host 插件依赖 `sessions`、`webServer`、`approval`、`userQuestions`、`agents` 服务，面向同一台 Mac 上的 DSH Web Host。原生界面的会话跳转会唤起 bundle ID 为 `local.dsh.desktop` 的 DSH.app；其他 App 壳的前台唤起需要适配。多 Home、远程 Host 和各版本 DSH 的兼容性不能只凭安装成功判断。

## 更新与开发

更新已安装的源码后，重新构建原生程序。只改原生界面时，更新并重新启动 Notch 即可；若改了 `src/` 下的 Host 插件代码，还需要对应的服务端热加载。

使用 [dshx](https://github.com/aa2246740/dsh-external-plugin-devkit) 的维护者可先执行 `dshx activation-plan dsh-notch --change artifact` 或 `--change server`，按实际修改范围更新。安装文档中的首次配置属于 watched patch，不能用重启整个 Host 代替缺失的安装步骤。

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
