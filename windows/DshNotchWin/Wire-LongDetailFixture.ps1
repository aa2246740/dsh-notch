# Idempotent wiring for the #4 NotchWindow.cs long-detail selftest sites.
# No-op when the file already calls LongDetailSelftestFixture.
# Newline-agnostic so CRLF checkouts and LF blobs both match.
$ErrorActionPreference = "Stop"
$windowPath = Join-Path $PSScriptRoot "NotchWindow.cs"
$text = [System.IO.File]::ReadAllText($windowPath)
if ($text.Contains("LongDetailSelftestFixture")) {
    return
}

$crlf = $text.Contains("`r`n")
$norm = $text.Replace("`r`n", "`n").Replace("`r", "`n")

$askPattern = '(?s)if \(longDetail\)\n        \{\n            // Past the 240-character threshold with room to spare:.*?\n            for \(int i = 0; i < 3; i\+\+\)\n            \{.*?\n            \}\n        \}'
$askReplacement = @'
if (longDetail)
        {
            // Past the 240-character threshold AND taller than the screen-capped
            // panel at 100% DPI (a short pad filled 2560x1392 exactly).
            NativeMethods.RECT work = WorkAreaAtEdge();
            detail.Append('\n');
            detail.Append(LongDetailSelftestFixture.BuildMarkdown(work.Bottom - work.Top));
        }
'@.Replace("`r`n", "`n")

$wired = [regex]::Replace($norm, $askPattern, $askReplacement, 1)
if ($wired -eq $norm) {
    throw "Wire-LongDetailFixture: InjectSyntheticAsk pad site not found in $windowPath"
}

$oldDeliver = "DeliverSnapshot(longDetailSnapshot);"
$newDeliver = "NativeMethods.RECT fixtureWork = WorkAreaAtEdge();`n            DeliverSnapshot(LongDetailSelftestFixture.BuildSnapshotJson(fixtureWork.Bottom - fixtureWork.Top));"
if (-not $wired.Contains($oldDeliver)) {
    throw "Wire-LongDetailFixture: DeliverSnapshot(longDetailSnapshot) site not found in $windowPath"
}
$wired = $wired.Replace($oldDeliver, $newDeliver)

if ($crlf) {
    $wired = $wired.Replace("`n", "`r`n")
}

$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($windowPath, $wired, $utf8)
Write-Host "Wired LongDetailSelftestFixture into $windowPath"
