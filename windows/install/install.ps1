<#
.SYNOPSIS
    Installs dsh-notch-win: builds the capsule and wires the DSH Host plugin (plus
    its launcher) into a profile — junction + patch inserts, no registry writes.

.DESCRIPTION
    Everything this script changes is reversible, and every change is recorded in
    `windows/install/.installed.json` so `uninstall.ps1` can undo exactly what was
    done:
      * profile junction   %USERPROFILE%\.dsh\profiles\web\dsh-notch -> <repo>
      * patch insert       `- insert: id: dsh-notch` in cordis.patch.yml
                           (the file is backed up first, timestamped)
      * patch insert       `- insert: id: dsh-notch-win-launcher`
                           (windows/launcher/notch-launcher.ts — starts the capsule
                           whenever DSH boots)

    There is deliberately NO Windows logon autostart any more. The capsule is the
    UI half of a program whose other half is the DSH Host plugin, so its lifetime
    belongs to DSH: `HKCU\...\Run\DshNotchWin` was removed (2026-09-14, user
    request) and replaced by the launcher insert above — which is also why this
    script no longer touches the registry at all.

    The exe is NOT copied anywhere: the repo build output is the installed binary,
    because the Host plugin is loaded from the same tree through the junction.
    Two paths for one program is how a "which build am I running" bug starts.

    -ProfileRoot exists so the whole thing can be exercised against a throwaway
    profile (that is how the check in PLAN.md §6.3 was run). Pointing it anywhere
    else is what makes a run a "sandbox": the running capsule is then left alone
    and the real install state file is not written.

.PARAMETER NoBuild
    Use the existing build output instead of rebuilding.

.PARAMETER Start
    Launch the capsule once the install is done (normally DSH starts it at boot).

.PARAMETER KeepRunning
    Do not stop the capsule process (only relevant when it is already running the
    exe being installed; a capsule from another tree is never touched).

.PARAMETER WhatIf
    Print every change without making any.

.EXAMPLE
    pwsh -File windows/install/install.ps1 -Start
#>
[CmdletBinding()]
param(
    [switch]$NoBuild,
    [switch]$Start,
    [switch]$WhatIf,
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.dsh\profiles\web'),
    [string]$ExePath,
    [switch]$KeepRunning
)

$ErrorActionPreference = 'Stop'

function Say([string]$text) { Write-Host $text }
function Plan([string]$text) { Write-Host "  [plan] $text" -ForegroundColor DarkGray }
function Done([string]$text) { if (-not $WhatIf) { Write-Host "  [done] $text" -ForegroundColor Green } }
function Skip([string]$text) { Write-Host "  [skip] $text" -ForegroundColor DarkGray }
function Fail([string]$text) { Write-Host "  [fail] $text" -ForegroundColor Red; exit 1 }

function Apply([string]$what, [scriptblock]$action) {
    Plan $what
    if ($WhatIf) { return }
    & $action
}

$installDir = $PSScriptRoot
$repoRoot = (Resolve-Path (Join-Path $installDir '..\..')).Path
$statePath = Join-Path $installDir '.installed.json'

if (-not $ExePath) {
    $ExePath = Join-Path $repoRoot 'windows\DshNotchWin\bin\Release\net8.0-windows\win-x64\dsh-notch-win.exe'
}

Say "dsh-notch-win installer"
Say "  repo        = $repoRoot"
Say "  profile     = $ProfileRoot"
if ($WhatIf) { Say "  mode        = DRY RUN (nothing will be changed)" }

# ── 1. build ────────────────────────────────────────────────────────────────
if ($NoBuild) {
    if (-not (Test-Path $ExePath)) { Fail "no build output at $ExePath (drop -NoBuild)" }
    Skip "build (using $ExePath)"
} else {
    $sdk = if (Test-Path 'D:\DSH\.dotnet-sdk\dotnet.exe') { 'D:\DSH\.dotnet-sdk\dotnet.exe' }
           else { (Get-Command dotnet -ErrorAction SilentlyContinue).Source }
    if (-not $sdk) { Fail 'no .NET SDK found (D:\DSH\.dotnet-sdk\dotnet.exe or dotnet on PATH)' }
    $project = Join-Path $repoRoot 'windows\DshNotchWin\DshNotchWin.csproj'
    Apply "build $project (Release)" { & $sdk build $project -c Release -v m | Out-Null }
    if (-not $WhatIf -and -not (Test-Path $ExePath)) { Fail "build produced no $ExePath" }
    Done "built $ExePath"
}

# A running capsule locks the exe it was started from (and would be replaced by
# the build below), so a REAL install stops it first. "Real" means the default
# profile: pointing -ProfileRoot elsewhere is the documented sandbox recipe
# (PLAN §6.3), and a sandbox run must never touch the capsule the user is
# actually running.
$defaultProfile = Join-Path $env:USERPROFILE '.dsh\profiles\web'
$realInstall = ($ProfileRoot -eq $defaultProfile)
$running = @(Get-Process -Name 'dsh-notch-win' -ErrorAction SilentlyContinue)
if ($KeepRunning) {
    Skip 'capsule left running (-KeepRunning)'
} elseif (-not $realInstall) {
    Skip 'sandbox run (profile overridden) — the running capsule is left alone'
} elseif ($running.Count -gt 0) {
    Apply "stop the running capsule (pid $(($running.Id) -join ', '))" { $running | Stop-Process -Force }
    if (-not $WhatIf) { Start-Sleep -Milliseconds 400 }
    Done 'stopped the running capsule'
}

# ── 2. profile junction ─────────────────────────────────────────────────────
$link = Join-Path $ProfileRoot 'dsh-notch'
$junctionCreated = $false
if (Test-Path $link) {
    $target = (Get-Item $link -Force).Target
    if ($target -and ($target | Select-Object -First 1) -eq $repoRoot) {
        Skip "junction already points at the repo ($link)"
    } elseif (-not $target) {
        Fail "$link exists and is not a junction — refusing to touch it"
    } else {
        Fail "$link points at $target, not $repoRoot — refusing to touch it"
    }
} else {
    if (-not (Test-Path $ProfileRoot)) { Fail "profile directory not found: $ProfileRoot" }
    Apply "create junction $link -> $repoRoot" {
        New-Item -ItemType Junction -Path $link -Target $repoRoot | Out-Null
    }
    $junctionCreated = $true
    Done "junction created"
}

# ── 3. patch inserts ────────────────────────────────────────────────────────
# Two entries, both idempotent: the Host plugin and the launcher. They are the
# only two things DSH needs — the capsule's start belongs to DSH's boot.
$patchEntries = @(
    [ordered]@{
        Id   = 'dsh-notch'
        Name = './dsh-notch/src/dsh-notch.ts'
        Note = @(
            '# dsh-notch-win — DSH 原生任务胶囊的 Windows 移植版（由 windows/install/install.ps1 追加）。',
            '# 入口是 .ts，靠 Node 24 的 strip-only 类型剥离加载，而 Node 拒绝剥离 node_modules 内的',
            '# 文件，所以走 patch 层的 insert + profile 目录里的 junction，而不是 dsh.profile.bundles。',
            '# 不要重复插入，否则 duplicate loader entry id 启动失败。'
        )
    },
    [ordered]@{
        Id   = 'dsh-notch-win-launcher'
        Name = './dsh-notch/windows/launcher/notch-launcher.ts'
        Note = @(
            '# dsh-notch-win 的启动项：DSH 启动时把胶囊拉起来（原先的 HKCU 登录自启已按用户要求删除）。',
            '# 它只做「查进程 → 分离启动 → 忘记」；胶囊自己会等 Host 写出的 runtime.json 并自动重连，',
            '# 所以 DSH 退出/重启都不需要收尾，也没有任何注册表写入。',
            '# 不要重复插入，否则 duplicate loader entry id 启动失败。'
        )
    }
)

$patch = Join-Path $ProfileRoot 'cordis.patch.yml'
if (-not (Test-Path $patch)) { Fail "no cordis.patch.yml in $ProfileRoot" }

$patchBackups = @()
foreach ($entry in $patchEntries) {
    $pattern = '(?m)^\s*-?\s*id:\s*' + [regex]::Escape($entry.Id) + '\s*$'
    if ((Get-Content $patch -Raw) -match $pattern) {
        Skip "cordis.patch.yml already inserts $($entry.Id)"
        continue
    }

    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = "$patch.bak-$stamp"
    $patchBackups += $backup
    $lines = @('') + $entry.Note + @(
        '- insert:',
        "    - id: $($entry.Id)",
        "      name: '$($entry.Name)'"
    )
    $block = $lines -join "`r`n"

    Apply "back up cordis.patch.yml -> $(Split-Path $backup -Leaf)" { Copy-Item $patch $backup -Force }
    Apply "append the $($entry.Id) insert to cordis.patch.yml" {
        Add-Content -Path $patch -Value $block -Encoding UTF8
    }
    if (-not $WhatIf) {
        if ((Get-Content $patch -Raw) -notmatch $pattern) { Fail "the $($entry.Id) insert did not land in cordis.patch.yml" }
    }
    Done "patch insert added: $($entry.Id)"
}

# ── 4. state file ───────────────────────────────────────────────────────────
# The state file belongs to the REAL install, so a sandbox run leaves it alone.
if ($WhatIf) {
    # nothing written in a dry run
} elseif (-not $realInstall) {
    Skip 'sandbox run — the real install state file is left alone'
} else {
    # A second install (an upgrade) must not lose what the first one recorded.
    $previousState = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { $null }
    $installedAt = if ($previousState -and $previousState.installedAt) { $previousState.installedAt } else { (Get-Date).ToString('o') }
    $state = [ordered]@{
        installedAt     = $installedAt
        updatedAt       = (Get-Date).ToString('o')
        repoRoot        = $repoRoot
        exePath         = $ExePath
        profileRoot     = $ProfileRoot
        patchEntries    = @($patchEntries | ForEach-Object { $_.Id })
        patchBackups    = @($patchBackups)
        junctionCreated = $junctionCreated
    }
    $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
    Done "state written to $statePath"
}

# ── 5. start ────────────────────────────────────────────────────────────────
if ($Start) {
    Apply "start $ExePath" { Start-Process -FilePath $ExePath | Out-Null }
    Done 'capsule started'
}

Say ''
Say 'Done. The Host plugin and the launcher are loaded at DSH boot: restart the DSH'
Say 'web process to pick them up (the capsule waits for ~/.dsh/dsh-notch/runtime.json'
Say 'and attaches by itself once the Host has written it). From then on every DSH'
Say 'start opens the capsule — nothing is registered to run at Windows logon.'
Say "Roll back with: pwsh -File `"$installDir\uninstall.ps1`""
