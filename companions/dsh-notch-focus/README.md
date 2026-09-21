# dsh-notch-focus

DSH Notch 的浏览器同步助手，负责把 Notch 的“打开对话”操作送到当前 DSH 页面，并同步未加载会话的未读状态。普通用户 fork 独立保留；只有 `origin: subagent` 的会话被排除。

已有安装可以继续使用原目录；更新源码、构建即可通过已有客户端 HMR 生效。不要重复安装同名助手。

同步协议第 3 版会区分任务完成和用户已读：只有获得焦点的页面正在查看该会话时，才发送带时间的阅读确认。另一个页面没有完成标记，不会让 Notch 的提醒消失。请同时更新 Notch Host 插件，以使用这套确认机制。

首次安装时，先配置 DSHX 指向当前 Harness checkout，然后在本目录执行：

```sh
pnpm install
DSHX_HARNESS=/absolute/path/to/deepseek-harness pnpm build
dsh plugin --profile web add "$PWD"
```

在同一 DSH Home 的 Web profile `cordis.patch.yml` 中追加以下项，保留已有配置：

```yaml
- insert:
    - id: dsh-notch-focus
      name: dsh-notch-focus
```

首次加入客户端后重新打开 DSH 页面。Host 不需要为这一步重启。Notch Host 插件和本助手必须使用同一个 Web Host。

This companion follows native Notch focus requests and mirrors cold-session unread state into the Notch Host. It supports any authenticated WebUI on the same Host. User forks remain independent; only durable subagent origins are filtered. Existing installations keep their current directory and use client HMR after rebuilding. For a new installation, build and add the package as above, insert its row into the same profile, then reopen the page for the new client graph. No Host restart is needed.
