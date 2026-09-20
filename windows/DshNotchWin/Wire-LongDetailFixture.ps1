# Idempotent wiring for the #4 NotchWindow.cs long-detail selftest sites.
# No-op when the file already calls LongDetailSelftestFixture (this branch).
# Needed so GitHub can receive the fixture without uploading the 260KB window file
# over HTTPS (this worker has no git token; MCP writes small files).
$ErrorActionPreference = "Stop"
$windowPath = Join-Path $PSScriptRoot "NotchWindow.cs"
$text = [System.IO.File]::ReadAllText($windowPath)
if ($text.Contains("LongDetailSelftestFixture")) {
    return
}

$oldAsk = @"
        if (longDetail)
        {
            // Past the 240-character threshold with room to spare: the panel then
            // fills the screen and this detail becomes its own scroll area.
            for (int i = 0; i < 3; i++)
            {
                detail.Append("\n每一阶段都要留下可复现的证据：自检项、截图与实测数字，而不是一句已经完成。"
                    + "卸载要能一键回滚到未安装状态，且不在系统里留下任何残留文件与注册表项。"
                    + "安装脚本必须能在没有管理员权限的情况下完成接入，并保证重复执行是幂等的。\n");
            }
        }
"@

$newAsk = @"
        if (longDetail)
        {
            // Past the 240-character threshold AND taller than the screen-capped
            // panel at 100% DPI (a short pad filled 2560x1392 exactly).
            NativeMethods.RECT work = WorkAreaAtEdge();
            detail.Append('\n');
            detail.Append(LongDetailSelftestFixture.BuildMarkdown(work.Bottom - work.Top));
        }
"@

if (-not $text.Contains($oldAsk)) {
    throw "Wire-LongDetailFixture: InjectSyntheticAsk pad site not found in $windowPath"
}

$text = $text.Replace($oldAsk, $newAsk)

$oldDeliver = "DeliverSnapshot(longDetailSnapshot);"
$newDeliver = "NativeMethods.RECT fixtureWork = WorkAreaAtEdge();`n            DeliverSnapshot(LongDetailSelftestFixture.BuildSnapshotJson(fixtureWork.Bottom - fixtureWork.Top));"
if (-not $text.Contains($oldDeliver)) {
    throw "Wire-LongDetailFixture: DeliverSnapshot(longDetailSnapshot) site not found in $windowPath"
}

$text = $text.Replace($oldDeliver, $newDeliver)
$utf8 = New-Object System.Text.UTF8Encoding $false
[System.IO.File]::WriteAllText($windowPath, $text, $utf8)
Write-Host "Wired LongDetailSelftestFixture into $windowPath"
