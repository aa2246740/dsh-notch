# dsh-notch-win 移植规划

> 把 macOS 专属的 [dsh-notch](https://github.com/aa2246740/dsh-notch)（DSH 原生任务胶囊）移植为 Windows 11 版本。
>
> 状态：**Phase 0/1/2/3 已完成 ✅**，Phase 4（StatusOrbit 四态笔画）未开始；详见 §15 执行记录
> 日期：2026-09-14
> 上游版本：dsh-notch 0.3.0（MIT）

---

## 0. 结论摘要

| 结论 | 说明 |
|---|---|
| 可行性 | **高**。真正"只适配 mac"的只有 UI helper，Host 插件层完全跨平台 |
| 可复用 | Host 插件层 `src/*.ts`（~700 行）**一行不改**；HTTP+SSE 契约、`runtime.json` 全部沿用 |
| 需重写 | macOS 原生 UI 层 2,709 行 Swift（AppKit + SwiftUI + Canvas） |
| 意外收获 | 机器人动画的 **JS 源码自包含可复用**，9.4MB JSON 与 413 行 Swift 插值都不用移植 |
| 最大风险 | WebView2 透明窗口，已在计划中前置 spike，并备有 Acrylic 兜底方案 |

三项已定决策（用户选定）：**① WebView2 + C# WinForms 外壳 ② 胶囊贴屏幕右上角 ③ 一次做到完整还原**。

---

## 1. 背景与目标

用户需求原话：

> "https://github.com/aa2246740/dsh-notch 我想让你安装这个插件，不过这个插件貌似只适配mac，你能改成适配win11系统吗，不需要干活，先思考规划"

dsh-notch 是 DSH 的"任务胶囊"：常驻屏幕边缘，实时显示运行中的任务、待决策、未读成功/失败；点击选项可直接回答问题，点击标题可回到 DSH 查看上下文；空闲时显示机器人动画。

**目标**：在 Windows 11 上做出功能与观感对齐的等价物，且不修改 DSH 本体、不破坏上游 macOS 实现。

---

## 2. 调研结论：macOS 专属边界在哪

上游仓库结构（`git clone` 后逐文件核对）：

| 层 | 文件 | 行数 | Win11 可用性 |
|---|---|---|---|
| **Host 插件层** | `src/dsh-notch.ts` | 53 | ✅ 原样 |
| | `src/board.ts` | 299 | ✅ 原样 |
| | `src/http.ts` | 195 | ✅ 原样 |
| | `src/types.ts` | 55 | ✅ 原样 |
| | `src/store.ts` | 41 | ✅ 原样（`homedir()` 跨平台） |
| | `src/browse-sync.ts` | 59 | ✅ 原样 |
| | `src/session-state.ts` | 27 | ✅ 原样 |
| **原生 UI 层** | `macos/Sources/RootView.swift` | 1029 | ❌ 重写 |
| | `macos/Sources/StatusOrbit.swift` | 615 | ❌ 重写（动效核心） |
| | `macos/Sources/IdleRobot.swift` | 413 | ❌ 重写（但可大幅简化，见 §7.3） |
| | `macos/Sources/NotchMarkdown.swift` | 249 | ❌ 换库 |
| | `macos/Sources/main.swift` | 146 | ❌ 重写 |
| | `macos/Sources/Panel.swift` | 141 | ❌ 重写 |
| | `macos/Sources/Client.swift` | 116 | ❌ 重写（逻辑照搬） |
| | `macos/Sources/ReviewStudio.swift` | 309 | ⛔ 不移植（开发工具） |
| **资源** | `macos/Sources/Resources/Idle/*.json` | 13 段 / 9.4MB | ⛔ 不需要（改用 JS 源码） |

Host 层的运行时依赖只有 `node:http` / `node:crypto` / `node:fs` / `node:os`，无第三方包。`mode: 0o600` 在 Windows 被忽略（无害）。

**一个必须澄清的事实**：0.3.0 的 `/dsh-notch/approve` 与 `board.holdApproval` 实际是**死代码** —— `dsh-notch.ts:44-46` 注释明确写了故意不拦截工具审批（避免后台 agent 工具跑沙箱检查时误报）。所以**本插件的交互重心是"回答 AskUserQuestion"**，不是审批按钮。Windows 版按事实实现，不伪造审批功能。

---

## 3. 架构契约

```
┌─────────────────── DSH Host (Node/TS，跨平台，不改) ───────────────────┐
│ ctx.sessions / ctx.agents / userQuestions                              │
│   └─► Board（聚合快照，含 busy / unread / lastTurn / ask）              │
│   └─► attachHttp：在 ctx.webServer 挂 /dsh-notch 前缀路由               │
│   └─► store：写 ~/.dsh/dsh-notch/runtime.json { origin, token, pid }    │
└────────────────────────────────┬───────────────────────────────────────┘
                                 │ loopback HTTP + Bearer token
┌────────────────────────────────┴───────────────────────────────────────┐
│              Windows Helper（本次要写的部分）                           │
│   C# 外壳：窗口层 + NotchClient(HTTP/SSE)   ◄──postMessage──►  WebView2 │
└────────────────────────────────────────────────────────────────────────┘
```

### 3.1 HTTP 接口清单（`src/http.ts`）

| 方法 | 路径 | 鉴权 | 用途 |
|---|---|---|---|
| GET | `/dsh-notch/status` | Bearer | 拉快照 |
| GET | `/dsh-notch/events` | Bearer | SSE 实时推送 |
| POST | `/dsh-notch/answer` | Bearer | 回答 AskUserQuestion |
| POST | `/dsh-notch/seen` | Bearer | 清除未读（`sessionId` 或 `all`） |
| POST | `/dsh-notch/focus` | Bearer | 请求 DSH 页面跳到该会话（60s 内有效） |
| POST | `/dsh-notch/approve` | Bearer | 审批（当前为死代码，仅保持契约） |
| GET | `/dsh-notch/pending-focus` | 同源信任 | 供 DSH 页面消费"回焦"请求 |
| POST | `/dsh-notch/sidebar` | 同源信任 | DSH 侧栏同步会话列表（防后台标签页覆盖） |

loopback 判定：`127.0.0.1` / `::1` / `::ffff:127.0.0.1`。令牌亦可走 `?token=` 查询参数。

### 3.2 数据契约（`src/types.ts`）

```ts
NotchSnapshot { ok, generatedAt, sidebarSyncedAt?, origin, rows: NotchRow[] }
NotchRow      { id, title, child, busy, unread, lastTurn?, approval?, ask? }
NotchLastTurn { at, kind, failed }
NotchAsk      { id, questions: NotchQuestion[] }
NotchQuestion { id, question, detail?, header?, options?[], multiSelect?, intent? }
NotchApproval { id, toolName, reason? }
```

排序规则（`board.ts:100`）：待处理 > 运行中 > 未读 > 最近一轮时间。

### 3.3 运行时文件

- 路径：`%USERPROFILE%\.dsh\dsh-notch\runtime.json`
- 内容：`{ origin, token, pid, writtenAt }`
- 上游支持环境变量 `DSH_NOTCH_RUNTIME_FILE` 覆盖路径（用于走查/测试）—— **Windows 版必须同样支持**，既为测试也为拒绝测试时自动降级（上游在设了该变量时额外加 360pt 偏移避免与真胶囊重叠）。
- `seen.json` 与 runtime 同目录，由 Host 侧维护。

---

## 4. macOS → Windows 11 能力对照

| macOS 能力 | 出现位置 | Windows 方案 | 难度 |
|---|---|---|---|
| `NSPanel` 无边框 / `.nonactivatingPanel` / `level=.statusBar` | `Panel.swift:93-110` | `WS_POPUP` + `WS_EX_TOOLWINDOW` + `WS_EX_NOACTIVATE` + `SetWindowPos(HWND_TOPMOST)` | 中 |
| 透明背景 + `NSVisualEffectView .hudWindow` 毛玻璃 | `Panel.swift:114-133` | 主：`TransparencyKey` + WebView2 `DefaultBackgroundColor=Transparent`；备：`DwmSetWindowAttribute(DWMWA_SYSTEMBACKDROP_TYPE=DWMSBT_TRANSIENTWINDOW)` + `SetWindowRgn` | **中高（唯一真风险）** |
| `canJoinAllSpaces` / `.stationary` / `.fullScreenAuxiliary` | `Panel.swift:101` | 无精确等价物；普通置顶可用，**独占全屏盖不住**（接受降级） | 低 |
| 圆角 16pt / 只圆左侧两角 | `Panel.swift:123-124` | 主：CSS `border-radius`；备：`CreateRoundRectRgn` | 低 |
| `NSScreen.visibleFrame` + 跟随鼠标所在屏 | `main.swift:84-107` | `MonitorFromPoint` + `GetMonitorInfo().rcWork` | 低 |
| 20Hz `NSEvent.mouseLocation` 轮询做悬停 | `main.swift:71-72,114` | `GetCursorPos` + `System.Windows.Forms.Timer`(50ms) | 低 |
| 每帧 `setFrame` 弹性改窗口尺寸 | `Panel.swift:26-55` | **改为窗口恒定尺寸 + CSS 动画**（见 §7.4） | 中 |
| 减少动态效果 | `Panel.swift:33` | `SystemParametersInfo(SPI_GETCLIENTAREAANIMATION)` | 低 |
| `NSTextView` 的 Cmd+A/C/V/Z | `Panel.swift:62-91` | 原生控件自动支持 Ctrl+A/C/V/Z，整块删除 | — |
| `NSHostingView` + SwiftUI | 全 UI | HTML/CSS + Canvas 2D | **大** |
| `Canvas`/`CGPath` 自绘轨道 | `StatusOrbit.swift` | Canvas 2D，时间轴常量照搬 | **大** |
| 8MB×13 JSON 轮廓帧 + 逐帧插值 | `IdleRobot.swift` | **弃用**，改跑上游 JS 渲染器 | 低 |
| `NotchMarkdown` | `NotchMarkdown.swift` | marked / markdown-it | 低 |
| `swift build -c release` | `Package.swift` | `dotnet publish` | 低 |

---

## 5. 技术选型

| 方案 | 新增工具链 | 透明/置顶/穿透 | 动画复用 | 体积 | 判定 |
|---|---|---|---|---|---|
| **B. WebView2 + C# WinForms** | 需装 .NET SDK（一次性） | 需 ~150 行 P/Invoke | JS 源码直接跑 | ~5MB | ✅ **选定** |
| A. Electron | 无（缓存已有） | 各一行 API | 同上 | ~200MB | 备选（透明最省心） |
| C. 纯原生 C# | 需装 .NET SDK | 同上 | 需移植 413 行 + 9.4MB | ~2MB | ❌ 工作量最大 |
| D. 浏览器内挂件 | 无 | 做不到置顶/不抢焦点 | — | — | ❌ 不满足需求 |

选 B 的理由：产物小、无 Node 常驻、Win11 自带 WebView2 Runtime（本机 152.0.4191.66）、同样能复用 JS 动画源码。

---

## 6. 项目结构

```
D:\DSH\dsh-notch-win\              ← 上游 fork
├── PLAN.md                        ← 本文档
├── macos/                         ← 上游原样保留（便于日后给上游提 PR）
├── src/                           ← Host 插件，一行不改
├── tools/                         ← 上游原样（recording 等不移植）
└── windows/
    ├── DshNotchWin.sln
    └── DshNotchWin/
        ├── DshNotchWin.csproj     net8.0-windows / WinForms / x64
        ├── app.manifest           PerMonitorV2 DPI
        ├── Program.cs             单实例 Mutex、DPI、启动
        ├── NotchWindow.cs         窗口 + 悬停/穿透状态机
        ├── NativeMethods.cs       P/Invoke（见 §7.2）
        ├── NotchClient.cs         HTTP + SSE + 重连
        ├── RuntimeFile.cs         读 runtime.json（含环境变量覆盖）
        ├── Models.cs              镜像 §3.2 的 DTO
        ├── Bridge.cs              WebView2 postMessage 双向桥
        └── Assets/
            ├── notch/             index.html / app.js / style.css
            └── idle/              renderer.js / motions.js（上游 JS）
```

**单实例**：命名 Mutex `Global\dsh-notch-win`。上游明确警告"已有 helper 在跑时不要再起第二个"。

---

## 7. 关键设计

### 7.1 传输层放 C#，不放页面 JS（重要）

页面通过 WebView2 虚拟主机映射加载（`https://notch.local/`），而 API 在 `http://127.0.0.1:<port>`：**跨源**，且上游 `/dsh-notch/*` 不返回任何 CORS 头 —— 页面里 `fetch` 必被拦截。

因此：
- C# 侧 `NotchClient` 负责全部 HTTP/SSE，读 `runtime.json` 取 `origin` + `token`；
- 通过 `CoreWebView2.PostWebMessageAsJson()` 下行推送，页面用 `chrome.webview.postMessage()` 上行；
- **副作用是好的**：Bearer token 永不进入页面 JS，与上游 `http.ts:25-29` 的"no secret ever lands in page JS"立场一致。

### 7.2 窗口层与 P/Invoke 清单

窗口样式：`WS_POPUP` 无边框；叠加扩展样式 `WS_EX_TOOLWINDOW`（不进任务栏/Alt-Tab）+ `WS_EX_NOACTIVATE`（点击不抢前台焦点）+ `WS_EX_TOPMOST`。

| DLL | 函数 | 用途 |
|---|---|---|
| user32 | `SetWindowPos` | 置顶、移动（`SWP_NOACTIVATE`） |
| user32 | `GetWindowLongPtr` / `SetWindowLongPtr` | 动态切换 `WS_EX_TRANSPARENT` 做点击穿透 |
| user32 | `GetCursorPos` | 20Hz 悬停检测 |
| user32 | `MonitorFromPoint` / `GetMonitorInfo` | 取鼠标所在屏的工作区 |
| user32 | `SetForegroundWindow` / `GetForegroundWindow` | 文本输入时临时借焦点，结束归还 |
| user32 | `SetWindowRgn` | 兜底方案：圆角窗口区域 |
| user32 | `SystemParametersInfo` | `SPI_GETCLIENTAREAANIMATION` 读减少动效 |
| user32 | `SetLayeredWindowAttributes` | 色键透明（主方案） |
| gdi32 | `CreateRoundRectRgn` / `DeleteObject` | 兜底圆角区域 |
| dwmapi | `DwmSetWindowAttribute` | `DWMWA_SYSTEMBACKDROP_TYPE`(38) 开 Acrylic；`DWMWA_WINDOW_CORNER_PREFERENCE`(33) |

关键扩展样式值（实现时按 MSDN 复核）：`WS_EX_TOOLWINDOW=0x80`、`WS_EX_TRANSPARENT=0x20`、`WS_EX_LAYERED=0x80000`、`WS_EX_NOACTIVATE=0x8000000`、`GWL_EXSTYLE=-20`、`HWND_TOPMOST=-1`；
`DWMSBT_MAINWINDOW=2`(Mica)、`DWMSBT_TRANSIENTWINDOW=3`(Acrylic)；`SPI_GETCLIENTAREAANIMATION=0x1042`。

**点击穿透状态机**（对应上游 `main.swift:109-145`）：

```
收起 & 指针不在岛内   → 加 WS_EX_TRANSPARENT（点击穿透给下层应用）
指针进入岛矩形         → 移除 TRANSPARENT；若 needsAction 或 allowExpandOnHover → 展开
指针离开 & 展开中      → 0.38s 后折叠并恢复穿透（0.38s 内回来则取消）
需要键盘输入时         → 临时清 WS_EX_NOACTIVATE + SetForegroundWindow，输入结束还原
```

### 7.3 表现层与动画复用

**机器人动画（省下最大一块工作量）**

`tools/idle/renderer.js` 实测是自包含的（`root.OpenBotMotion = factory()`），**现场构建 SVG DOM**（`viewBox="-140 -140 280 280"`，分层 `bodiesLayer` / `botLayer` / `dotsLayer`），`motions.js` 暴露 `window.poseFor(id, time)`。上游的 9.4MB JSON 只是 `tools/idle/export.mjs` 用无头 Chromium 把同一套动画**烘焙**成极坐标轮廓帧供 Swift 插值用的产物 —— WebView 里根本不需要。

需移植的只剩 `IdleRobot.swift` 的**调度器**（约 40 行逻辑）：动作序列、静止间隔、稀有动作计时、防重复。渲染直接交给 JS。

性能优化：`renderer.js` 走 SVG DOM，192 点路径 × 30fps 在低端机上可能吃力；备选是借它的 `OpenBotMotion.SvgProjector` 算路径后自绘到 Canvas 2D，与上游 mac 的做法一致。

**状态轨道（StatusOrbit）**

需按 §8.2 的常量在 Canvas 2D 重实现四态笔画：蓝(运行) → 黄(决策)/绿(成功)/红(失败)，有向笔画 + 圆周收尾 + 并发多灯计数。契约文档见上游 `DESIGN.md`、`macos/STATUS-MOTION.md`、`docs/motion-continuity.md`。

### 7.4 尺寸与锚定

上游每帧改窗口矩形（0.4s smootherstep，锚点锁右上）。Windows 上改为：

**窗口恒定 480 × 最大高，内部胶囊用 CSS transform 缩放/位移。**

好处：避免每帧 `SetWindowPos` 的抖动与 WebView 合成开销，动画更顺；窗口层只需维护"岛矩形"用于穿透判定。
代价：一个较大的透明置顶窗口常驻，穿透逻辑必须严谨（放错会挡住右侧屏幕的点击）。

备选（更保守）：沿用上游做法，每帧 `SetWindowPos` + `SWP_NOACTIVATE|SWP_NOZORDER`，60fps 实测可接受则用它。

---

## 8. 设计常量表（从上游源码提取，用于对齐观感）

### 8.1 颜色（`RootView.swift` NotchTokens）

| 语义 | 值 |
|---|---|
| 决策/黄 | `#F2FF14` |
| 失败/红 | `#FF4000` |
| 成功/绿 | `#34C759` |
| 运行/蓝 | `#4D6BFE` |
| 胶囊底 | 纯黑 |
| 输入框底 | `#0F0F12` |
| 徽标底 | `#262626` |
| 芯片描边 | `white @ 0.28`（非选中 `0.20`） |
| 玻璃渐变 | 黑 `0.50@0 → 0.72@0.40 → 0.90@0.82 → 1.0@1.0` |
| 玻璃高光 | 白 `0.10@0 → 0.04@0.28 → 透明@0.72` |

### 8.2 时序

| 项 | 值 | 来源 |
|---|---|---|
| 状态笔画飞行 | **0.95s** | `StatusOrbit.swift:64` |
| 决策回复回程 | **0.98s** | `StatusOrbit.swift:312` |
| 决策旋转 | 0.62s | `StatusOrbit.swift:297` |
| 机器人离场 | 0.82s | `StatusOrbit.swift:326` |
| 蓝环重绘时长 | `(0.82 − 0.666) × 0.76` | `StatusOrbit.swift:463` |
| 窗口几何动画 | 0.4s，spring(bounce 0.08)；回退路径为 60fps smootherstep `x³(6x²−15x+10)` | `Panel.swift:4-11` |
| 折叠延迟 | 0.38s | `main.swift:144` |
| 悬停轮询 | 50ms（20Hz） | `main.swift:71` |
| 渲染帧率 | 60fps（`minimumInterval: 1/60`） | `StatusOrbit.swift:524` |

> 注：macOS 15+ 走 spring，14 走手写 smootherstep。Windows 版统一用 **smootherstep 路径**，保证与上游回退路径逐帧一致。

### 8.3 版式

| 项 | 值 |
|---|---|
| 展开最大宽 | 480pt |
| 收起尺寸 | 32 × 110pt |
| 顶边内缩 | 100pt |
| 紧凑高度（1/2/3 灯） | 44 / 72 / 100pt（Phase 4 起为**动画值**：`orbitLayout.height + 24`，由页面上报、宿主逐帧跟随） |
| 灯直径 | 19pt |
| 最大展开高 | `工作区高 − 2 × 顶边内缩` |
| 圆角 | 16pt |

所有 pt 值需按显示器 DPI 换算为物理像素（PerMonitorV2）。

### 8.4 待机调度（`IdleRobot.swift`）

| 项 | 值 |
|---|---|
| 基础动作（按序循环） | `blink, scan, tilt, nod, stretch, hop, balance, sneeze, sleep` |
| 静止间隔 | 随机 5–10s |
| 稀有动作 | `dance`，每随机 1200–2400s 一次 |
| dance 时长 | 随机 3–5s |
| 普通动作时长 | 该动作片段时长，缺省 7s |
| 防重复 | 下一动作不与上一个相同 |
| 其他 | 眨眼、变色龙彩蛋共用生产渲染器 |

---

## 9. 执行计划

按**风险前置**排序；交付目标仍是"一次做到完整还原"。

| 步 | 内容 | 验收 | 预估 |
|---|---|---|---|
| **0** | **Host 端接入验证（零 Windows 代码）**：镜像克隆 → profile 建 junction → `cordis.patch.yml` 加 insert → 重启 → 打 `/status` | 日志出现 `[my-plugins/dsh-notch] loaded`；`/dsh-notch/status` 返回含 rows 的 JSON；触发一次提问后 `ask` 字段出现 | 0.5d |
| **1** | **透明窗口 spike**：装 .NET SDK，验证透明/置顶/不抢焦点/点击穿透/200% DPI 多屏锚定 | 胶囊浮于其他窗口之上、点击穿透生效、前台应用不失焦 | 1d |
| 2 | 胶囊 UI + SSE 状态行 + 悬停展开折叠 | 状态实时变化；展开锚点锁右上；0.38s 延迟折叠 | 1.5d |
| 3 | AskUserQuestion 向导（单选/多选/自定义输入/markdown）+ 回焦 + 未读清除 | 在胶囊里答完，DSH 侧立即继续；点标题回到对应会话 | 1.5d |
| **4 ✅** | StatusOrbit 四态动效 | 四色笔画、0.95s/0.98s 时间轴、并发多灯计数、Reduce Motion 直显终态；收起态高度改由页面上报的动画布局驱动 | 2d |
| 5 | 待机机器人 | 9 动作 + 眨眼 + dance 彩蛋，间隔与时长符合 §8.4 | 1d |
| 6 | 安装/自启/卸载/回滚 + 全量验收 | 见 §11 | 0.5d |

---

## 10. 安装与接入方案（第 0 步细节）

本机现状：**没有 dshx**（上游 `dshx.yml` / `cordis.yml` 是给 dshx 用的），走的是 `dsh plugin` + `dsh.profile.bundles` + `dsh.bundle.patch` 体系；上游 `package.json` **未声明** `dsh.bundle.patch`，也没发 npm。故：

1. **先备份**（沿用用户既有习惯）：`package.json`、`cordis.patch.yml` 各存一份 `.bak-YYYYMMDD-HHMMSS`
2. 镜像克隆上游到 `D:\DSH\dsh-notch-win`
3. 在 profile 目录建 junction：
   ```
   mklink /J %USERPROFILE%\.dsh\profiles\web\dsh-notch D:\DSH\dsh-notch-win
   ```
4. 在 profile 的 `cordis.patch.yml` **追加 insert**（不要动 `bundles`）：
   ```yaml
   - insert:
       - id: dsh-notch
         name: './dsh-notch/src/dsh-notch.ts'
   ```
5. 重启 `npx @deepseek-ai/dsh web`，确认日志标记
6. 用 token 访问 `/dsh-notch/status` 验证

**两个必须避开的坑（已实测确认）**：

- **Node 类型剥离范围**：DSH 自身不带 tsx/esbuild/jiti，靠 Node 24 原生类型剥离加载 `.ts`，而 Node **拒绝剥离 `node_modules` 内的文件**。所以入口必须落在 `node_modules` 之外 —— 用 junction 的真实路径（`D:\DSH\dsh-notch-win`）就满足。
- **bundles vs patch**：`dsh.profile.bundles` 里挂的包必须在自身 `package.json` 声明 `dsh.bundle.patch`。上游没有，所以**不能塞进 bundles**（`pnpm add` 链接还会引入 realpath 二次风险），走 patch insert 最稳。

**冲突扫描结论**：插件 id `dsh-notch`、路由前缀 `/dsh-notch`、运行时目录 `~/.dsh/dsh-notch/` —— 与现有 15 条 bundles（dshmarket / agent-teams / whale-widget / better-sidebar / univer-office / wallpaper-engine / remote-web-ui / web-ui-settings / meow-memory / taskboard / builtin-browser / find-plugin / prompt-optimizer）**无任何交叉**。

依赖服务已核实存在：`sessions`、`webServer`、`approval`、`userQuestions`、`agents`（本机 dsh CLI 0.1.5-rc.1）。

---

## 11. 验收清单

> 逐条结论与证据见 **§6.4**（Phase 6 全量验收）。`[x]` = 已验证；`[!]` = 已验证但与本文原句不同（模型被用户改过）；`[~]` = 本机条件不足未实测；`[✗]` = 有意偏离。

**功能**
- [!] 空载竖条 —— 模型改为**贴边胶囊**（§15 Phase 1 追加二，用户选定）：30 pt 宽 × 空布局 44 pt
- [x] 1/2/3 个任务时高度 44/72/100pt（自检 35 / 94 / 95）
- [x] 状态实时跟随（SSE），断线自动重连（自检 49、118-120；实测 `/events` 有帧）
- [x] 在胶囊里回答问题后，DSH 侧立即继续（§3.6 真机日志；自检 58-76）
- [x] 多选题、自定义输入、长 markdown 详情（超长转滚动）均可用（自检 59-67、69-73）
- [x] 点标题回焦 DSH 对应会话（自检 28-32；seen/focus 由宿主进程发）
- [x] 未读可单条/全部清除（自检 53-57；`sidebar-seen.test.mjs` 5 项）

**窗口行为**
- [!] 悬停只高亮，**点击才展开**；答完/失焦折叠，锚点锁该侧边缘（用户选定；自检 15-18、36、74）
- [x] 收起时点击穿透到下层应用（自检 28/29、31）
- [x] 点击不抢走前台应用焦点（仅文本输入时临时借焦点并归还）（自检 30、32）
- [~] 多显示器 + 非 100% 缩放 —— 本机单屏 150% 实测通过（自检 1、10-27）；**没有第二块屏，多屏未实测**
- [x] Reduce Motion 开启时直接显示终态（自检 99/100、117）
- [x] 单实例（实测第二次启动 `exit=2 already running`）

**动效**
- [x] 四态颜色与 §8.1 一致（自检 92/93/96-98；`p4-*.png`）
- [x] 笔画飞行 0.95s / 决策回程 0.98s / 窗口几何 0.4s（自检 81-87、102/103；`orbit-math.test.mjs` 38 项）
- [x] 并发多灯计数正确；快速回复不被旧回调覆盖（自检 46/47、101-104、122-125）
- [x] 9 个待机动作 + 眨眼 + dance 彩蛋，间隔符合 §8.4（自检 106-111；`p5-*.png`）

**工程**
- [✗] DSH 侧零改动 —— **有意 3 处 fork 差异**（`src/board.ts`，+21/−2，修「全部已读」，见 §15 Phase 2 修复/修复二）
- [x] `macos/` 目录保持上游原样（`git status` 证实）
- [x] 可一键回滚（`windows/install/{install,uninstall}.ps1` + §6.3 沙箱往返 + 时间戳备份）

---

## 12. 风险与缓解

| # | 风险 | 等级 | 缓解 |
|---|---|---|---|
| 1 | **WebView2 透明窗口不稳**（本方案唯一真风险） | 高 | 第 1 步单点 spike；兜底改用 Acrylic 亚克力 + 圆角窗口区域（build 22631 已支持），视觉上等价于 mac 的 HUD 模糊 |
| 2 | `WS_EX_NOACTIVATE` 与文本输入抢焦点冲突 | 中 | 输入期间临时切样式 + `SetForegroundWindow`，结束还原；对照上游 `canBecomeKey` 行为 |
| 3 | 大透明窗口挡住下层点击 | 中 | §7.4 的岛矩形穿透判定必须有边界测试；保守方案回退到每帧改窗口尺寸 |
| 4 | 独占全屏（游戏/视频）盖不住 | 中 | 接受降级（mac 的 `.fullScreenAuxiliary` 无对应物），在文档中说明 |
| 5 | 右上角与通知中心/托盘冲突 | 低 | 留边距、可配置偏移；上游 `DSH_NOTCH_RUNTIME_FILE` 的 +360pt 偏移逻辑一并移植 |
| 6 | 令牌文件权限（`0600` 在 Windows 是空操作） | 中 | 用 NTFS ACL 收紧到当前用户；或改用 DPAPI 保护 |
| 7 | 上游分叉后同步困难 | 低 | `macos/` 与 `src/` 保持原样，只新增 `windows/`，便于上游 PR |
| 8 | 本机无 .NET SDK | 低 | `winget install Microsoft.DotNet.SDK.8`，可 `winget uninstall` 回滚 |
| 9 | 上游声明"不保证兼容所有 DSH 版本" | 低 | 本机 CLI 0.1.5-rc.1 与部分包 rc.2 有轻微错位，服务名已核实存在，留适配余量 |
| 10 | 9.4MB JSON 不参与后与上游视觉有细微出入 | 低 | JS 渲染器是这些 JSON 的**源头**，理论上更精确；Phase 5 与上游录屏比对 |

---

## 13. 明确不做

- `tools/recording`（36 场景录屏 demo）—— 纯演示工具
- `macos/Sources/ReviewStudio.swift` 与 `tools/review`（原生预览/审计）
- `tools/desktop-shell`（macOS 桌面壳诊断）
- `dshx` 集成、`macos/Tests/*` 原生 Swift 探针
- 审批按钮 UI（上游 0.3.0 本就是死代码）

---

## 14. 上游与许可

- 上游仓库：https://github.com/aa2246740/dsh-notch （MIT）
- 机器人资源源自 [OpenBotMotion](https://github.com/aa2246740/open-bot-motion)（MIT，须保留 `tools/idle/LICENSE.open-bot-motion`）
- 本移植为独立社区改编，非官方 DeepSeek 应用
- **本机网络提示**：GitHub 直连不可达，克隆/取文件需走镜像（`https://ghfast.top/https://github.com/...`）

---

## 15. 执行记录

### Phase 0 — Host 端接入验证（2026-09-14，**已完成 ✅**）

**做了什么**

1. 备份 profile 配置：`package.json` / `cordis.patch.yml` → `*.bak-20260914-124320`
2. 上游仓库落到 `D:\DSH\dsh-notch-win`（镜像浅克隆，`PLAN.md` 保留）
3. 建 junction：`%USERPROFILE%\.dsh\profiles\web\dsh-notch` → `D:\DSH\dsh-notch-win`
4. `cordis.patch.yml` 追加 `insert`：`id: dsh-notch`，`name: './dsh-notch/src/dsh-notch.ts'`

**唯一必要的源码改动（fork 差异 #1）**

预检时 Node 24 直接报错：

```
ERR_UNSUPPORTED_TYPESCRIPT_SYNTAX
TypeScript parameter property is not supported in strip-only mode
```

来源是 `src/board.ts:72`。把构造函数参数属性展开为显式字段（语义不变）：

```diff
-  constructor(private readonly ctx: Context) {}
+  private readonly ctx: Context
+
+  constructor(ctx: Context) {
+    this.ctx = ctx
+  }
```

全仓扫描确认这是**唯一**一处非可擦除语法；其余 6 个模块均可被 Node 24 直接 import。

**验证结果**

| 检查 | 结果 |
|---|---|
| Node 24 直接 import 6 个子模块 | 全部 OK，导出 `apply, inject, name` |
| 经 junction 路径 import 入口 | OK |
| 热加载（`patchReload: live`） | **未重启即生效**，`runtime.json` 1 秒内写出 |
| `runtime.json` | `origin=http://127.0.0.1:3080`、`pid=1872`（运行中的 dsh web）、token 48 字符 |
| `GET /dsh-notch/status` 无 token | HTTP **403** ✅ |
| `GET /dsh-notch/status` 带 token | `ok=true`，1 行，且**正是当前会话**、`busy=true` |
| `GET /dsh-notch/events`（SSE） | 首帧 `ok=true rows=1 origin=http://127.0.0.1:3080` |

**结论**：Host 插件层在 Windows 上**零适配可用**（除上述 1 处语法改写）。HTTP + SSE + Bearer 鉴权 + 会话聚合全部正常，无需重启 DSH。**下一个未解风险是第 1 步的 WebView2 透明窗口。**

**回滚方法**：删除 `cordis.patch.yml` 中的 dsh-notch 块（或还原 `cordis.patch.yml.bak-20260914-124320`），再删掉 junction `profile\dsh-notch`。插件未写入 `bundles`，无残留、无需 `pnpm install`。

### Phase 1 — 窗口层 spike（2026-09-14，**已完成 ✅**）

**目标**：验证透明 / 置顶 / 不抢焦点 / 点击穿透 / 多显示器锚定 —— 全流程中唯一不可预测的一环。

**产物**：`windows/DshNotchWin/`（`net8.0-windows` WinForms + WebView2 `1.0.4191.47`）

- `.NET SDK 8.0.425` 装到 `D:\DSH\.dotnet-sdk`，用官方 `dotnet-install.ps1` 的 **`-NoPath` 本地安装**：零提权、零系统改动、删除目录即完全回滚。
  （不用 `winget` 的原因：机器级安装会弹 UAC，而本会话审批提示已禁用，无法代点。）
- 窗口层：`NotchWindow.cs`（锚定 / 悬停 / 穿透状态机）+ `NativeMethods.cs`（P/Invoke）
- 表现层：`Assets/notch/index.html`，WebView2 经虚拟主机 `notch.local` 加载

**自检结果（`--selftest`，16 项全 PASS，退出码 0）**

| 检查 | 结果 |
|---|---|
| `PROCESS_DPI_AWARENESS == 2`（per-monitor） | PASS |
| `WS_EX_TOOLWINDOW` / `NOACTIVATE` / `TOPMOST` | PASS（`exstyle=0x080900A8`） |
| 色键透明配置 + WebView2 透明背景 | PASS |
| 锚定右对齐 / 顶边内缩 / 不越界 / 遵守收起尺寸 / 内缩钳制 | PASS |
| 点击穿透 ON→OFF 往返 | PASS（`0xA8` ↔ `0x88`） |
| 置顶操作不改变前台窗口 | PASS |
| WebView2 初始化 | PASS（runtime 152.0.4191.66） |
| 覆盖样式在 WebView2 初始化后仍存活 | PASS |

**截图证据**（程序自截，`--shot`，物理像素）：`windows/shots/p2-rest-right.png`、`windows/shots/p2-expanded-right.png`（Phase 1 spike 时的 `rest.png`/`expanded.png` 后来被 Phase 2 的 `p2-*` 一组取代，旧文件已删）

**实测行为**（物理像素，150% 缩放）：悬停 `48×165 @2512` → `720×390 @1840`，**右边缘恒为 2560**（锚点契约与上游 `Panel.swift` 一致）；移开约 1s 后自动回到 `48×165`。

**过程中踩到的三个坑（已修，并加回归防护）**

1. **WinForms 会抹掉提前设置的 `WS_EX_*` 位**。构造函数里 `TransparencyKey` / `ShowInTaskbar` 等 setter 各触发一次 `UpdateStyles()`，把 `TOOLWINDOW` / `NOACTIVATE` 冲掉 —— 自检最初报 `exstyle=0x00090008` 即此。修法：样式改到窗口显示后施加并带 `SWP_FRAMECHANGED`；自检新增"样式存活"一项做回归防护。
2. **自检顺序错误**。`base.OnShown(e)` 会*同步*触发 `Shown` 事件，自检正跑在该事件里；`ApplyOverlayStyles()` 原先写在 `base.OnShown` 之后，导致自检读到未施加的状态。修法：移到 `base.OnShown(e)` **之前**。
3. **`SetClickThrough` 的缓存失同步**。样式位被外部抹掉后缓存仍是 `true`，再次调用被当成 no-op 跳过。修法：改为**读回真实样式位**（自愈），不再信任缓存。

**一次误诊（记录在案）**：用 PowerShell 测得窗口 `32×110 @1675`、右边缘 1707，据此判断"进程 DPI-unaware"。**该结论是错的** —— PowerShell 自身 DPI-unaware，看到的是 1/1.5 的虚拟化坐标。程序自身日志写明 `awareness=2 hwndDpi=144 scale=1.5 bounds={2512,150,48,165}`，右边缘 2560，一直是对的。虽属误诊，仍顺手把 DPI 感知从 `Application.SetHighDpiMode()` 改为在 `app.manifest` 声明（由 OS 在进程启动时施加，与调用顺序和启动方式均无关），并在自检中加入 `PROCESS_DPI_AWARENESS==2` 断言，使该类问题今后可自动发现。

**结论**：**WebView2 透明窗口方案成立** —— 计划中标注的"唯一真风险"已排除，无需启用 Acrylic 兜底方案。放大图确认胶囊之外的桌面内容完整透出，无品红色键边缘。

### Phase 1 追加 — 交互模型调整与一个致命陷阱（2026-09-14）

**用户反馈**："我现在不能移动它啊"（原设计照搬上游 `isMovable = false`）。澄清后用户选定：**① 加拖动并记住位置；② 悬停改为"点击才展开"**。

**已实现**

- `WindowPlacement.cs`：位置持久化到 `%USERPROFILE%\.dsh\dsh-notch\window.json`，存的是**右上角锚点**（胶囊只向左下生长，存角不会因尺寸切换而漂移）；支持 `DSH_NOTCH_WINDOW_FILE` 覆盖（测试不污染真实配置，与上游 `DSH_NOTCH_RUNTIME_FILE` 同思路）；加载时钳制回屏幕内，防止拖丢。
- **锚点模型**：所有尺寸变化都围绕固定的右上角，`expand/collapse` 不再每次用光标所在屏重算 —— 否则刚拖走就会被弹回。
- **点击展开**（悬停仅高亮 + 指针光标）；**双击或右键背景复位**到右上角。
- **拖动**由 C# 侧 20Hz 轮询驱动（`GetAsyncKeyState` 判按键），因此鼠标在窗口外松开也能正确结束（窗口从不夺取捕获）。

**致命陷阱：`TransparencyKey` 与"能接收鼠标"根本不兼容（已修）**

- **现象**：胶囊外观完全正常，但**所有点击都穿透到背后的浏览器**，点击、拖动全部无效。
- **诊断**：`WindowFromPoint` 在胶囊中心返回的是**背后 Edge 的窗口**（pid 19252），而不是胶囊或其 WebView2 —— 且是在 `WS_EX_TRANSPARENT` 已清除（`exstyle=0x08090088`）的前提下。
- **根因**：WinForms 的 `TransparencyKey` 实现为分层色键（`WS_EX_LAYERED` + `LWA_COLORKEY`）。WebView2 渲染窗口是**子窗口**，其像素不参与父窗口分层表面的色键计算，于是 Form 自身表面**整块都是品红色键** → OS 判定**整个窗口**对命中测试透明。显示正常只是因为子窗口画在了上面。
- **修法**：放弃色键透明，改用 **`SetWindowRgn` 裁剪胶囊轮廓** —— 区域同时负责裁剪与命中测试，且完全不需要分层。代价：圆角变为硬边、失去投影（已挂 `CS_DROPSHADOW` 寻回一点）。
- **回归防护**：自检新增 `hit-test reaches capsule`，在关闭穿透的前提下用 `WindowFromPoint` 断言命中落在自己窗口内。**这正是能抓住该 bug 的检查 —— 而此前所有几何检查全部通过。**

**三个次生缺陷（均已修）**

1. **区域尺寸错误**：`ApplyRegion()` 内联在 `ApplySize()` 里调用时，`ClientSize` 尚未更新（实测 26×109 vs 真实 48×165），画面被裁切。修法：新增 `OnClientSizeChanged` 兜底，区域始终跟随真实客户区。
2. **圆角弧线角度写反**：GDI+ 角度以 3 点钟为 0° 且**顺时针**增长，上左角应为 `180°→270°`（我误写成 `90°→90°`），结果切出**内凹缺口** —— 而包围盒检查依然显示 `48×165` 通过，**只有截图能看出来**。
3. **双击复位失效**：收起态下第一次点击就会展开并**改变窗口尺寸**，第二次点击落到不同 DOM 节点，Chromium 不再报 `dblclick` → 收起态永远无法双击复位。修法：双击检测移到 C# 侧（点击时间戳），右键复位保留。

**教训（已写入记忆库）**：**几何断言全绿 ≠ 视觉正确**。命中测试与视觉渲染是两套独立机制，必须分别断言 —— 前者用 `WindowFromPoint`，后者用 `--shot` 截图。

### Phase 1 追加二 — 贴边吸附模型（2026-09-14，用户选定）

**用户要求**：①胶囊**一直吸附在屏幕边缘**；②**拖动只能上下**；③**双击改为切换到另一侧屏幕边缘**。

**模型简化**：位置从"自由坐标"变成 **`(edge, top)`** —— 胶囊永远挂在左边缘或右边缘，只能纵向滑动，因此不可能停在桌面中间。

- `window.json` 新格式 `{ edge, edgeX, top, savedAt }`。`edgeX` 记录吸附边所在的显示器，多屏下能回到同一块屏。
- **旧格式自动迁移**（`topRightX/topRightY`）：按锚点落在工作区左半还是右半推断贴哪条边，用户已拖好的位置不会丢。
- **拖动只取纵向位移**（横向位移被忽略），并在拖动过程中就钳制在工作区内，不会拖出屏幕。
- **双击 = 切换左右边缘**（保留纵向位置与展开状态）；**右键 = 回到该边的默认高度**（逃生口）。
- **圆角随边缘镜像**：贴右边→圆左角（同上游），贴左边→圆右角。窗口区域与页面 CSS 两处必须同步切换，否则会出现"圆角对着屏幕边缘、方角对着桌面"。
- 因双击语义变化，双击检测仍留在 C# 侧（点击时间戳）—— 收起态下第一次点击会改变窗口尺寸，页面永远收不到 `dblclick`。

**新增自检项（共 31 项全 PASS）**：`snaps to right edge`、`snaps to left edge`、`expand grows away from edge`、`expand keeps outer edge`、`region follows the edge`、`clamps bottom/top inside work area`、`placement round-trips`、`placement resolves`、`legacy placement migrates`。

**截图证据**：`windows/shots/p2-rest-right.png`、`windows/shots/p2-rest-left.png`、`windows/shots/p2-expanded-left.png`（左侧镜像圆角已确认；spike 时的 `right-rest.png`/`left-rest.png`/`left-expanded.png` 已被 Phase 2 的 `p2-*` 取代）。`--shot` 新增 `--edge left` 开关，且自动化路径**不写**用户的位置文件。

### Phase 1 追加三 — 阴影闪回与拖动流畅度（2026-09-14）

**用户反馈**：①单击展开后收起时会有阴影闪回；②希望拖动更流畅。

**① 阴影闪回 —— 根因是我自己加的 `CS_DROPSHADOW`**

之前为了让区域裁剪的窗口略有质感，挂了 `CS_DROPSHADOW`。但 DWM 是**按窗口区域**绘制投影的：收起时区域从 720×390 瞬间缩到 48×165，**旧的大投影会先合成一帧**再跳成小的 —— 即用户看到的闪回。

修法：**移除 `CS_DROPSHADOW`**，并加自检项 `no drop shadow (flash-free)`（读 `GCL_STYLE` 断言 `0x20000` 位不存在）防止复发。胶囊最终无投影，这是区域裁剪方案的既定代价。

**② 拖动流畅度 —— 换掉时间源，而不是调参数**

- 第一版只把轮询 50ms → 8ms 并 `timeBeginPeriod(1)`。**实测仍只有 64 Hz（15.6ms）**，日志明确记录 `interval=8ms resolutionRaised=True` 却毫无效果。
- 根因：WinForms `Timer` 底层是 `SetTimer`，而 **`WM_TIMER` 是低优先级、可被合并的消息** —— UI 线程一忙就退化到系统 tick（~15.6ms），与 interval 和 timer resolution 都无关。
- 查显示器：**240 Hz**。64 Hz 意味着每个刷新周期重复 3~4 帧，必然显得顿 —— 这解释了用户的主观感受。
- 正解：拖动期间 `SetCapture(Handle)`，改由 **`WM_MOUSEMOVE`** 驱动（按鼠标设备速率送达，不受低优先级定时器限制）；保留轮询作**安全网**（以物理按键状态判定），并处理 `WM_CAPTURECHANGED`，确保捕获丢失时手势与捕获都不会卡死。
- 实测：**131–150 Hz**（突破并远超原来 64 Hz 的天花板），且 `captureAfterRelease=0x0` 证明捕获正常释放 —— 不会卡住整个系统的鼠标输入。

**自检项增至 33 项，全 PASS。**

**方法论**：两件事都**先量化再动手** —— 阴影闪回定位到具体 API 与具体帧；拖动则先测出真实更新率（64 Hz）与显示器刷新率（240 Hz），才判定"必须换时间源"。若只满足于"把 interval 调小了"，会误以为已经修好。

### Phase 2 — SSE 真实数据 + 状态行列表 + 0.4s 几何动画（2026-09-14）

**范围**（PLAN §9 第 2 步）：接上真实数据、把状态行列表画出来、窗口几何按上游时间轴动起来。
**不含**：AskUserQuestion 向导与选项提交（Phase 3）、StatusOrbit 四态笔画（Phase 4）、待机机器人（Phase 5）、审批按钮（上游 0.3.0 即死代码）。

#### 2.1 数据链路

```
runtime.json ──► NotchClient(GET /status 首帧)
                 └─► GET /events (SSE, text/event-stream)  ──► 每次变更一帧快照
                        │  断线 → 指数退避重连；重连前重读 runtime.json（DSH 可能换了端口）
                        ▼
                 NotchWindow.PushSnapshot() ──PostWebMessageAsJson──► 页面渲染
```

- 运行态只走 C#（跨源 + Bearer token 不进页面 JS，PLAN §7.1 既定决策）。
- 页面不理解时间轴：**宿主每帧下发窗口真实几何**，页面只做 reflow。这样宿主动画与内容不可能失步。

#### 2.2 高度模型（对齐上游矩阵）

| 状态 | 宽度 | 高度 | 依据 |
|---|---|---|---|
| 收起 | 32pt（`main.swift` restW） | `44 + 28 × (可见灯数 − 1)` | `OrbitLayout.height = 20+28·(total−1)` + 24（`RootView.swift:557`） |
| 展开 | 480pt | `clamp(页面上报内容高, 120, 工作区高 − 2×100)` | `RootView.swift:576-583`，`main.swift:93-94` |

可见灯数 = `round(top+middle+bottom+decision)`：绿(完成未读) / 蓝(运行) / 红(失败) / 黄(待决策)。四灯即 128pt —— 文档只写了 1/2/3 灯的 44/72/100，第 4 灯按同一公式延伸（四类状态可同时存在）。

#### 2.3 几何动画

- 时长 **0.4s**，缓动 **smootherstep** `x³(6x²−15x+10)`，逐字照搬 `Panel.swift:7-10`（上游 macOS 15+ 走 spring，14 走这条手写回退路径；Windows 统一走回退路径以保证可复现）。
- **不变量**：每帧保持"外侧边缘"（贴边那侧的 x）与顶部 y 不变 —— 即 `Panel.swift:32` 的 `maxX`/`maxY` 锚定，方向差异（macOS y 向上、Windows y 向下）不影响该不变量。
- 中断即重定向：目标变化时从**当前帧**重新计时（`cancelResize` + generation 计数），旧回调按代际丢弃 —— 同 `Panel.swift:19-31`。
- Reduce Motion：直接落终态，不逐帧。（`SPI_GETCLIENTAREAANIMATION`，Phase 1 已有。）

**时间源（Phase 1 教训的直接复用）**：几何动画与拖动面临同一个敌人 —— `WM_TIMER` 被钉死在 ~64Hz，而本机是 **240Hz** 屏。因此动画**不复用 WinForms Timer**，而是专用线程：

```
timeBeginPeriod(1) → 线程循环：按 Stopwatch 算 t → smootherstep → 直接调
SetWindowPos(SWP_NOACTIVATE|NOZORDER) + SetWindowRgn
```

`SetWindowPos`/`SetWindowRgn` 是跨线程安全的窗口管理器调用（这正是上面两处避免碰 WinForms 状态的原因）；结束恢复 `timeEndPeriod(1)`。**实测帧率写进日志与自检**，不接受"应该够快"。

#### 2.4 区域裁剪逐帧重建

区域同时负责**裁剪**与**命中测试**（Phase 1 的致命陷阱结论）。逐帧重建用**行跨距矩形**而不是 `GraphicsPath`：GDI+ 路径每帧构造 + `GetHrgn` 成本高，而圆角外的每行可见区间有闭式解

```
弧心 xc，半径 r，行 y 在角内时的 dy = r − (y − yc)：
  dx = ceil(r − sqrt(max(0, r² − dy²)))      // 圆心在右侧 → 可见区间 [0, xc−dx]
  dx = floor(r − sqrt(max(0, r² − dy²)))     // 圆心在左侧 → 可见区间 [xc+dx, W]
```

把相邻的相同 `(left,right)` 行合并成少量矩形，再 `CreateRectRgn`+`CombineRgn` 组装；交给 `SetWindowRgn` 后**系统接管该区域**（不可再 DeleteObject）。宽度取整使圆角外缘与 GDI+ 圆角窗口区域逐像素一致。

#### 2.5 页面端

- 加入真实数据渲染：收起态是**灯栈**（彩色圆盘 + 计数，颜色/层级照 `StatusOrbit.swift:555-590`：绿在上 / 蓝居中 / 红在下 / 黄居中偏上），展开态是**会话列表**（徽标行 + 行列表 + 空态）。
- 行状态色优先级严格照 `RootView.swift:1000-1019`：`busy` > `isFailedResult` > `needsAction` > `unread` > 灰。
- 行点击 → `focus`（在 DSH 中打开该会话）；行右键 → 单条已读 `seen`；徽标行"清除" → `seen all`。所有可交互元素带 `data-no-drag`，不触发窗口拖动（Phase 1 已埋好该守卫）。
- 容器尺寸固定 480×260pt，靠**宿主下发的视口**裁剪；内容 `overflow: hidden`，动画期间自然"绽放"而不是整块缩放（缩放会把字号也缩掉）。
- 内容高由页面测量后上报（`height` 消息），宿主只在展开态采纳，并带抖动闸门避免尺寸反馈振荡。

#### 2.6 验收

| 项 | 方法 |
|---|---|
| 真实数据上屏 | 对着运行中的 DSH 打开 `/events`，断网/重启 DSH 后自动重连 |
| 高度矩阵 | 自检断言 1/2/3/4 灯的收起高度 = 44/72/100/128 |
| 几何动画 | 自检逐帧采样：外侧边与顶部恒定、宽高单调、0.4s 内落到终态、中途改目标不跳变 |
| 帧率 | 自检与运行日志记录实测动画帧率（基线：拖动 131–150 Hz） |
| 区域正确 | 沿用 Phase 1 的 `WindowFromPoint` 命中断言，动画中与动画后各测一次 |
| 视觉 | `--shot` 收起/展开、左右边各一张 |

### Phase 2 执行记录（2026-09-14，**已完成 ✅**）

**产物**：`NotchClient.cs`（runtime.json + HTTP + SSE + 重连 + seen/focus + 窗口激活）、`NotchModels.cs`（镜像 `src/types.ts`）、`SseParser.cs`（纯状态机）、`NotchGeometry.cs`（高度矩阵 + smootherstep + 行跨距区域 + 动画状态机）、`NotchWindow.cs` 扩展、`Assets/notch/index.html` 重写。

**验证结果**

| 检查 | 结果 |
|---|---|
| `--selftest` | **58 项全 PASS**（Phase 1 的 33 项 + 几何/动画/数据 25 项） |
| 真实数据 | `live snapshot received`：`http 200 rows=3 lamps=2 (busy=1 done=2)` — 与 `/status` 实测一致 |
| 高度矩阵 | 1/2/3/4 灯 = 44/72/100/128 ✅（0 灯与 1 灯同为 44，符合上游 `max(0,total−1)`） |
| 几何动画时长 | 实测 400–410 ms（`progress=1`），落点精确等于目标 |
| 几何动画帧率 | **220–450 Hz**（240 Hz 屏；对比拖动基线 131–150 Hz、WM_TIMER 天花板 64 Hz） |
| 不变量 | 外侧边与顶部 y 逐帧恒定、宽高单调、整数回退目标从当前帧重启 |
| 区域 | 动画后 `GetWindowRgnBox` 仍等于窗口客户区；`WindowFromPoint` 命中自身 |
| 视觉 | `windows/shots/p2-{rest,expanded}-{left,right}.png` |

**四个真坑（都是"看起来像 CSS bug"的宿主/管线问题）**

1. **`--no-incremental` 之外，资源不会重新拷贝**。改了 `index.html` 后普通 `build` 可能跳过 `Content` 拷贝（增量判定），于是连续两次截图**字节完全相同** —— 极容易被误判成"样式没生效"。诊断征兆：同一路径截图大小一字不差。
2. **WebView2 会把虚拟主机内容缓存到 exe 旁的 profile 目录**（`bin/.../dsh-notch-win.exe.WebView2`）。即使资源文件已更新，页面仍可能被**从缓存供给**，症状是"改了 HTML 却毫无变化"。修法：`--shot` 走 `CoreWebView2Environment.CreateAsync` + 临时 profile（轮转 3 个槽位，用完即删）；**但自检不能走这条路** —— 控件若已自建环境，`EnsureCoreWebView2Async` 会直接抛 `already initialized with a different CoreWebView2Environment`，自检就再也测不到渲染器了。
3. **物理像素 vs CSS 像素（本次最贵的一个）**。宿主按 PerMonitorV2 报告物理像素，页面按 CSS 像素布局；150% 缩放下把窗口宽 720 直接塞进 `--panel-w`，shell 就宽了 240px，**每行左侧的点与标题全被窗口裁剪掉**，只剩右对齐的文字 —— 看起来像"行没渲染"。修法：`toCssPx(physical, scale)`，几何消息里已经带了 `scale` 字段就是为了这个。
4. **收起态的内容块不能用 `flex:1` 填满 shell**。shell 永远按展开尺寸（480×260）布局、由窗口裁剪，所以 `#rest` 一旦填满 shell，两个灯就被竖直居中到 y≈130，**落在 72px 高的收起窗口之外** —— 截图里只有一个纯黑胶囊。修法：`#rest{height:100vh;flex:0 0 auto}`，按视口高度居中。

**另外两个必须记住的次生问题**

- **高度测量会反噬**：面板高度由页面测量内容得到，而内容高度又受可用宽度影响 → 若把**动画中的**窗口宽告诉页面，文字每帧重排、测量每帧变化，胶囊会以约 200 次/秒的速度在高度上来回追（实测 267→156→…）。修法三件套：页面宽度用恒定面板宽（480）+ `#list` 固定宽并从 `scrollbar-gutter:stable` 预留滚动条槽 + 只在 `settled` 时测量、且差值 <4px 不上报。
- **单位错误会伪装成"被采纳了"**：高度下限曾写成 `Scale(120pt)=180px`，而页面诚实测出的 3 行内容只有 177px —— 下限**赢**了，日志里 `raw=177` 却仍然输出 180。凡是把上游的 pt 常量当像素用时，都会犯这个错。

**`--shot` 新增行为**：截图前会主动向页面要一次重新测量（`measure` 消息），因为自动化从外部改了展开状态，页面看不到那一步。

### Phase 2 修复 — 「全部已读」按了没用（2026-09-14，用户报障）

**现象**：点「全部已读」后，收起态的绿灯与展开态的「N 完成」徽标不消失，看起来像按钮坏了。

**排查路线（先证伪"按钮没通"）**

1. 读 `~/.dsh/dsh-notch/seen.json`：时间戳恰好落在用户操作的时刻 → **Host 侧确实收到了 `/seen {all:true}` 并且写盘了**。这一步是关键，它把怀疑对象从"点击链路"缩小到"状态语义"。
2. headless 复现点击本身：给页面注入假 `chrome.webview`，`document.getElementById('clear').click()`，打印出站消息 → `sent types: ready, height, seen`，**按钮与桥路正常**。
3. 于是问题只可能在页面的**判定逻辑**：`isCompleted()` 里那句"兜底" —— `unread === true || (lastTurn && !lastTurn.failed)`。`unread` 被 Host 清成 `false` 之后，会话的 `lastTurn` 仍然存在且仍是成功态，于是这句兜底**永远为真** → 绿灯与"完成"徽标是**永久**的。

**根因**：兜底写得太宽。它本来只需要盖住 Host 的"busy→idle 第一帧还没标 unread"（board.ts:111-113 在**快照末尾**才刷新 running 集合）这一个 ~80ms 的窗口，却变成了"成功过就算未读"。上游 `completedUnreadRows` 的第一条件就是 `unread`（RootView.swift:150-152），正是这个道理。

**修法**：`isCompleted(row)` 只认 `row.unread === true`（并保留 `!busy && !failed && !needsAction`）。灯的计数与徽标直接采用 Host 的 `counts.completed`。

**回归证据（headless 对照）**：同一份 HTML，只把判定换回旧版，投喂"before：unread=true / after：unread=false"两帧快照：

| 版本 | before | after（模拟 Host 处理完 seen all） |
|---|---|---|
| 修复后 | 绿灯「2」+ 徽标「2 完成」+ 行尾「完成,完成」 | 绿灯消失、徽标消失、行尾标签消失，只剩 idle 灰点 |
| 旧逻辑 | 同上 | **绿灯「2」与徽标仍在**（复现用户报障） |

**教训**：**兜底条件永远不要比它要兜的问题更宽**。为了抹掉 80ms 的状态闪烁而放宽判定，代价是让一个"清除"动作变成永久无效 —— 而且 Host 侧完全正常，日志里看不出任何异常。另外：`--selftest` 里 59 项全绿也救不了这个 bug，因为它只断言窗口与几何，从不断言"点了按钮之后灯该消失"。**UI 动作的验收必须包含"结果状态"的断言，而不只是发请求成功。**

**顺带记下**：`markAllSeen()` 只写 `ctx.sessions.list()` 里的会话的 seen 时间戳，sidebar-only 行不受影响；且当有 DSH 页面在同步时 `unread` 完全来自 sidebar 的 `completed` 标志，`seen` 时间戳会被绕过（board.ts:253-259）。所以"全部已读"在**浏览器开着 DSH 页面**时可能仍不清 —— 这是上游语义，不是本移植的 bug；真要彻底清需要在 Host 侧改。

### Phase 2 修复二 — 「全部已读」第二次报障：**修复根本没送进运行中的页面**（2026-09-14）

**用户复报**："全部已读还是没用，继续修"。

**先证伪"还有第二个 bug"**：查运行时状态 → 胶囊是 13:37:25 启的、产物里确实是修复版、`sidebarSyncedAt` 为空（没有页面在同步）。于是最可能的解释不是逻辑，而是**投递**。

**根因（流程性错误，比代码 bug 更值得记）**：WebView2 把 `https://notch.local/index.html` 缓存进 **exe 旁的 profile 目录**（`dsh-notch-win.exe.WebView2`），而且**对常驻胶囊同样生效**。我上一轮只把 `--shot` 的缓存绕开（临时 profile），于是：

| 时刻 | 事件 |
|---|---|
| 13:32:08 | 胶囊启动，加载的是**修复前**的页面（并缓存它） |
| 13:35:50 | 我改好并构建出修复版页面 |
| ~13:36 | 用户点「全部已读」→ 页面是旧的 → 绿灯照旧挂着 |
| 13:37:25 | 我重启胶囊（这次才载入修复版），但用户已不会再点一次 |

**换句话说：修了 bug，没把修复送进正在跑的页面。**

**修法（两道，互不依赖）**

1. **导航 URL 带内容指纹**：`index.html?v=<index.html 的 mtime+长度>`（`AssetToken()`）。内容一变 URL 就变，旧缓存条目永远不可能被命中 —— 不需要任何清理 API（本项目引用的 WebView2 1.0.4191.47 里 `CoreWebView2Environment.ClearBrowsingDataAsync` 不存在，编译期即报 CS1061，所以指纹是唯一干净的路子）。
2. `--shot` 继续用轮转临时 profile（已证实必要）。

**同时补上真正能抓到这个 bug 的自检**（`RunPageSelfTestAsync`，65 项全 PASS）：

- 等页面 bridge 报到（`_pageReady`）——**第一次跑就暴露了"250ms 就去探测"会读到空 DOM**，于是加了显式等待，并把等待本身也做成一项断言
- 用 `ExecuteScriptAsync` 在**真实页面**里读回它自己看到的东西（灯的种类与计数、徽标文本、行尾标签数）
- 投喂"两行未读完成"的合成快照 → 断言灯与徽标出现 → **点真正的 `#clear` 按钮** → 断言页面确实发出了 `{type:'seen'}` → 投喂清空后的快照 → 断言**灯、徽标、行尾标签全部消失**
- 自检期间不执行真实 `markAllSeen`（`_pageProbeEnabled`），避免测试改动用户的 `seen.json`

**第三条修复（Host 侧，用户最初报障的可能成因）**：`board.ts` 的 sidebar mirror 分支从不检查 `dismissed`，于是**只要浏览器里开着 DSH 页面**，`unread` 就完全由页面报的 `completed` 决定，"全部已读"会被下一次同步立刻重新点亮。已改为 `unread = busy || dismissed ? false : ...`，即：

- 已显式标记已读的会话，无论页面怎么说都算已读（与非 mirror 分支一致）
- **运行中的会话永远不算"未读完成"**（上游灯判定本就要求 `!busy`，mirror 分支漏了）

这是 fork 差异 #2/#3，已在 `board.ts` 原地注释说明。新增 `tests/sidebar-seen.test.mjs`（无需 tsx，Node 24 直接剥类型加载 `src/board.ts`）覆盖 5 条：页面报完成→未读、`markAllSeen` 后仍被 mirror 报完成→已读、单会话 `markSeen` 同理、**比 seen 更新的一轮仍算未读**（防止 seen 过度静音）、busy 行不算未读。全 PASS，且测试把 `HOME/USERPROFILE` 重定向到临时目录，绝不动用户的真实 `seen.json`。

### Phase 3 — AskUserQuestion 向导（2026-09-14，**已完成 ✅**）

**范围**（PLAN §9 第 3 步）：在胶囊里回答 AskUserQuestion —— 单选 / 多选 / 自定义输入 / markdown 详情，外加回焦与未读清除的打通。
**不含**：StatusOrbit 四态笔画（Phase 4）、待机机器人（Phase 5）、安装自启（Phase 6）、审批按钮（上游 0.3.0 即死代码）。

#### 3.1 产物

| 文件 | 改动 |
|---|---|
| `NotchModels.cs` | 新增 `NotchAnswerItem`（镜像 `src/types.ts:56-60`） |
| `NotchClient.cs` | `AnswerAsync`（`POST /answer`）、`NotchMessages.Answer`（唯一手写 JSON 之外的**序列化**出口，用户输入可能含引号/换行）、`ProbeAnswerRoute`（自检用） |
| `NotchWindow.cs` | ask 状态机（新题自动展开 / 答完自动折叠 / 长详情切换高度）、`HandlePageAnswer`、`SetKeyboardBorrow`、导航拦截、`InjectSyntheticAsk`（`--shot --ask`）、`LogPageLayoutAsync`、自检 +26 项 |
| `Assets/notch/index.html` | 向导 UI + markdown 渲染器（移植 `NotchMarkdown.swift`）+ 测量重写 |
| `Program.cs` | `--ask` / `--ask-long` 截图开关 |

#### 3.2 契约与上游对齐

- 回答体严格照 `RootView.swift:505-515`：单选被输入框覆盖时 `selected` 清空，多选两者都带，`custom` 为空时**整个字段省略**而不是空串。
- 向导步骤照 `AskWizard`：单选点一下就前进、最后一题未答不出「完成」、多选题累积、`完成` 只在最后一题出现、全部答完才可提交。
- 长详情（>240 字符，与宿主的 `LongDetailThreshold` 同一常量）不再贴合内容，而是占满屏幕（`工作区高 − 2×100pt`）并把详情变成可滚动区域，选项始终留在屏幕上（`RootView.swift:657-673`）。
- markdown 是**移植**不是引库：胶囊离线（没有 CDN / 打包器），上游那个 130 行的块解析器就是参照物，且全部用 `textContent` 建节点 —— 题目详情是不可信文本，不能注入标记。

#### 3.3 三处平台的必然差异（都不是"没还原"）

1. **键盘借用**：胶囊是 `WS_EX_NOACTIVATE`，按键跟着**前台窗口**走，所以输入框拿到 DOM 焦点也收不到字符。页面的 `focusin` 现在会让宿主临时清掉该位 + `SetForegroundWindow` + `SetFocus`，失焦即还原，并且只在当前前台仍是自己时才把键盘还给原来的窗口。自检断言样式位往返（确定性）而不去断言"谁是前台"。
2. **待回答时不折叠**：上游可以先折叠、鼠标一蹭再展开（`main.swift:123`）；本移植是"点击才展开"（用户 Phase 1 选定），折叠会变成死路，而且 `Collapse()` 会收回键盘——正打字时被鼠标漂移打断不可接受。所以 `_awaitingAction || _keyboardBorrowed` 期间不启动也不执行折叠。
3. **动作行 = 第一个带 `ask` 的行**：上游取第一个 `needsAction`，可能落在审批提示上；审批是死代码（`src/dsh-notch.ts:44-46`）且本移植不做审批按钮（PLAN §13），所以只认真正能作答的那种行。同理，上游的 `skipQuestion` 在视图里**没有任何调用点**（不可达），不伪造「跳过」按钮。

#### 3.4 验收

| 项 | 结果 |
|---|---|
| `--selftest` | **91 项全 PASS**（Phase 2 的 65 项一项未退，新增 26 项） |
| 向导渲染 | 真页面里断言题面、`1/2` 计数、两个芯片与描述、markdown 结构（`h1:1 p:2 li:2 table:1 code:1 strong:1`） |
| 单选 / 多选 | 点单选前进且**不提前提交**；多选累积到 `on=日志\|截图` |
| 回答载荷 | 逐字段比对（`q1=["Alpha"]`、`q2=["日志","截图"]`），并另外断言"手打的答案原样送达"与"失败提示可见" |
| 真 Host 路由 | 对运行中的 Host 发一次真实 `POST /answer`（不存在的 ask）→ **404 not pending**（若是 400 就是载荷形状不对，403 就是令牌不对），不回答任何真实问题 |
| 自动展开 / 自动折叠 | 走**真实 `OnSnapshot`** 投喂合成快照：新题 `expanded=True activeAsk=ask-probe-1`，答完 `expanded=False activeAsk=-` |
| 长详情 | `long=True target=1068 max=1068`，详情 `scroll=590/549 overflow=auto`（41px 真实溢出），按钮 `fits=yes` |
| 视觉 | `windows/shots/p3-{ask-right,ask-left,ask-long,list-expanded,rest-right}.png` |

#### 3.5 Phase 3 挖出的五个真坑（前两个是 Phase 2 遗留）

1. **页面按 CSS 像素测量，宿主按物理像素开窗** —— 差 1/scale。宿主这一侧本来是一致的（`EstimateContentHeight` 是 `Scale` 过的、120 的下限注释写明是物理像素），页面却把 CSS 值直接发出去：150% 缩放下展开面板只有内容的 **1/1.5 高**（实测 `win=286` vs 需要 429）。这是 Phase 2 就存在的 bug，65 项全绿是因为**从来没有断言"面板高度等于它的内容"**。修法：页面按 `msg.scale` 换算后再上报，并新增 `listFits` / `fits` 断言。
2. **`font: 600 9px/1 inherit` 是非法声明，整条被丢弃** —— `font` 简写的 family 位置不接受 CSS 全局关键字 `inherit`，于是「全部已读」按钮一直以继承来的 16px 渲染，把徽标行撑到 27px（注释里写的 24 也是错的），测量因此永远差 8px。同样的写法我在向导的标题/输入框/小按钮上也抄了一遍（看起来"字号偏大、字重不对"）。全部改成 longhand。
3. **flex item 默认会收缩 → 用子元素尺寸测量容器 = 自指**。`#list` 是 `flex:1`，行是它的 flex item：行被压到当前列表框的高度，`contentHeight()` 于是量到"当前窗口"而不是"内容需要多少"，面板永远长不到该有的高度，表现为**一行文字旁边挂着一个滚动条拇指**（列表比它唯一的一行还矮 7px）。`#wizard` 有同样的问题（`scrollHeight` 对可收缩元素只会回显自己）。修法：`#wizard` 与 `.row` 都 `flex:0 0 auto`，测量只求和子元素盒子。
4. **长详情布局的 `flex:1` 漏在父级**：`body.long-detail` 设了、`#w-detail` 也是 `flex:1`，但 `#wizard` 仍是 `flex:0 1 auto`——flex item 在主轴方向不会被拉满，于是"滚动区"没有可滚动的高度，多出来的窗口高度就空在按钮下面。只有截图能看出来，`class` 断言一路绿灯（新增的 `scroll=content/viewport` 断言就是为它写的）。
5. **`scrollbar-width` 会让 Chromium 忽略 `::-webkit-scrollbar`**：一旦写了标准属性，浏览器切回**原生**滚动条，于是 `::-webkit-scrollbar-button{display:none}` 之类的规则全部失效，预留的 gutter 里被画出原生轨道和上下箭头。删掉标准属性、只留 webkit 伪元素。

**顺带**：`--shot` 新增 `LogPageLayoutAsync()`，把页面自己的盒子尺寸（viewport / 列表 client-scroll / 面板各块高度 / 行高）写进日志。上面第 1、2、3 条的定位全靠它 —— 截图只说"不好看"，这个说"面板 88px，内容 95px"。

#### 3.6 端到端链路：已于 19:05 用真实提问补齐 ✅

交付时这一段是**未验证**的：只有顶层会话能提问（子代理提问被 DSH 拒绝：`human interaction is unavailable while the calling agent is owned by another live agent`），而顶层会话提问会阻塞执行回合。用户在场后当场问了一个真问题，宿主日志逐行记下了完整链路（用户实际是在**胶囊里**点的选项）：

```
19:04:52.046  ask 74005f17-7498-4d65-b196-b35f589fe697 appeared longDetail=False — expanding
19:04:52.449  geometry settled 720x129
19:04:52.450  content height 129 -> 381 (expanded=True)      ← 页面上报物理像素高度
19:04:52.854  geometry settled 720x381            ← 面板长到内容高度（381px = 254 CSS）
19:05:05.753  page answer ask=74005f17-… items=1              ← 回答来自胶囊页面桥
19:05:05.759  answer accepted ask=74005f17-…                  ← 宿主 POST /answer 被 Host 接受
19:05:05.769  ask resolved — folding                          ← 答完自动折叠
19:05:06.484  geometry settled 57x66
```

要点：`page answer` 而不是 GUI 回答，说明确实是胶囊发出的；`content height 129 -> 381` 正是 3.5 第 1 条单位修复在真机上的表现；13 秒内完成（新题自动展开 → 加宽到内容 → 作答 → 自动折叠）。同一段时间的日志还显示用户在真实使用 Phase 1 的交互（`edge=left top=635`：双击切到左边缘并拖到了 y=635）。

---

### Phase 4 — StatusOrbit 四态笔画（2026-09-14，**已完成 ✅**）

**范围**（PLAN §9 第 4 步）：把收起态从"19 pt 实心盘 + 计数"换成上游的四态笔画 —— 蓝（运行）/ 黄（待决策）/ 绿（成功）/ 红（失败）四色有向笔画、0.95 s 飞行、0.98 s 回复回程、0.62 s 决策旋转、并发多灯计数、Reduce Motion 直显终态；并且**收起态胶囊高度改由页面上报的动画 OrbitLayout 驱动**（上游 `restCapsuleHeight = orbitLayout.height + 24`）。
**不含**：待机机器人（Phase 5；`workReveal`/`StatusBirth` 已留钩子）、安装自启（Phase 6）。

#### 4.1 产物

| 文件 | 改动 |
|---|---|
| `Assets/notch/index.html` | 新增 StatusOrbit 移植（约 900 行）：`OrbitLayout`/`OrbitBrushRoute`/`OrbitMotionFrame`/`OrbitStroke`/`DecisionSpin`/`DecisionReturn(Frame)`/`DecisionMorph`/`DecisionClosing`/`StatusSeparation` + BoardModel 的 orbit 状态机 + Canvas 渲染器 + `rest` 高度上报 + 自检探针；删掉沿用的 `#lamps` DOM 与 `renderLamps` |
| `NotchClient.cs` | `NotchMessages.Geometry` 增加 `motion`（Reduce Motion 由宿主 `SPI_GETCLIENTAREAANIMATION` 决定并下发，不让页面猜） |
| `NotchWindow.cs` | `SetRestOrbit`/`ApplyRestGeometry`/`AbortGeometryAnimation`（飞行期间窗口高度由页面逐帧驱动）、`rest` 消息、`RunOrbitSelfTestAsync` +29 项、`InjectSyntheticOrbitAsync`（截图用） |
| `Program.cs` | `--orbit <state>` / `--orbit-at <0..1>` / `--no-motion` |
| `windows/tests/orbit-math.test.mjs` | 新增：**从 index.html 抽取** `orbit-math` 标记段做 38 项纯数学断言（不需要构建、不需要浏览器、不需要 DSH） |

#### 4.2 与上游对齐的要点

- **一个样本决定一切**：页面 CSS px 就是上游的 pt，宿主负责 pt→物理像素；四个盘位与胶囊高度读同一个 `OrbitLayout`（docs/motion-continuity.md:15），所以窗口边缘与笔画不可能对不上。
- **"成功向上 / 失败向下"是舱位语义**：绿盘落在顶槽、红盘落在底槽；飞行中源槽（蓝灯）会向下滑动让位（实测蓝字 cy 36.9 → 47.3）。不能断言成"墨迹 y 一直减小"——目的地固定、源槽在动。
- **颜色与填充分离**：笔画头部先描出目标圆，圆画完才填充；返回段用"结果色→蓝"的空间渐变，实心盘与 15 pt 黑盘盖住回程（STATUS-MOTION.md:18,28）。
- **DecisionSpin 用连续角速度积分**（0.62 s）：黄↔蓝切换点不反转、不重置相位；回复回程 0.98 s，笔尖角速度落到运行速度。
- 蓝环**只在没有飞行时**才画（飞行期间蓝墨来自笔画尾段）；数字与黑盘按 `sourceOpacity` 淡出，避免结果圈与蓝字重影。

#### 4.3 与上游的差异（都不是"没还原"）

1. **`workReveal` 留钩子**：`ROBOT_DEPARTURE = 0`。Phase 5 接上机器人后改回 1.22 s 并让蓝环以笔速出生（StatusOrbit.swift:463-470 的公式已在位）。
2. **空闲态仍是占位圆点**：上游无状态时画待机机器人（RootView.swift:692-709），机器人属 Phase 5；这里保留 Phase 2 的 5 pt 灰点，代码里标了 `PHASE 5 REMOVES THIS`。
3. **悬浮 1.08 缩放用 CSS transition 近似**上游 spring（RootView.swift:697），且只在 `hasstatus` 时生效。

#### 4.4 验收

| 项 | 结果 |
|---|---|
| `node windows/tests/orbit-math.test.mjs` | **38 项全 PASS**（路由相位顺序与目的地位置、头部单调且尾部不越界、非返回飞行落在结果圆、返回飞行回到蓝弧、布局高度单调 + "红盘位移 = 壳高变化"、回程/旋转端点与速度连续性、morph 单调性、20/28 pt 分离阈值） |
| `--selftest` | **120 项全 PASS**（Phase 3 的 91 项一项未退，新增 29 项） |
| 四态笔画（真页面 canvas 回读） | 单灯 = 蓝弧 214 px（实心盘约 600）且落在唯一槽位；成功 68 px 弧 → 644 → 617 px 实心盘，绿盘 cy 21.7 在蓝字 47.3 之上；失败红盘底缘 58.7 落在第二槽；四态四盘 623/203/619/628 px，cy 21.7/49.7/74.9/105.7（28 pt 间距） |
| 窗口高度跟随飞行 | 走真实 `OnSnapshot`：2 灯 → 1 灯时窗口取到 **18 个不同高度，108 → 66 px 单调**；四态 192 px；单灯 66 px |
| Reduce Motion | 由页面开关驱动：`flight=null animating=false`，绿盘立刻出现在顶槽（623 px @ y=21.7） |
| 视觉 | `windows/shots/p4-{idle,running,decision,mixed,mixed-reduce,flight-success,flight-failure,flight-decision,reply,live}.png`；`p4-live.png` 是**真实数据**（绿 1 + 蓝 1），验证端到端 |

#### 4.5 Phase 4 挖出的坑（其中一个只有截图能抓到）

1. **上一会话留下的半迁移状态**：源码 `index.html` 已把 `#lamps` 换成 `<canvas id="orbit">`，但 JS 仍在 `getElementById('lamps')` 上跑 `renderLamps` → 每次快照都抛异常（页面只剩外壳）。运行中的 bin 还是 Phase 3 的旧资源，所以"看着正常"。
2. **画帧不推进布局**：rAF 回调只 render 不 tick → 笔画自己在动（墨水进度是现算的），但 `model.layout` 冻结 → 上报高度永远是起飞前的值，窗口不动。修法：`pump()` 先 `tickLayout()` 再 `render()`（对应上游 RootView.swift:326 的 60 fps Timer）。
3. **盒子变了不重绘**：Reduce Motion 下没有帧循环，宿主按上报高度改完窗口后画面仍按旧盒子居中 → 整摞灯偏移（实测绿盘 cy 8.1 而非 22）。修法：`ResizeObserver` → `render()`。
4. **探针读到上一帧的盒子**：pin 一帧后立刻读 canvas，宿主还没来得及按上报高度改窗口 → 断言量到错位（红/黄盘被画到画布外，回读 0 px）。修法：**测量本身就是等待** —— pin 之后要等一轮 IPC + 重排再回读。
5. **`animating` 不该包含旋转**：Reduce Motion 下 `updateOrbitLayout` 仍会建 `DecisionSpin`（上游同样如此），若把它算进"布局在动"就会让宿主误以为要接管高度。改成 `flight | reply | layoutActive`，旋转单独留给帧循环。
6. **上报末值会被 0.02 pt 阈值吞掉**：飞行最后一帧落在 20.01，随后"目标与起点相同"的 mix 被当成 0.42 s 动画 → 真值 20.00 永远不上报，宿主停在 20.01。修法：`from` 与 `target` 相同时立即落地并上报。
7. **solo 黄灯的感叹号被淡没了**：上游把字形颜色乘 `(1-fill)`（黄底上是**黑字**，不是透明），我写成 alpha 淡出 → 单独待决策时是一块没有符号的黄圆。自检里"四态四盘"走的是四槽分支，压根没经过 morph 分支，所以一路绿灯；**是截图抓到的**，随后补了 solo 分支断言（字形处 15 个暗像素、盘内远离字形处 0 个）。




---

### Phase 5 — 待机机器人（2026-09-14，**已完成 ✅**）

**范围**（PLAN §9 第 5 步）：无状态时显示上游的待机机器人 —— OpenBotMotion 的 9 个待机动作 + 自然眨眼 + dance 彩蛋（间隔与时长照 §8.4），外加"离场/到场"存在感状态机：灯出现时机器人收缩成笔尖并把颜色交给 status（1.22 s），灯全部离开后从环里绽开回来（1.05 s）。
**不含**：安装/自启（Phase 6）。

#### 5.1 产物

| 文件 | 改动 |
|---|---|
| `Assets/notch/idle/` | 上游 `tools/idle/renderer.js`(97 KB) + `motions.js` + `LICENSE.open-bot-motion` **原样落地**（哈希一致）；9.4 MB 烘焙 JSON 不参与 |
| `Assets/notch/robot-pose.js` | 新增（约 32 KB）：`RobotDirector`（9 动作调度、静止 5–10 s、dance 每 1200–2400 s 一次 3–5 s、自然眨眼 3.7/4.9/3.2/4.6/4.1/3.5 s 周期含 90 ms 闭 190 ms 开、carry/mix 手递）＋ `RobotPose`（把上游引擎写进隐藏 SVG 的实时 `d`/眼睛/圆点拷进胶囊画布，保持 `getImageData` 可断言）＋ `departure`/`statusBirth` |
| `Assets/notch/index.html` | presence 状态机（离场/到场）、Canvas 上的机器人渲染、锚点 = 画布中心；`ROBOT_DEPARTURE` 由 0 改回 1.22 且 `DecisionSpin.delay = 1.22`（笔等机器人）；探针新增 `soloRobot`/`pen`/机器人像素回读 |
| `NotchClient.cs` | `rest` 消息带 `idle`（宿主自己算不出"机器人是否该在屏幕上"） |
| `NotchWindow.cs` | `RunRobotSelfTestAsync` +12 项、`InjectSyntheticRobotAsync`（`--robot` 截图）、`LogRobotFrameAsync` |
| `Program.cs` | `--robot <idle\|blink-<相位>\|hop\|dance\|flight\|arrive>` ＋ `--robot-at`（clip 姿态是绝对时刻，flight/arrive 是相对锚点的偏移） |
| `windows/tests/` | `robot-probe.mjs`/`flight-probe.mjs`/`page-probe.mjs`/`probe-renderer.cjs`/`serve-check.mjs`（headless Edge CDP 探针，不需要构建、不需要 DSH） |

#### 5.2 与上游对齐的要点

- **引擎原样用，位置自己算**：9.4 MB 烘焙 JSON 是上游 `tools/idle` 的**产物**，而 `renderer.js` 是它的**源头**，所以移植只带 JS 引擎（97 KB vs 9.4 MB），由引擎实时算姿势再光栅化进胶囊画布 —— 也正因如此，像素断言仍然成立。
- **锚点是画布中心**（`IdleRobot.swift:402-403` 的 maxWidth/maxHeight 居中），不是灯堆中心：胶囊画布是 30 × 上报高度，`frameH` 只是里面的一段。
- **颜色交接**：离场时机器人自己的颜料按 `RobotDeparture` 混向即将出现的 status 颜色，`colorMix` 在 68%–74% 走完；到场时从上一盏灯的颜色里绽开（`IdleRobot.swift:418`）。
- **笔等机器人**：`DecisionSpin.delay = ROBOT_DEPARTURE = 1.22 s`，蓝环在机器人最后一点到达边缘之前不出发。

#### 5.3 验收

| 项 | 结果 |
|---|---|
| `--selftest` | **132 项全 PASS**（Phase 4 的 120 项一项未退，新增 12 项） |
| `node windows/tests/orbit-math.test.mjs` | **38 项全 PASS**（未退） |
| 引擎存活 | 真页面回读上游引擎写进 SVG 的属性：`d` 305 字符、2 只眼睛带 `translate(...) rotate(...)` |
| 空闲出图 | 空载时机器人是唯一墨迹：body 354 px、eyes 12 px，且窗口高度 = 空布局 20 pt → 66 px |
| 眨眼 | 计划夜的眼皮真的合上：eyes 11 px open → 0 px closed |
| 手势 | hop 的轮廓位移到 minY = −136.3（静止约 −63） |
| dance | 彩蛋换颜料：`#c92299` → `#7d26d0`，body 345 px |
| 离场 | 采样点改用**页面上报的离场锚点**后：361 px @0.246 → 154 @0.418 → 2 @0.5 → 0 @0.615，scale 1/0.646/0.06；锚点落在灯出现的那一帧内（11.540 ∈ 11.538..11.600） |
| 笔被压住 | 离场期间 `travelled = 0`（delay 1.22），窗口过后 `travelled = 2.19` |
| 到场 | visibility 0.16 @0.10 s → 0.99 @0.30 s（绽开，不是硬切） |
| Reduce Motion | 中性姿势静止：body 354 px → 354 px（400 ms 内） |
| 视觉 | `windows/shots/p5-{idle,dance,flight,arrive}.png` —— idle 白机器人、dance 品红机器人、flight 蓝色半收缩 + 蓝环、arrive 灰暗渐显 |

#### 5.4 Phase 5 挖出的坑

1. **`motions.js` 里有 demo 引导代码**：它一加载就 `querySelector('#grid')`、读 `data-motion`，在胶囊页面里直接抛异常 → 引擎 API 全部丢失（`window.NotchRobot` 未定义）。做法：只在页面里注入/执行渲染器那一半，且把入口显式挂在 `window.NotchRobot` 上，页面缺它时**大声失败**（`throw new Error('robot-pose.js did not load')`）。
2. **幽灵节点要取最后一个**：引擎每次渲染都会往隐藏 SVG 里追加/复用节点，取第一个会拿到上一帧的残留，画出来的姿势永远慢一帧。
3. **锚点用画布中心**（见 5.2）：用 `oy + frameH/2` 时机器人被画到 44 px 画布的 y≈332，黑胶囊里什么都没有 —— 这是"窗口在、画面空"的经典表现。
4. **TDZ 静默失效 + `robotVisual` 用 `visibility` 当门控**：`const` 先用后声明抛 `ReferenceError`，画布全黑而探针一路绿灯（探针读的是状态不是像素）；同时离场期间 `visibility` 故意是 0（屏幕归 status 所有），拿它当"要不要画"的门控就会**离场完全不画**。两者都要靠"回读像素"才能发现。
5. **自检的离场采样锚点错了**（本次修复）：自检原先用 `state().flightStart` 当锚点算 `+0.70 s` / `+1.10 s` 两个采样点，但离场可能锚在"看见灯的那一帧"而布局飞行更晚开始（本机实测差 60 ms），于是两个采样点都落到机器人自己 0.9 s 曲线的**死亡之后**（opacity 在 1.22 s 里的 0.546 处归零），量到的是**别人的墨**。
6. **同色交接让像素计数认不出主人**（本次修复）：离场时机器人的颜料被混成 status 的颜色，而蓝灯的点数字形/圆盘也是同一个蓝 —— 同一个 30 pt 列里，"机器人缩小了"和"status 在画"在颜色上无法区分（实测 218 px 的"body"其实全是蓝灯字形）。做法：探针加 `soloRobot` 把 status 通道停掉再回读，机器人自己的墨才可测。断言因此拆成"机器人真的缩小"（隔离像素）与"笔真的被压住"（`pen().travelled`）两条。
7. **GUI 子系统 exe 不阻塞 PowerShell**：`& exe --selftest` 立刻返回、进程随后被回收，读到的 `%TEMP%\dsh-notch-win-selftest.txt` 是**上一次**的报告（本次因此先误判"改完还是 FAIL"）。必须 `Start-Process -Wait -PassThru` 拿退出码，或核对报告的写入时间。

---

### Phase 6 — 安装 / 自启 / 卸载 / 回滚 + 全量验收（2026-09-14，**已完成 ✅（自启待用户确认）**）

**范围**（PLAN §9 第 6 步）：把"能跑"变成"装得上、退得掉" —— 一条安装命令、一条卸载命令、每一步都可回滚，并按 §11 清单做一次全量验收。
**不做**：自动更新、托盘图标、多用户机器级安装（本机是单用户、无 UAC 的场景，全部走 HKCU + 用户目录）。

#### 6.1 装的是什么（三条边，全部可逆）

| 边 | 位置 | 由谁写 | 回滚 |
|---|---|---|---|
| Host 插件 | `%USERPROFILE%\.dsh\profiles\web\dsh-notch` → `D:\DSH\dsh-notch-win`（junction） | `install.ps1`（已存在则跳过，指向别处则拒绝） | `uninstall.ps1` 删链接（**不碰仓库本体**） |
| 加载项 | 同目录 `cordis.patch.yml` 的 `- insert: id: dsh-notch` | `install.ps1` 追加（先备份 `.bak-<时间戳>`；已存在则跳过） | 逐行摘除该 insert 及其紧邻的注释块，并断言文件里再无 `id: dsh-notch` |
| 自启 | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\DshNotchWin` | `install.ps1 -NoAutostart` 可跳过 | 删除该项；装之前若有旧值则**还原旧值**（记录在 `.installed.json`） |

exe 不复制到别处：**仓库的构建产物就是被安装的二进制**（`windows/DshNotchWin/bin/Release/net8.0-windows/win-x64/dsh-notch-win.exe`）。理由很实际 —— Host 插件本来就是从同一棵树经 junction 加载的，两个副本 = 迟早出现"我到底在跑哪个构建"。

`.installed.json` 记录本次安装动过的每一样东西（含装之前的自启值），卸载据此精确还原；手工换过 `-ProfileRoot`/`-AutostartKey` 也一样（脚本参数可覆盖，这正是沙箱验证用的入口）。

#### 6.2 用法

```powershell
# 安装（默认重新构建；-Start 顺手把胶囊拉起来）
pwsh -File windows\install\install.ps1 -Start

# 只登记插件、不要开机自启
pwsh -File windows\install\install.ps1 -NoAutostart

# 不要动正在跑的胶囊（默认只对真实安装动手；沙箱模式自动跳过）
pwsh -File windows\install\install.ps1 -NoBuild -KeepRunning

# 先看看会改什么（一个字节都不写）
pwsh -File windows\install\install.ps1 -WhatIf

# 卸载（保留仓库与构建产物；-KeepPatch 只摘自启）
pwsh -File windows\install\uninstall.ps1
```

重启 DSH web 进程才会加载/卸载 Host 插件（插件在启动时装配）。胶囊自己会等 `~/.dsh/dsh-notch/runtime.json`（2 s 一次）——所以**开机自启早于 DSH 是安全的**：DSH 没起来时它就是边缘上一个待机机器人，Host 写好 origin+token 后自动接上。

#### 6.3 回滚验证（沙箱往返，本机实测）

在临时 profile + 临时注册表键（`HKCU\Software\DshNotchWinSandbox\Run`）上跑完整往返，**不碰真实安装**：

| 步骤 | 结果 |
|---|---|
| `install.ps1 -NoBuild` | 建 junction、追加 insert（带注释块）、写 Run 值、落 `.installed.json` |
| 再跑一次 `install.ps1` | 三条全部 `[skip]`（幂等），状态文件合并而不是覆盖旧记录 |
| `uninstall.ps1` | 删 Run 值、摘除 insert（第 9..16 行 = 注释块 + insert）、删 junction（真实安装的状态文件在沙箱模式下不动） |
| 摘除后的 `cordis.patch.yml` | 与安装前**逐行一致**（8 行，`meow-memory` 与 `some-other-plugin` 两段完好） |
| 真实 profile 的 `-WhatIf` | 只报一条计划：写自启项（junction 与 insert 已存在 → skip） |

沙箱隔离的两条硬规则（试跑时才发现，都是"试跑不该动真东西"）：
1. **沙箱不碰正在跑的胶囊** —— `-ProfileRoot`/`-AutostartKey` 任一被覆盖即视为沙箱模式，此时既不结束胶囊进程、也不写真实安装的 `.installed.json`（状态文件只属于真实安装，卸载要靠它还原"装之前的自启值"）。第一次试跑忘了这条，把用户正在看的胶囊一起杀了。/ 需要显式保留进程还有 `-KeepRunning`。
2. **只删自己指向的 junction** —— 目标不是本仓库时直接 `[fail]` 退出，绝不动别的插件留下的链接。

#### 6.4 全量验收（PLAN §11 逐条对账）

**功能**

| §11 条目 | 结论 | 证据 |
|---|---|---|
| 空载时右上角 32×110 pt 竖条 | 模型已变（用户 Phase 1 选定贴边吸附） | 空载 = 30 pt 宽 × 空布局 44 pt：自检 108 `orbit=20pt window=66px`；`windows/shots/p5-idle.png` |
| 1/2/3 个任务高度 44/72/100 pt | ✅ | 自检 35 `lamp heights 1/2/3/4`、94/95 四灯 128 pt → 192 px |
| 状态实时跟随（SSE），断线重连 | ✅ | 自检 49（真实 Host `http 200 rows=1`）、118-120 分帧/注释/CRLF 解析；实测 `curl /dsh-notch/events` 收到 `data: {...}` 帧；重连看 `NotchClient.RunAsync`（idle 看门狗 + 指数退避 + 每次失败重读 runtime.json） |
| 在胶囊里答题后 DSH 侧立即继续 | ✅ | §3.6 真机日志（19:04 用户本人作答）；自检 58-76 覆盖向导与载荷 |
| 多选 / 自定义输入 / 长 markdown | ✅ | 自检 59-67、69-73（含 `scroll(content/viewport)` 与"按钮不出面板"） |
| 点标题回焦 DSH 对应会话 | ✅ | 自检 28-32（命中测试/前台不变/键盘借用往返）；宿主 `seen`+`focus` 由进程发（Bearer 不进页面） |
| 未读单条 / 全部清除 | ✅ | 自检 53-57；`node tests/sidebar-seen.test.mjs` **5 项 PASS**（上游 fork 差异 #2/#3 的回归） |

**窗口行为**

| §11 条目 | 结论 | 证据 |
|---|---|---|
| 悬停展开 / 离开 0.38 s 折叠 | 模型已变：悬停只高亮，**点击才展开**（用户选定） | 自检 15-18（展开几何）、74（答完折叠）、36（悬停只减 2 pt） |
| 收起时点击穿透到下层 | ✅ | 自检 28/29（`click-through ON/OFF`）、31（`hit-test reaches capsule`） |
| 点击不抢前台焦点 | ✅ | 自检 30（键盘借用往返）、32（`foreground unchanged`） |
| 多显示器 + 非 100% 缩放 | ⚠️ 单屏 150% 实测通过；**多屏本机没有第二块屏，未实测** | 自检 1（PerMonitorV2）、10-27（锚点/夹取/迁移/持久化）、日志 `dpi scale = 1.5` |
| Reduce Motion 直显终态 | ✅ | 自检 99/100（跳过飞行直落终态）、117（机器人静止） |
| 单实例 | ✅ | 实测第二次启动 `exit=2 dsh-notch-win: already running` |

**动效**

| §11 条目 | 结论 | 证据 |
|---|---|---|
| 四态颜色与 §8.1 一致 | ✅ | 自检 92/93/96-98；`windows/shots/p4-{idle,running,decision,mixed,flight-*,reply,live}.png` |
| 笔画 0.95 s / 回程 0.98 s / 几何 0.4 s | ✅ | 自检 81-87（飞行相位与落点）、102/103（高度逐帧跟随）；`node windows/tests/orbit-math.test.mjs` **38 项 PASS** |
| 并发多灯计数 / 快速回复不被旧回调覆盖 | ✅ | 自检 46/47（中途改目标从当前帧续）、101-104、122-125（计数派生） |
| 9 个待机动作 + 眨眼 + dance | ✅ | 自检 106-111；`windows/shots/p5-{idle,dance,flight,arrive}.png` |

**工程**

| §11 条目 | 结论 | 证据 |
|---|---|---|
| DSH 侧零改动 | ❌ **有意 3 处 fork 差异**（`src/board.ts`，+21/−2）：Node 24 不支持参数属性、sidebar mirror 分支的 unread 要先看 dismissed、同一表达式补 `busy` 守卫 | `git diff --stat`；设计说明见 §15「Phase 2 修复」「修复二」；回归 `tests/sidebar-seen.test.mjs` |
| `macos/` 保持上游原样 | ✅ | `git status --porcelain` 只有 `M src/board.ts` + 新增 `PLAN.md`/`tests/`/`windows/`，`macos/` 一行未动 |
| 可一键回滚 | ✅ | `windows/install/{install,uninstall}.ps1` + 6.3 的沙箱往返实测 + 每次改写前的时间戳备份 |

**自动化总账**：`--selftest` **132 项全 PASS**（退出码 0）、`orbit-math.test.mjs` **38 项 PASS**、`sidebar-seen.test.mjs` **5 项 PASS**、真实 Host 路由 `GET /status` 200 / `GET /events` 有帧、单实例退出码 2、安装/卸载往返逐行一致。

#### 6.5 开机自启：已按用户确认打开 ✅

用户 2026-09-14 明确选择"现在就打开"，已执行 `pwsh -File windows\install\install.ps1 -NoBuild -Start`：

```
  [skip] junction already points at the repo (...)
  [skip] cordis.patch.yml already inserts dsh-notch
  [plan] set HKCU:\Software\Microsoft\Windows\CurrentVersion\Run\DshNotchWin = "...\dsh-notch-win.exe"
  [done] state written to windows\install\.installed.json
  [done] capsule started
```

实测结果：`HKCU\...\Run\DshNotchWin = "...\windows\DshNotchWin\bin\Release\net8.0-windows\win-x64\dsh-notch-win.exe"`；状态文件 `autostartWritten=true, previousAutostart=null`（即删掉即可完全复原）；胶囊重启后 3 秒内 `transport stream connected` + `rest height -> 57x68 orbit=20.57pt`，说明它照旧接回了 Host。

回滚路径也用 `-WhatIf` 对真实 profile 预演过，动作恰好是四步：停胶囊 → 删 Run 项 → 摘 insert（真实文件第 35..48 行）→ 删 junction（外加删状态文件）。真要做就是：

```powershell
pwsh -File windows\install\uninstall.ps1
```


#### 6.6 入库的验收截图与复现命令

仓库只收 **5 张代表性截图**（合计约 208 KB，其中 `p3-ask-long.png` 一张就占 168 KB），其余留在工作区：截图由 `--shot` 完全可再生产，而二进制进 git 历史是删不掉的（upstream 的 `.gitignore` 本身就有一条 `*.png`，所以这几张是 `git add -f` 收进来的）。

| 图 | 说明 | 复现命令（工作目录 = 仓库根） |
|---|---|---|
| `windows/shots/p2-rest-right.png` | 收起态（空载、贴右边缘） | `dsh-notch-win.exe --shot windows\shots\p2-rest-right.png` |
| `windows/shots/p3-ask-long.png` | 长 markdown 详情的向导 | `... --shot windows\shots\p3-ask-long.png --ask-long` |
| `windows/shots/p4-live.png` | **真实数据**下的四态笔画（绿 1 + 蓝 1） | 有真实任务在跑时 `... --shot windows\shots\p4-live.png` |
| `windows/shots/p5-idle.png` | 待机机器人（白） | `... --shot windows\shots\p5-idle.png --robot idle` |
| `windows/shots/p5-flight.png` | 离场中段（半收缩 + 蓝环） | `... --shot windows\shots\p5-flight.png --robot flight` |

`exe` = `windows\DshNotchWin\bin\Release\net8.0-windows\win-x64\dsh-notch-win.exe`。`--shot` 是自动化路径：**不写**用户的位置文件，合成状态的那几条还会先 Dispose 掉真实 transport，防止真实快照在曝光中途覆盖画面。