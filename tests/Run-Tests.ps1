<#
.SYNOPSIS
    Tests Restore-Claude.ps1 in a throw-away sandbox. Nothing outside %TEMP%\claude-backup-tests is written.

.DESCRIPTION
    Each scenario builds a fake backup zip (same format as Backup-Claude.ps1 writes) for a fake "old PC",
    then restores it with -Apply into a fake "new PC". USERPROFILE, LOCALAPPDATA and APPDATA are pointed
    into the sandbox for the restore, so it cannot reach real files. Claude may be running: -Force is used.

    Scenarios cover Claude Desktop data layouts (Store app version 2 and 3, classic install, installed but
    never opened), a new Windows user name, long paths, safety copies, sign-in cleanup, a drive that does
    not exist, and that workspace files are never rewritten. Plus unit tests for the sign-in cleanup.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
#>
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$restore = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-Claude.ps1'
$root = Join-Path $env:TEMP 'claude-backup-tests'
$pfn = 'Claude_pzs8sxrjxfjjc'
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:failures = 0

function Check([string]$Name, $Ok) {
    if ($Ok) { Write-Host "  PASS  $Name" -ForegroundColor Green } else { Write-Host "  FAIL  $Name" -ForegroundColor Red; $script:failures++ }
}
function J([string]$Path) { $Path.Replace('\', '\\') }
function ZipName([string]$Path) { $Path.Substring(0, 1) + '/' + $Path.Substring(3).Replace('\', '/') }
function Read-Long([string]$Path) { [IO.File]::ReadAllText("\\?\$Path") }
function DeskPath([string]$HomeDir, [string]$Layout) {
    switch ($Layout) {
        'v3'      { "$HomeDir\AppData\Local\Claude-Data\$($pfn.ToLower())" }
        'v2'      { "$HomeDir\AppData\Local\Packages\$pfn\LocalCache\Roaming\Claude" }
        'classic' { "$HomeDir\AppData\Roaming\Claude" }
    }
}

# ---- Restore scenarios ---------------------------------------------------------------------------------
function Test-Scenario([string]$BackupLayout, [string]$TargetLayout) {
    Write-Host ''
    Write-Host "Backup made with Claude Desktop '$BackupLayout', restored onto '$TargetLayout'" -ForegroundColor Cyan
    $S = Join-Path $root "$BackupLayout-to-$TargetLayout"
    if (Test-Path $S) { Remove-Item $S -Recurse -Force }
    $old = "$S\oldhome"; $new = "$S\newhome"; $work = "$S\work"
    $oldDesk = DeskPath $old $BackupLayout
    $newDesk = if ($TargetLayout -ne 'unopened') { DeskPath $new $TargetLayout } else { $null }
    $stamp = [datetime]::new(2026, 10, 1, 10, 0, 0, [DateTimeKind]::Utc)
    $missingDrive = [char[]](90..68) | ForEach-Object { "$_" } | Where-Object { -not (Test-Path "$($_):\") } | Select-Object -First 1

    # What the "old PC" had
    $files = [ordered]@{}
    $files["$old\.claude\settings.json"]         = '{"hooks":{"x":"' + (J $old) + '\\.claude\\hook.ps1"},"other":"' + (J $old) + 'X\\nope"}'
    $files["$old\.claude\notes.txt"]             = 'new file'
    $files["$old\.claude\replace.txt"]           = 'from backup'
    $files["$old\.claude\same.txt"]              = 'identical'
    $deep = "$old\.claude\" + ('d' * 90) + '\' + ('e' * 90)
    $files["$deep\deep-new.txt"]                 = 'deep new'
    $files["$deep\deep-replace.txt"]             = 'deep from backup'
    $files["$oldDesk\config.json"]               = '{"a":1,"oauth:tokenCache":"djEwOLDOLDOLD","b":"x","oauth:tokenCacheV2":"djEwOLD2OLD2","dxt:allowlistCache:f0":"djEwCACHE"}'
    $files["$oldDesk\claude_desktop_config.json"] = '{"mcpServers":{"demo":{"command":"node","args":["' + (J $old) + '\\mcp\\demo\\index.js"]}}}'
    $files["$oldDesk\claude-code-sessions\acct\org\local_1.json"] = '{"sessionId":"local_1","cliSessionId":"abc","cwd":"' + (J $work) + '"}'
    $files["$old\mcp\demo\config.json"]          = '{"keyFile":"' + (J $old) + '\\mcp\\key.json"}'
    $files["$work\data.json"]                    = '{"note":"' + (J $old) + '\\stays as it is"}'
    $files["$work\.claude\settings.local.json"]  = '{"dir":"' + (J $old) + '\\x"}'
    if ($missingDrive) { $files["$($missingDrive):\Elsewhere\file.txt"] = 'on a drive this PC does not have' }
    if (-not $isAdmin) { $files['C:\ProgramData\ClaudeRestoreTest\x.log'] = 'held back without Administrator' }
    $sources = @(
        @{ Path = "$old\.claude"; Kind = 'ClaudeCode'; Label = 'Claude Code' }
        @{ Path = $oldDesk; Kind = 'ClaudeDesktop'; Label = 'Claude Desktop' }
        @{ Path = "$old\mcp"; Kind = 'McpServer'; Label = 'MCP servers' }
        @{ Path = $work; Kind = 'Workspace'; Label = 'Workspace' }
        @{ Path = "$($missingDrive):\Elsewhere"; Kind = 'Workspace'; Label = 'Workspace' }
        @{ Path = 'C:\ProgramData\ClaudeRestoreTest'; Kind = 'ClaudeService'; Label = 'Claude service log' }
    )
    function Get-Source([string]$Path) { ($sources | Where-Object { $Path.StartsWith($_.Path + '\', [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1).Path }

    # What the "new PC" already has
    $newDeep = $deep.Replace($old, $new)
    New-Item -ItemType Directory -Force "$new\.claude" | Out-Null
    Set-Content "$new\.claude\replace.txt" 'local version' -NoNewline
    Set-Content "$new\.claude\same.txt" 'identical' -NoNewline; (Get-Item "$new\.claude\same.txt").LastWriteTimeUtc = $stamp
    [void][IO.Directory]::CreateDirectory("\\?\$newDeep"); [IO.File]::WriteAllText("\\?\$newDeep\deep-replace.txt", 'deep local')
    if ($TargetLayout -eq 'v3') { New-Item -ItemType Directory -Force (DeskPath $new 'v2') | Out-Null; Set-Content "$(DeskPath $new 'v2')\.user-data-left.claude_pzs8sxrjxfjjc" '' -NoNewline }
    if ($newDesk) {
        New-Item -ItemType Directory -Force $newDesk | Out-Null
        Set-Content "$newDesk\config.json" '{"oauth:tokenCache":"djEwNEWNEWNEW","z":2}' -NoNewline
        Set-Content "$newDesk\Local State" '{"os_crypt":{"encrypted_key":"NEWKEY"}}' -NoNewline
    }

    # The backup zip
    $zipPath = "$S\claude-backup_test.zip"
    $zip = [IO.Compression.ZipFile]::Open($zipPath, 'Create')
    $manifest = foreach ($p in $files.Keys) {
        $e = $zip.CreateEntry((ZipName $p)); $e.LastWriteTime = [DateTimeOffset]$stamp
        $w = New-Object IO.StreamWriter -ArgumentList $e.Open(); $w.Write($files[$p]); $w.Dispose()
        [pscustomobject]@{ Source = Get-Source $p; Type = 'File'; ZipPath = ZipName $p; OriginalPath = $p; Bytes = [Text.Encoding]::UTF8.GetByteCount($files[$p]); LastWriteUtc = $stamp.ToString('o') }
    }
    $manifest = @($manifest) + [pscustomobject]@{ Source = "$old\.claude"; Type = 'Dir'; ZipPath = (ZipName "$old\.claude\emptydir") + '/'; OriginalPath = "$old\.claude\emptydir"; Bytes = 0; LastWriteUtc = '' }
    [void]$zip.CreateEntry((ZipName "$old\.claude\emptydir") + '/')
    $info = [ordered]@{
        Tool = 'Claude backup (test)'; Created = $stamp.ToString('o'); Computer = 'OLDPC'; UserProfile = $old
        DesktopPackageFamilyName = $(if ($BackupLayout -ne 'classic') { $pfn }); DesktopDataPath = $oldDesk; DesktopKeyHash = 'OLDHASH'
        NodeVersion = 'v24.0.0'; Workspaces = [string[]]@($work)
        Sources = @($sources | ForEach-Object { [pscustomobject]@{ Path = $_.Path; Kind = $_.Kind; Label = $_.Label; Files = 1; Bytes = 1; Found = $true } })
    }
    foreach ($t in @(@('_restore/backup-info.json', ($info | ConvertTo-Json -Depth 4)), @('_restore/manifest.csv', (($manifest | ConvertTo-Csv -NoTypeInformation) -join "`r`n")))) {
        $w = New-Object IO.StreamWriter -ArgumentList $zip.CreateEntry($t[0]).Open(); $w.Write($t[1]); $w.Dispose()
    }
    $zip.Dispose()

    # Restore into the sandbox: the child process sees the sandbox as its user folders
    $saved = @{ USERPROFILE = $env:USERPROFILE; LOCALAPPDATA = $env:LOCALAPPDATA; APPDATA = $env:APPDATA }
    try {
        $env:USERPROFILE = $new; $env:LOCALAPPDATA = "$new\AppData\Local"; $env:APPDATA = "$new\AppData\Roaming"
        $out = powershell -NoProfile -ExecutionPolicy Bypass -File $restore -ZipPath $zipPath -Apply -Force 2>&1 | Out-String
    }
    finally { foreach ($k in $saved.Keys) { Set-Item "env:$k" $saved[$k] } }
    if ($out -match 'Exception|Error') { Write-Host $out -ForegroundColor DarkGray }

    $safety = Get-ChildItem $S -Directory -Filter 'pre-restore_*' | Select-Object -First 1
    $idx = if ($safety) { @(Import-Csv "$($safety.FullName)\INDEX.csv") } else { @() }
    $set = Read-Long "$new\.claude\settings.json"
    Check 'new file created'                          ((Read-Long "$new\.claude\notes.txt") -eq 'new file')
    Check 'changed file replaced, old one saved'      ((Read-Long "$new\.claude\replace.txt") -eq 'from backup' -and ($idx | Where-Object OriginalPath -eq "$new\.claude\replace.txt"))
    Check 'identical file left alone'                 ((Get-Item "$new\.claude\same.txt").LastWriteTimeUtc -eq $stamp)
    Check 'empty folder recreated'                    (Test-Path "$new\.claude\emptydir")
    Check 'Claude config path -> new user folder'     ($set -like ('*' + (J $new) + '\\.claude\\hook.ps1*'))
    Check 'look-alike path left alone'                ($set -like ('*' + (J $old) + 'X\\nope*'))
    Check 'MCP server config path -> new user folder' ((Read-Long "$new\mcp\demo\config.json") -like ('*' + (J $new) + '\\mcp\\key.json*'))
    Check 'workspace file NOT rewritten'              ((Read-Long "$work\data.json") -like ('*' + (J $old) + '\\stays as it is*'))
    Check 'workspace .claude settings path updated'   ((Read-Long "$work\.claude\settings.local.json") -like ('*' + (J $new) + '\\x*'))
    Check 'long-path files restored and saved'        ((Read-Long "$newDeep\deep-new.txt") -eq 'deep new' -and (Read-Long "$newDeep\deep-replace.txt") -eq 'deep from backup' -and ($idx | Where-Object OriginalPath -eq "$newDeep\deep-replace.txt"))
    if ($missingDrive) { Check "drive $($missingDrive): held back"  ($out -match "drive $($missingDrive): does not exist") }
    if (-not $isAdmin) { Check 'ProgramData held back (not admin)' (-not (Test-Path 'C:\ProgramData\ClaudeRestoreTest') -and $out -match 'needs PowerShell opened as Administrator') }

    $others = @('v2', 'v3', 'classic' | ForEach-Object { DeskPath $new $_ } | Where-Object { $_ -ne $newDesk })
    if ($newDesk) {
        $cfg = Read-Long "$newDesk\config.json"
        Check "Desktop data went where this PC's app keeps it ($TargetLayout)" ((Test-Path "$newDesk\claude_desktop_config.json") -and (Test-Path "$newDesk\claude-code-sessions\acct\org\local_1.json"))
        Check 'nothing written to the other Desktop locations' (-not ($others | Where-Object { Test-Path "$_\claude_desktop_config.json" }))
        Check 'Desktop MCP path -> new user folder'   ((Read-Long "$newDesk\claude_desktop_config.json") -like ('*' + (J $new) + '\\mcp\\demo\\index.js*'))
        Check 'sign-in: old tokens out, this PC''s kept, JSON valid' ([bool]$(try { $cfg | ConvertFrom-Json } catch { $null }) -and $cfg -like '*djEwNEWNEWNEW*' -and $cfg -notlike '*djEwOLD*' -and $cfg -notlike '*djEwCACHE*' -and ($cfg | ConvertFrom-Json).a -eq 1)
    }
    else {
        Check 'Desktop data held back (never opened)' ($out -match 'has not been opened on this PC yet|is not installed on this PC yet')
        Check 'no Desktop data written anywhere'       (-not ($others | Where-Object { Test-Path "$_\claude_desktop_config.json" }))
    }
}

# ---- Sign-in cleanup unit tests ------------------------------------------------------------------------
function Test-SignInCleanup {
    Write-Host ''
    Write-Host 'Sign-in cleanup (config.json edits)' -ForegroundColor Cyan
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($restore, [ref]$null, [ref]$null)
    foreach ($fn in $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -in 'Repair-SignIn', 'Write-TextFile', 'Test-ValidJson', 'Get-LongPath' }, $true)) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
    $script:EncryptedPair = '"(?<key>[^"\\]+)"\s*:\s*"(?<value>djE[wx][A-Za-z0-9+/=]*)"'
    $f = Join-Path $root 'signin-unit.json'
    [void][IO.Directory]::CreateDirectory($root)
    $cases = @(
        @{ n = 'last member removed';   in = '{"a":1,"b":"x","t2":"djEwOLD"}';     keep = @{};                 want = 'a', 'b' }
        @{ n = 'middle member removed'; in = '{"a":1,"t2":"djEwOLD","b":"x"}';     keep = @{};                 want = 'a', 'b' }
        @{ n = 'first member removed';  in = '{"t2":"djEwOLD","a":1}';             keep = @{};                 want = @('a') }
        @{ n = 'only member removed';   in = '{"t2":"djEwOLD"}';                   keep = @{};                 want = @() }
        @{ n = 'two in a row at end';   in = '{"a":1,"t1":"djEwA","t2":"djExB"}';  keep = @{};                 want = @('a') }
        @{ n = 'pretty-printed JSON';   in = "{`n  `"a`": 1,`n  `"t1`": `"djEwA`",`n  `"b`": [1,2]`n}"; keep = @{}; want = 'a', 'b' }
        @{ n = 'kept value replaces';   in = '{"t1":"djEwOLD","a":1}';             keep = @{ t1 = 'djEwNEW' }; want = 't1', 'a' }
        @{ n = 'kept value inserted';   in = '{"a":1}';                            keep = @{ t1 = 'djEwNEW' }; want = 't1', 'a' }
        @{ n = 'kept into emptied obj'; in = '{"t2":"djEwOLD"}';                   keep = @{ t1 = 'djEwNEW' }; want = @('t1') }
    )
    foreach ($c in $cases) {
        [IO.File]::WriteAllText($f, $c.in)
        [void](Repair-SignIn $f $c.keep)
        $out = [IO.File]::ReadAllText($f)
        $obj = try { $out | ConvertFrom-Json } catch { $null }
        $names = if ($obj) { @($obj.PSObject.Properties.Name) } else { @('INVALID') }
        Check $c.n (($null -ne $obj) -and ($names.Count -eq @($c.want).Count) -and -not (@($c.want) | Where-Object { $names -notcontains $_ }) -and ($out -notmatch 'OLD|djExB|djEwA'))
    }
}

if (Test-Path $root) { Remove-Item $root -Recurse -Force }
foreach ($combo in @(@('v2', 'v3'), @('v3', 'v3'), @('v2', 'v2'), @('classic', 'v3'), @('v3', 'classic'), @('v3', 'unopened'))) {
    Test-Scenario $combo[0] $combo[1]
}
Test-SignInCleanup

Write-Host ''
if ($script:failures) { Write-Host "$script:failures check(s) failed." -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
Remove-Item $root -Recurse -Force
