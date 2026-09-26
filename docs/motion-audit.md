# Native motion audit

This pass covers all 13 independent review cases using the production RootView, BoardModel, geometry, robot resources and status renderer. It does not use DSH models, network calls or real session actions. User acceptance and production installation remain separate from this self-review.

## Defects reproduced and fixed

- Returning success/failure strokes used a different phase from the running ring. A failing regression reproduced the endpoint mismatch; flights now share the running phase and matched endpoint speed.
- Blue-to-yellow incorrectly reversed the resume curve and erased its arc. It now closes the gap, changes color, fills the circle, then resolves the exclamation point, on its own 0.82-second timeline.
- Text switched between font line boxes and outlines across states. All status glyphs now use the same centered 19-point canvas. This also removes the odd/even child-frame mismatch. The exclamation point retains its separate optical correction.
- Cold snapshots incorrectly used the robot-birth acceleration despite displaying an existing task. They now start at normal speed.
- Removing the bottom result shrank the shell while leaving that disk outside the bottom edge. Its center now follows the shell bottom during the fade.
- The review heading counted playback runs rather than showing the selected case. It now displays the actual case number out of 13.

## Coverage

| Case | Examined behavior |
| --- | --- |
| 01 | Robot backflip, point handoff, concurrent number and blue stroke, rotation handoff |
| 02 | Success flight, source number alignment, returning blue arc phase |
| 03 | Failure flight and return to remaining running task |
| 04 | Last running task succeeds; result counts and shell shrink together |
| 05 | Last running task fails; result counts and shell shrink together |
| 06 | Clear red, then last green; cube arrival |
| 07 | Clear green, then last red; cube arrival |
| 08 | Robot to point, yellow ring, fill and exclamation |
| 09 | Forward closing arc, complete ring, yellow fill, symbol change |
| 10 | Yellow clears, top-origin blue drawing, deceleration to running speed |
| 11 | Decision cancellation to idle robot |
| 12 | Four status types; progressive clearing without bottom clipping |
| 13 | Approval to running; same resume motion as case 10 |

Each case was captured for 180 frames (2,340 full-component images per complete pass). Every case changed across its capture. Contact strips and transition boundaries were inspected. Cases 06, 07 and 12 were captured again after the bottom-edge fix.

Actual-size, 2x and 3x raster checks covered all four colors. The visible glyph bounding-box center matched the circle horizontally in all 12 samples. In case 02, measured horizontal glyph center remained 199.5 raster pixels across frames 20–44 while the shell grew and the count changed. These are measurements for the tested rendering setup, not a claim that fractional coordinates or antialiasing never occur on other displays.

IdleProbe covers glyph geometry, phase continuity, cold-start speed, closed-ring-before-fill, velocity handoffs, bottom containment, idle contour interpolation, blink timing, reversal and shared shell movement. MotionProbe covers route geometry, outcome queues, stale completion IDs and reduced motion.

## Reproduction

Run `sh tools/review/audit.sh /tmp/notch-review-frames` on macOS with the Swift toolchain. It builds an isolated local harness and captures all cases through NSHostingView. `NOTCH_AUDIT_CASES=6,7,12` selects a subset. The script does not install the helper or modify DSH sessions.

The interactive review remains `sh tools/review/build.sh`. Production installation is not part of these scripts.

## Follow-up: dissolve symbols and avoid clearing overlap

Cases 09 and 10 (including approval case 13) now cross-dissolve the centered numeral and exclamation outlines instead of folding their halves. Ring timing is unchanged.

Removed red, green and yellow disks now fade according to their distance from surviving neighbors. Opacity reaches zero by a 20-point center separation, before the 19-point disks and blue stroke can overlap. A sole result returning to the idle robot retains its existing handoff because there is no surviving neighbor. Cases 06, 07, 09, 10, 11, 12 and 13 are the targeted replay set for this change.

The targeted set completed 1,260 full-component captures. Transition strips were inspected, including the lower red disk becoming invisible before reaching the blue ring. Native IdleProbe passed the separation invariant and existing motion checks. The independent preview executable was rebuilt and byte-verified; production installation is still pending user acceptance.

## Idle tour and relaxed holds

Review case 14 plays the chameleon first, returns to light neutral, then visits all nine basic actions with four seconds of neutral blinking between actions. The regular scheduler now waits a random 3–5 seconds between basic actions; independent blink intervals also stay within 3–5 seconds. The sleep clip holds fully closed eyes for four seconds (1.7–5.7 seconds in its nine-second timeline). Rare chameleon scheduling remains 20–40 minutes in normal use.

The tour disables only automatic action selection, retaining the real director timer, blink overlay and pose blending. The existing 100 from/to action-pair tests (nine basics plus dance) passed, along with closed-eye duration assertions. Native chameleon entry/exit frames were inspected. Preview executable and updated sleep resource were byte-verified; production installation remains separate.

### 正式安装：随机待机节奏（2026-09-10）

- 基础动作之间随机待机 5–10 秒；变色龙每次随机表演 3–5 秒，维持原采样速度，在最后 450 ms 平滑回到浅色中性姿态。低频彩蛋触发间隔仍为 20–40 分钟。其他动作保持已验收版本。
- 原生 IdleProbe 全部通过（FAILURES=0），包含 100 种动作组合以及 100 次随机时长/中性收尾断言；正式 Release 构建成功，安装资源验证 10/10。
- 已替换本机 DSH.app 内的独立 helper 与资源；二进制 SHA-256 为 `dc5612a0c36133857f27892b8532151dadb5c71a1599cb407c3b472c004c2ba5`。旧二进制和资源已备份。演示进程关闭。
- 新 helper PID 35639，确认到原 Host 43127 的 TCP 连接；只读状态请求 HTTP 200 / ok=true。DSH App PID 57838、Host PID 57873 均未变化，原生截图确认 DSH 页面正常显示。本轮未调用模型。
- 原生 CUA 能检查 DSH.app，但无法选择无 app bundle 的独立 helper；因此本轮安装后机器人屏幕表现未通过 CUA 重新截图验收，动画证据为此前用户认可的演示与本轮原生渲染回归。
- 本机安装与回滚证据：本地验收目录中的 `installation.json`、`previous-production/`、`host-status.json`（不随仓库分发）。
