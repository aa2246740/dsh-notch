# dsh-notch-focus 0.1.2

DSH Notch 的客户端同步助手。0.1.2 源码的 `@deepseek-ai/dsh-*` peer 为 `>=0.2.0-rc.1 <0.2.1`，对应 DeepSeek Harness **`dsh-v0.2.0-rc.1` Desktop / Web**，与 `dsh-notch` 0.3.3 同时更新。该范围接受 `0.2.0-rc.1` 和稳定版 `0.2.0`，拒绝 `0.2.0` alpha，也拒绝 `0.1.7-rc.2`。已发布的 0.1.1 包仍在 v0.3.2 Release 里。

- 从 Notch 点击会话，通过 RC2 的 `uiWorkspace.openSession` 打开对话。
- 从 RC2 `uiSession.sessionStatus` 读取未读完成状态，通过 `retainedBy.mainView` 识别当前会话。
- 仅前台页面查看已完成会话时发送带时间的阅读确认；后台页面、仍运行的会话不会清除未读结果。
- 保留用户 fork，只排除 `origin: subagent` 的子代理；允许 API 创建的自定义会话 ID。
- 首次轮询忽略旧跳转请求，避免重新打开页面时意外切换会话。

## 安装

下载 [Notch v0.3.2 Release](https://github.com/aa2246740/dsh-notch/releases/tag/v0.3.2) 的 `dsh-notch-focus-0.1.1.tgz`，与 Host 插件安装到同一个 profile。

Desktop 使用应用内插件管理页；Web 使用：

```sh
dsh plugin --profile web add /absolute/path/to/dsh-notch-focus-0.1.1.tgz
```

包内已有官方 `dsh.bundle.patch`，不要再手动追加同名条目。按管理器提示完成加载并重新打开页面；已有安装更新原条目。只替换磁盘文件不代表当前页面已加载新代码。

## 从源码构建

开发者需要 Node.js 24、DSHX 0.9.2（git 分支，不用 npm 上的旧版）和已备好依赖的 **`dsh-v0.2.0-rc.1`** Harness checkout。在本目录运行：

```sh
npm ci --ignore-scripts --legacy-peer-deps
DSHX_HARNESS=/absolute/path/to/deepseek-harness npm run build
```

编译只写本插件的 `lib/`。客户端产物为 `lib/client.js`，使用 DSHX 的外部构建适配器。发布包已经带有该产物，安装者无需源码构建或 DSHX。

## English

The 0.1.2 companion source targets DSH `dsh-v0.2.0-rc.1` Desktop and Web with Notch 0.3.3. Its `@deepseek-ai/dsh-*` peer is `>=0.2.0-rc.1 <0.2.1`: that accepts `0.2.0-rc.1` and stable `0.2.0`, and rejects `0.2.0` alphas and `0.1.7-rc.2`. It uses `uiWorkspace.openSession`, `uiSession.sessionStatus`, and main-view retention for bidirectional navigation and timestamped reading acknowledgements. Inactive pages and running sessions cannot clear unread results. User forks remain independent; delegated subagents are excluded. The published 0.1.1 tarball remains on the v0.3.2 release.

Install the prebuilt `.tgz` from the linked release using the Desktop Plugins page or the Web CLI above. Both plugins must use the same profile. The package supplies its Bundle patch; do not mount it again manually. Follow the manager's loading instructions and reopen the page. Client HMR in every Desktop variant is not claimed.
