<#
.SYNOPSIS
    Installs dsh-notch-win: builds the capsule, wires the DSH Host plugin into a
    profile (junction + patch insert) and optionally registers it to start with
    Windows.

.DESCRIPTION
    Everything this script changes is reversible, and every change is recorded in
    `windows/install/.installed.json` so `uninstall.ps1` can undo exactly what was
    done:
      * profile junction   %USERPROFILE%\.dsh\profiles\web\dsh-notch -> <repo>
      * patch insert       `- insert: id: dsh-notch` in cordis.patch.yml
                           (the file is backed up first, timestamped)
      * autostart          HKCU\...\Run\DshNotchWin = "<exe>" (skippable)

    The exe is NOT copied anywhere: the repo build output is the installed binary,
    because the Host plugin is loaded from the same tree through the junction.
    Two paths for one program is how a "which build am I running" bug starts.

    -ProfileRoot and -AutostartKey exist so the whole thing can be exercised
    against a throwaway profile and a throwaway registry key (that is how the
    check in PLAN.md §16 was run).

.PARAMETER NoBuild
    Use the existing build output instead of rebuilding.

.PARAMETER NoAutostart
    Do not register the autostart entry.

.PARAMETER Start
    Launch the capsule once the install is done.

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
    [switch]$NoAutostart,
    [switch]$Start,
    [switch]$WhatIf,
    [string]$ProfileRoot = (Join-Path $env:USERPROFILE '.dsh\profiles\web'),
    [string]$AutostartKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
    [string]$AutostartName = 'DshNotchWin',
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
# profile + the default autostart key: pointing either parameter elsewhere is the
# documented sandbox recipe (PLAN §6.3), and a sandbox run must never touch the
# capsule the user is actually running.
$defaultProfile = Join-Path $env:USERPROFILE '.dsh\profiles\web'
$realInstall = ($ProfileRoot -eq $defaultProfile) -and ($AutostartKey -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')
$running = @(Get-Process -Name 'dsh-notch-win' -ErrorAction SilentlyContinue)
if ($KeepRunning) {
    Skip 'capsule left running (-KeepRunning)'
} elseif (-not $realInstall) {
    Skip "sandbox run (profile/autostart overridden) — the running capsule is left alone"
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

# ── 3. patch insert ─────────────────────────────────────────────────────────
$patch = Join-Path $ProfileRoot 'cordis.patch.yml'
$patchBackup = $null
if (-not (Test-Path $patch)) { Fail "no cordis.patch.yml in $ProfileRoot" }

$patchText = Get-Content $patch -Raw
if ($patchText -match '(?m)^\s*-?\s*id:\s*dsh-notch\s*$') {
    Skip 'cordis.patch.yml already inserts dsh-notch'
} else {
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $patchBackup = "$patch.bak-$stamp"
    $block = @(
        '',
        '# dsh-notch-win — DSH 原生任务胶囊的 Windows 移植版（由 windows/install/install.ps1 追加）。',
        '# 入口是 .ts，靠 Node 24 的 strip-only 类型剥离加载，而 Node 拒绝剥离 node_modules 内的',
        '# 文件，所以走 patch 层的 insert + profile 目录里的 junction，而不是 dsh.profile.bundles。',
        '# 不要重复插入，否则 duplicate loader entry id 启动失败。',
        '- insert:',
        '    - id: dsh-notch',
        "      name: './dsh-notch/src/dsh-notch.ts'"
    ) -join "`r`n"
    Apply "back up cordis.patch.yml -> $(Split-Path $patchBackup -Leaf)" { Copy-Item $patch $patchBackup -Force }
    Apply 'append the dsh-notch insert to cordis.patch.yml' {
        Add-Content -Path $patch -Value $block -Encoding UTF8
    }
    Done 'patch insert added'}

# ── 4. autostart ────────────────────────────────────────────────────────────
$previousAutostart = $null
$autostartWritten = $false
if ($NoAutostart) {
    Skip 'autostart (disabled with -NoAutostart)'
} else {
    if (-not (Test-Path $AutostartKey)) {
        Apply "create $AutostartKey" { New-Item -Path $AutostartKey -Force | Out-Null }
    }
    $current = (Get-ItemProperty -Path $AutostartKey -Name $AutostartName -ErrorAction SilentlyContinue).$AutostartName
    $command = '"' + $ExePath + '"'
    if ($current -eq $command) {
        Skip "autostart already registered ($AutostartName)"
    } else {
        if ($null -ne $current) { $previousAutostart = $current }
        Apply "set $AutostartKey\$AutostartName = $command" {
            New-ItemProperty -Path $AutostartKey -Name $AutostartName -Value $command -PropertyType String -Force | Out-Null
        }
        $autostartWritten = $true
    }
}

# ── 5. state file ───────────────────────────────────────────────────────────
# The state file belongs to the REAL install (it is what uninstall.ps1 reads to
# restore the pre-install autostart value), so a sandbox run leaves it alone.
if ($WhatIf) {
    # nothing written in a dry run
} elseif (-not $realInstall) {
    Skip 'sandbox run — the real install state file is left alone'
} else {
    # A second install (an upgrade) must not lose what the first one recorded:
    # the pre-install autostart value is only knowable before the first write.
    $previousState = if (Test-Path $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json } else { $null }
    if ($null -eq $previousAutostart -and $previousState -and $previousState.previousAutostart) {
        $previousAutostart = $previousState.previousAutostart
    }
    $installedAt = if ($previousState -and $previousState.installedAt) { $previousState.installedAt } else { (Get-Date).ToString('o') }
    $state = [ordered]@{
        installedAt       = $installedAt
        updatedAt         = (Get-Date).ToString('o')
        repoRoot          = $repoRoot
        exePath           = $ExePath
        profileRoot       = $ProfileRoot
        autostartKey      = $AutostartKey
        autostartName     = $AutostartName
        autostartWritten  = $autostartWritten
        previousAutostart = $previousAutostart
        junctionCreated   = $junctionCreated
        patchBackup       = $patchBackup
    }
    $state | ConvertTo-Json | Set-Content -Path $statePath -Encoding UTF8
    Done "state written to $statePath"
}

# ── 6. start ────────────────────────────────────────────────────────────────
if ($Start) {
    Apply "start $ExePath" { Start-Process -FilePath $ExePath | Out-Null }
    Done 'capsule started'
}

Say ''
Say 'Done. The Host plugin is loaded at DSH boot: restart the DSH web process to'
Say 'pick it up (the capsule waits for ~/.dsh/dsh-notch/runtime.json and attaches'
Say 'by itself once the Host has written it).'
Say "Roll back with: pwsh -File `"$installDir\uninstall.ps1`""





