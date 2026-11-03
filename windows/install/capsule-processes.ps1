# Shared by install.ps1 and uninstall.ps1.
# A dsh-notch-win process is owned by this install only when its image path is
# inside the target install directory. Another checkout's helper keeps the same
# image name and must be left running.

function Normalize-CapsulePath([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $text = $Path.Trim().Trim('"')
    if ($text.StartsWith('\\?\')) { $text = $text.Substring(4) }
    try {
        $full = [System.IO.Path]::GetFullPath($text)
    } catch {
        return $null
    }
    if (Test-Path -LiteralPath $full) {
        $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
        if ($item -and $item.FullName) { $full = $item.FullName }
    }
    return $full.TrimEnd('\', '/')
}

function Test-CapsulePathUnderInstall([string]$ImagePath, [string]$InstallDirectory) {
    $image = Normalize-CapsulePath $ImagePath
    $root = Normalize-CapsulePath $InstallDirectory
    if (-not $image -or -not $root) { return $false }
    if ([string]::Equals($image, $root, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    foreach ($sep in @('\', '/')) {
        $prefix = $root + $sep
        if ($image.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Resolve-CapsuleImagePath {
    param(
        [string]$DirectPath,
        [string]$FallbackPath,
        [string]$OwnerUser,
        [string]$CurrentUser,
        [string]$EnvUser
    )
    if (-not [string]::IsNullOrWhiteSpace($DirectPath)) { return $DirectPath.Trim() }
    if ([string]::IsNullOrWhiteSpace($FallbackPath) -or [string]::IsNullOrWhiteSpace($OwnerUser)) { return $null }
    $sameUser = $false
    foreach ($candidate in @($CurrentUser, $EnvUser)) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ([string]::Equals($OwnerUser, $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
            $sameUser = $true
        }
    }
    if (-not $sameUser) { return $null }
    return $FallbackPath.Trim()
}

function Get-CapsuleImagePath($Process) {
    $direct = $null
    try { $direct = [string]$Process.Path } catch { $direct = $null }
    if ([string]::IsNullOrWhiteSpace($direct)) {
        try { $direct = [string]$Process.MainModule.FileName } catch { $direct = $null }
    }

    $fallback = $null
    $ownerUser = $null
    $currentUser = $null
    if ([string]::IsNullOrWhiteSpace($direct)) {
        try {
            $cim = Get-CimInstance -ClassName Win32_Process -Filter "ProcessId = $($Process.Id)" -ErrorAction Stop
            $owner = Invoke-CimMethod -InputObject $cim -MethodName GetOwner -ErrorAction Stop
            $ownerUser = [string]$owner.User
            $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
            $currentUser = $identity.Split('\')[-1]
            $fallback = [string]$cim.ExecutablePath
        } catch {
            $fallback = $null
        }
    }

    return Resolve-CapsuleImagePath -DirectPath $direct -FallbackPath $fallback -OwnerUser $ownerUser -CurrentUser $currentUser -EnvUser $env:USERNAME
}

function Get-InstallDirectory([string]$ExePath) {
    $normalized = Normalize-CapsulePath $ExePath
    if (-not $normalized) { return $null }
    return [System.IO.Path]::GetDirectoryName($normalized)
}

function Select-OwnedCapsuleProcess {
    param(
        [Parameter(Mandatory = $true)][string]$ExePath,
        $Processes = $null,
        [scriptblock]$ImagePathReader = $null
    )
    $installDir = Get-InstallDirectory $ExePath
    if (-not $installDir) { return }
    if ($null -eq $Processes) {
        $Processes = @(Get-Process -Name 'dsh-notch-win' -ErrorAction SilentlyContinue)
    }
    foreach ($proc in @($Processes)) {
        if ($null -eq $proc) { continue }
        $image = if ($ImagePathReader) { & $ImagePathReader $proc } else { Get-CapsuleImagePath $proc }
        if (Test-CapsulePathUnderInstall -ImagePath ([string]$image) -InstallDirectory $installDir) {
            $proc
        }
    }
}
