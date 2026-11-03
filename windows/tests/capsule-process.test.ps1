# Exercises the install/uninstall process filter without stopping a real process.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\install\capsule-processes.ps1')

function Fail([string]$text) { throw $text }

$root = Join-Path ([System.IO.Path]::GetTempPath()) ('notch-capsule-' + [guid]::NewGuid().ToString('n'))
$installDir = Join-Path $root 'win-x64'
$otherDir = Join-Path $root 'other-checkout'
New-Item -ItemType Directory -Path $installDir, $otherDir | Out-Null
$exe = Join-Path $installDir 'dsh-notch-win.exe'
$other = Join-Path $otherDir 'dsh-notch-win.exe'
New-Item -ItemType File -Path $exe, $other | Out-Null

try {
    if (-not (Test-CapsulePathUnderInstall -ImagePath $exe -InstallDirectory $installDir)) {
        Fail 'target exe was not recognized as owned'
    }
    if (Test-CapsulePathUnderInstall -ImagePath $other -InstallDirectory $installDir) {
        Fail 'a sibling checkout was treated as owned'
    }
    $dotted = Join-Path $installDir 'nested/../dsh-notch-win.exe'
    if (-not (Test-CapsulePathUnderInstall -ImagePath $dotted -InstallDirectory $installDir)) {
        Fail 'a .. segment was not normalized into the install directory'
    }
    $cased = $exe.ToUpperInvariant()
    if (-not (Test-CapsulePathUnderInstall -ImagePath $cased -InstallDirectory $installDir)) {
        Fail 'path comparison was case-sensitive'
    }
    $extended = '\\?\' + $exe
    if (-not (Test-CapsulePathUnderInstall -ImagePath $extended -InstallDirectory $installDir)) {
        Fail 'an extended-length path was not accepted'
    }
    if (Test-CapsulePathUnderInstall -ImagePath '' -InstallDirectory $installDir) {
        Fail 'an empty image path was accepted'
    }
    $sibling = Join-Path ($installDir + '-extra') 'dsh-notch-win.exe'
    if (Test-CapsulePathUnderInstall -ImagePath $sibling -InstallDirectory $installDir) {
        Fail 'a directory-prefix lookalike was accepted'
    }

    $direct = Resolve-CapsuleImagePath -DirectPath $exe -FallbackPath $other -OwnerUser 'someone-else' -CurrentUser 'me' -EnvUser 'me'
    if ($direct -ne $exe) { Fail 'a readable image path did not win over the fallback' }

    $foreign = Resolve-CapsuleImagePath -DirectPath '' -FallbackPath $exe -OwnerUser 'someone-else' -CurrentUser 'me' -EnvUser 'me'
    if ($null -ne $foreign -and $foreign -ne '') { Fail 'another user was used as the path-inspection fallback' }

    $mine = Resolve-CapsuleImagePath -DirectPath '   ' -FallbackPath $exe -OwnerUser 'Me' -CurrentUser 'me' -EnvUser ''
    if ($mine -ne $exe) { Fail 'the current user did not get the fallback path' }

    $envUser = Resolve-CapsuleImagePath -DirectPath $null -FallbackPath $other -OwnerUser 'me' -CurrentUser '' -EnvUser 'ME'
    if ($envUser -ne $other) { Fail 'USERNAME was not accepted as the current user' }

    $missing = Resolve-CapsuleImagePath -DirectPath '' -FallbackPath '' -OwnerUser 'me' -CurrentUser 'me' -EnvUser 'me'
    if ($null -ne $missing -and $missing -ne '') { Fail 'a missing fallback path was treated as verified' }

    $procs = @(
        [pscustomobject]@{ Id = 11 }
        [pscustomobject]@{ Id = 22 }
        [pscustomobject]@{ Id = 33 }
    )
    $reader = {
        param($proc)
        switch ($proc.Id) {
            11 { return $exe }
            22 { return $other }
            default { return $null }
        }
    }
    $owned = @(Select-OwnedCapsuleProcess -ExePath $exe -Processes $procs -ImagePathReader $reader)
    if ($owned.Count -ne 1 -or $owned[0].Id -ne 11) {
        Fail "owned set was [$($owned.Id -join ', ')], expected 11"
    }

    Write-Host 'capsule process filter=PASS'
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
