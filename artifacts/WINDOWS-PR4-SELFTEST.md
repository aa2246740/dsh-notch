# Home-Windows proof: dsh-notch PR #4 `--selftest`

**Result: FAIL** (exit code **1**, consistent on two runs)

Machine: Cola's Windows private worker Home-Windows  
Checkout: `https://github.com/aa2246740/dsh-notch` @ `devin/1789865286-windows-host-plugin-fixes` (`57c2fd6`)  
Did not merge. Did not publish npm. Did not install Grok Bot.

## 1. OS and toolchains

```
Microsoft Windows [Version 10.0.26200.9457]
OS Name:                       Microsoft Windows 11 专业版
OS Version:                    10.0.26200 N/A Build 26200
System Type:                   x64-based PC
Total Physical Memory:         31,913 MB
```

Console session was Active. Work area measured by the capsule: 2560×1392, **dpi scale = 1** (100%).

| Tool | This machine |
| --- | --- |
| Node | Portable **v24.5.0** (`workspace\.tools\node-v24.5.0-win-x64`). System `npm` was **missing**. Cursor-agent also ships Node 24.5.0 without npm. |
| npm | Portable **11.5.1** (same zip) |
| .NET SDK | **Missing on PATH**. Installed locally with official `dotnet-install.ps1 -Channel 8.0 -NoPath` → **8.0.425** at `workspace\.tools\dotnet-sdk` |
| .NET runtime (system) | `Microsoft.WindowsDesktop.App 8.0.17` present |
| cargo / rustc | **Missing** (not required for this port) |
| WebView2 | **153.0.4234.48** (`C:\Program Files (x86)\Microsoft\EdgeWebView\Application`) |
| gh | Missing |

README still documents macOS + `npm ci` / `npm test` only. Windows `--selftest` is documented in PR #4 / `PLAN.md` / `windows/install/install.ps1`.

## 2. Commands and exit codes

Working tree: `C:\Cursor-Home-Windows\workspace\dsh-notch-pr4`

```
npm ci
# exit 0

dotnet build windows\DshNotchWin\DshNotchWin.csproj -c Release
# exit 0  (SDK 8.0.425)

# PLAN.md: WinExe does not block `& exe`; use Start-Process -Wait -PassThru
Start-Process -FilePath windows\DshNotchWin\bin\Release\net8.0-windows\win-x64\dsh-notch-win.exe `
  -ArgumentList '--selftest' -Wait -PassThru
# run 1 exit 1
# run 2 exit 1

npm test
# exit 0  (16/16 pass)

node windows\tests\orbit-math.test.mjs
# exit 0

node windows\tests\serve-check.mjs
# exit 0

node tests\sidebar-seen.test.mjs
# exit 0
```

## 3. PR #4 `--selftest` — FAIL

| Run | Exit | PASS | FAIL | RESULT line |
| --- | --- | --- | --- | --- |
| 1 | 1 | 156 | 1 | `RESULT: FAIL (1 check(s))` |
| 2 (rerun) | 1 | 156 | 1 | `RESULT: FAIL (1 check(s))` |

The only failing check, both times:

```
[FAIL] long detail is a bounded scroll area scroll(content/viewport)=0 fits=True
```

The previous check **passed**: `long detail switches the layout` with `long=yes overflow=auto fits=yes scroll=1027/1027`.  
`ParseScrollProbe` returns `content - viewport`. On this 100% DPI / 2560×1392 work area the synthetic long detail **exactly fills** the viewport (`1027/1027`), so overflow is 0 and the assertion requires `> 0`.

This is not one of the two pixel-flake items called out in community PR #2. It reproduced on two consecutive runs.

WebView2 init: **PASS** (`runtime=153.0.4234.48`). Host live snapshot/answer routes: **PASS (skipped, no Host reachable)**.

stderr (teardown only): `Failed to unregister class Chrome_WidgetWin_0. Error = 1412`

## 4. Community PR #2 spot-check (because #4 failed)

Checkout: `https://github.com/ygl152/dsh-notch` @ `win11-port` (`767463e`)

```
dotnet build windows\DshNotchWin\DshNotchWin.csproj -c Release   # exit 0
Start-Process ...\dsh-notch-win.exe -ArgumentList '--selftest' -Wait -PassThru
# exit 1
```

**PR #2: FAIL**, exit **1**, **151 PASS / 6 FAIL**

Fails:

1. `the arc carries partial coverage` `alpha=-1/255` (the right-edge sample #4 claimed to fix)
2. `long detail is a bounded scroll area` (same 100% DPI overflow=0 as #4)
3. `the outcome is drawn, not faded in` (green ink vs ~600 disk assumption)
4. `the failure ink lands in the second slot`
5. `the failure outcome is drawn, not faded in`
6. `the solo decision lamp is a solid amber disk` `amber=320` vs `expect ~600`

So #4 is **strictly better** than #2 on this box (1 fail vs 6). The remaining #4 fail is the long-detail scroll overflow check at 100% DPI.

## 5. Artifact paths

All under `C:\Cursor-Home-Windows\workspace\dsh-notch\artifacts\` (also on branch `cursor/windows-pr4-selftest-acea`):

- `WINDOWS-PR4-SELFTEST.md` — this report
- `windows-ver.txt` / `windows-systeminfo-snippet.txt` / `toolchains.txt`
- `pr4-selftest-report.txt` / `pr4-selftest-stdout.txt` / `pr4-selftest-stderr.txt` / `pr4-selftest-exit.txt`
- `pr4-selftest-rerun-report.txt` / `pr4-selftest-rerun-exit.txt`
- `pr4-npm-test-stdout.txt` / `pr4-orbit-math-stdout.txt` / `pr4-serve-check-stdout.txt` / `pr4-sidebar-seen-stdout.txt`
- `pr2-selftest-report.txt` / `pr2-selftest-exit.txt`

No `--shot` screenshots were taken. No image artifacts.

Temp originals: `%TEMP%\dsh-notch-win-selftest.txt`

## 6. Hard gate (committed before tests)

On `cursor/windows-pr4-selftest-acea` (PR #5):

- `.cursor/hooks.json` + executable `.cursor/hooks/block-other-models.sh` (`subagentStart`, `failClosed`)
- `.cursor/agents/worker.md` with `model: inherit` and `force-default-model: true`
- `.cursor/CLOUD.md` — stay on parent Grok 4.6; no Claude/GPT/Gemini; children omit `model`
