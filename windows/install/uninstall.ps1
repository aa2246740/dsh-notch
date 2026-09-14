<#
.SYNOPSIS
    Undoes windows/install/install.ps1: drops the autostart entry, removes the
    dsh-notch insert from cordis.patch.yml, and removes the profile junction.

.DESCRIPTION
    The repository, the build output and the user's own files are never touched —
    uninstalling means "DSH no longer loads the plugin and Windows no longer
    starts the capsule", not "delete the project". Re-running install.ps1 puts it
    all back.

    What was changed is read back from `windows/install/.installed.json` (written
    by install.ps1), so a value that existed before the install is restored rather
    than deleted. Without that file the script still works: it removes the insert
    block, removes the junction if it points at this repo, and removes the
    autostart value only when it points at this repo's exe.

.PARAMETER KeepPatch
    Leave cordis.patch.yml alone (e.g. to keep the Host plugin loaded while
    removing the autostart entry).

.PARAMETER KeepRunning
    Do not stop the capsule process.

.PARAMETER WhatIf
    Print every change without making any.

.EXAMPLE
    pwsh -File windows/install/uninstall.ps1
#>
[CmdletBinding()]
param(
    [switch]$KeepPatch,
    [switch]$KeepRunning,
    [switch]$WhatIf,
    [string]$ProfileRoot,
    [string]$AutostartKey,
    [string]$AutostartName,
    [string]$ExePath
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

$state = $null
if (Test-Path $statePath) {
    $state = Get-Content $statePath -Raw | ConvertFrom-Json
    if (-not $ProfileRoot) { $ProfileRoot = $state.profileRoot }
    if (-not $AutostartKey) { $AutostartKey = $state.autostartKey }
    if (-not $AutostartName) { $AutostartName = $state.autostartName }
    if (-not $ExePath) { $ExePath = $state.exePath }
}
if (-not $ProfileRoot) { $ProfileRoot = Join-Path $env:USERPROFILE '.dsh\profiles\web' }
if (-not $AutostartKey) { $AutostartKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' }
if (-not $AutostartName) { $AutostartName = 'DshNotchWin' }
if (-not $ExePath) {
    $ExePath = Join-Path $repoRoot 'windows\DshNotchWin\bin\Release\net8.0-windows\win-x64\dsh-notch-win.exe'
}

Say 'dsh-notch-win uninstaller'
Say "  repo        = $repoRoot"
Say "  profile     = $ProfileRoot"
if ($WhatIf) { Say '  mode        = DRY RUN (nothing will be changed)' }

# ── 1. stop the capsule ─────────────────────────────────────────────────────
# Only a REAL uninstall (default profile + default autostart key) stops the
# capsule: pointing either parameter elsewhere is the documented sandbox recipe,
# and a sandbox run must never touch the capsule the user is actually running.
$defaultProfile = Join-Path $env:USERPROFILE '.dsh\profiles\web'
$realUninstall = ($ProfileRoot -eq $defaultProfile) -and ($AutostartKey -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run')
if ($KeepRunning) {
    Skip 'capsule left running (-KeepRunning)'
} elseif (-not $realUninstall) {
    Skip 'sandbox run (profile/autostart overridden) — the running capsule is left alone'
} else {
    $running = @(Get-Process -Name 'dsh-notch-win' -ErrorAction SilentlyContinue)
    if ($running.Count -gt 0) {
        Apply "stop the capsule (pid $(($running.Id) -join ', '))" { $running | Stop-Process -Force }
        if (-not $WhatIf) { Start-Sleep -Milliseconds 400 }
        Done 'capsule stopped'
    } else {
        Skip 'capsule was not running'
    }
}

# ── 2. autostart ────────────────────────────────────────────────────────────
$current = $null
if (Test-Path $AutostartKey) {
    $current = (Get-ItemProperty -Path $AutostartKey -Name $AutostartName -ErrorAction SilentlyContinue).$AutostartName
}
$ours = $current -and ($current -replace '"', '') -eq $ExePath
if ($null -eq $current) {
    Skip "no autostart entry ($AutostartName)"
} elseif (-not $ours -and ($null -eq $state -or $state.autostartWritten -ne $true)) {
    Fail "$AutostartName is not ours ($current) — refusing to remove it"
} else {
    if ($state -and $state.previousAutostart) {
        Apply "restore the previous autostart value ($($state.previousAutostart))" {
            New-ItemProperty -Path $AutostartKey -Name $AutostartName -Value $state.previousAutostart -PropertyType String -Force | Out-Null
        }
        Done 'previous autostart value restored'
    } else {
        Apply "remove $AutostartKey\$AutostartName" {
            Remove-ItemProperty -Path $AutostartKey -Name $AutostartName -Force
        }
        Done 'autostart entry removed'
    }
}

# ── 3. patch insert ─────────────────────────────────────────────────────────
if ($KeepPatch) {
    Skip 'cordis.patch.yml left alone (-KeepPatch)'
} else {
    $patch = Join-Path $ProfileRoot 'cordis.patch.yml'
    if (-not (Test-Path $patch)) {
        Skip "no cordis.patch.yml in $ProfileRoot"
    } else {
        $lines = [System.Collections.Generic.List[string]](Get-Content $patch)
        # Find the `- insert:` entry whose child carries `id: dsh-notch`; its
        # documentation is the contiguous comment/blank run directly above it.
        $insertAt = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*-\s*insert:\s*$') {
                for ($j = $i + 1; $j -lt $lines.Count -and $lines[$j] -match '^\s+\S'; $j++) {
                    if ($lines[$j] -match '^\s*-?\s*id:\s*dsh-notch\s*$') { $insertAt = $i; break }
                }
                if ($insertAt -ge 0) { break }
            }
        }
        if ($insertAt -lt 0) {
            Skip 'cordis.patch.yml has no dsh-notch insert'
        } else {
            $end = $insertAt + 1
            while ($end -lt $lines.Count -and $lines[$end] -match '^\s+\S') { $end++ }
            # The run is dropped only when it actually documents dsh-notch, so a
            # neighbouring entry's comments (the meow-memory block above ours)
            # survive an uninstall.
            $runStart = $insertAt
            while ($runStart -gt 0 -and ($lines[$runStart - 1] -match '^\s*$' -or $lines[$runStart - 1] -match '^\s*#')) {
                $runStart--
            }
            $run = if ($runStart -lt $insertAt) { $lines[$runStart..($insertAt - 1)] } else { @() }
            $documented = @($run | Where-Object { $_ -match 'dsh-notch' }).Count -gt 0
            $start = if ($documented) { $runStart } else { $insertAt }
            $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
            $backup = "$patch.bak-$stamp"
            Apply "back up cordis.patch.yml -> $(Split-Path $backup -Leaf)" { Copy-Item $patch $backup -Force }
            Apply "remove the dsh-notch insert (lines $($start + 1)..$end)" {
                $kept = @()
                if ($start -gt 0) { $kept += $lines[0..($start - 1)] }
                if ($end -lt $lines.Count) { $kept += $lines[$end..($lines.Count - 1)] }
                Set-Content -Path $patch -Value $kept -Encoding UTF8
            }
            if (-not $WhatIf) {
                if ((Get-Content $patch -Raw) -match '(?m)^\s*-?\s*id:\s*dsh-notch\s*$') {
                    Fail 'the insert is still in cordis.patch.yml — restore from the backup above'
                }
            }
            Done 'patch insert removed'
        }
    }
}

# ── 4. junction ─────────────────────────────────────────────────────────────
$link = Join-Path $ProfileRoot 'dsh-notch'
if (-not (Test-Path $link)) {
    Skip 'no profile junction'
} else {
    $target = (Get-Item $link -Force).Target
    $target = if ($target) { $target | Select-Object -First 1 } else { $null }
    if ($target -ne $repoRoot) {
        Fail "$link points at $target, not $repoRoot — refusing to remove it"
    }
    Apply "remove the junction $link" { Remove-Item $link -Force }
    Done 'junction removed (the repo itself is untouched)'
}

# ── 5. state file ───────────────────────────────────────────────────────────
if (-not $realUninstall) {
    Skip 'sandbox run — the real install state file is left alone'
} elseif (Test-Path $statePath) {
    Apply "remove $statePath" { Remove-Item $statePath -Force }
    Done 'state file removed'
}

Say ''
Say 'Done. Restart the DSH web process to unload the Host plugin.'
Say "Nothing else was deleted — re-install with: pwsh -File `"$installDir\install.ps1`""




