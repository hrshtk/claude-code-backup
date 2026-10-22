<#
.SYNOPSIS
    Backs up Claude Code and Claude Desktop - settings, chats, MCP servers and the workspaces you pick -
    into a new folder in Downloads, ready to restore on this PC or another one.

.DESCRIPTION
    1. Finds Claude on this PC: Claude Code (%USERPROFILE%\.claude, or CLAUDE_CONFIG_DIR), Claude Desktop
       (Store or classic install, old and new data locations) and their logs. These are always backed up.
    2. Finds your workspaces - the folders you work in with Claude - from your chat history, Claude
       Desktop's session list and Claude Code's project list, plus the folders your local MCP servers
       run from. You choose which to include. If none are found, it asks you for folders.
    3. Creates Downloads\Claude-Backup_<date>_<time>\ holding the backup zip, Restore-Claude.bat,
       Restore-Claude.ps1 and README.txt.

    Files are stored as they are (uncompressed unless -Compress), each under its full original path.
    Caches and files that only work on this PC (encrypted cookies and the key for them, lists of running
    processes, lock files) are left out; README.txt lists them with the reason.

.PARAMETER Workspace
    Folders to include, instead of choosing from the menu.
.PARAMETER AllWorkspaces
    Include every workspace found, except very broad ones such as a whole drive or your user folder.
.PARAMETER NoWorkspaces
    Back up Claude's own data and MCP server folders only.
.PARAMETER OutputRoot
    Where the new backup folder is created. Default: your Downloads folder.
.PARAMETER Compress
    Compress files for a smaller zip (slower). By default files are stored uncompressed.
.PARAMETER Yes
    Ask nothing. Uses -Workspace / -AllWorkspaces / -NoWorkspaces, or else the recommended selection.
.PARAMETER ListOnly
    Show what was found, then stop without backing anything up.
.PARAMETER OpenFolder
    Open the backup folder in Explorer when done (Backup-Claude.bat uses this).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Backup-Claude.ps1
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Backup-Claude.ps1 -Workspace 'D:\Code\my-app', 'C:\Notes' -Yes
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Backup-Claude.ps1 -ListOnly

.NOTES
    Claude Backup for Windows, by Harshit Kushwaha (https://www.linkedin.com/in/hrshtk/). MIT license.
#>
[CmdletBinding()]
param(
    [string[]]$Workspace,
    [switch]$AllWorkspaces,
    [switch]$NoWorkspaces,
    [string]$OutputRoot,
    [switch]$Compress,
    [switch]$Yes,
    [switch]$ListOnly,
    [switch]$OpenFolder
)

$ErrorActionPreference = 'Stop'
$ToolVersion = '1.0.0'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$UserHome = $env:USERPROFILE.TrimEnd('\')
$MarkerName = '.claude-backup-folder'   # marks folders this tool creates, so later backups skip them

# ---- Skip rules ---------------------------------------------------------------------------------------
# Rel = path relative to a backed-up location, Name = folder/file name anywhere inside it.
$ClaudeHomeSkips = @(
    @{ Rel = 'cache';           Why = 'Cache (model list) - downloaded again' }
    @{ Rel = 'sessions';        Why = 'List of running Claude processes - only valid until they exit' }
    @{ Rel = 'shell-snapshots'; Why = 'Snapshot of this PC''s shell setup - recreated every session' }
    @{ Rel = 'session-env';     Why = 'Per-session temp data - recreated' }
)
$DesktopCacheNames = 'Cache', 'Code Cache', 'GPUCache', 'GPUPersistentCache', 'GrShaderCache', 'ShaderCache',
                     'DawnGraphiteCache', 'DawnWebGPUCache', 'Shared Dictionary', 'blob_storage'
$DesktopSkips = @(
    @{ Name = $DesktopCacheNames;  Why = 'Cache - rebuilt automatically' }
    @{ Name = 'Network';           Why = 'Cookies encrypted for this PC only - you sign in again instead' }
    @{ Rel  = 'Local State';       Why = 'Encryption key locked to this Windows account - recreated automatically' }
    @{ Name = 'LOCK', 'lockfile';  Why = 'In-use lock file - recreated automatically' }
)
# Like = wildcard on file/folder names. Earlier backups are never packed into a new one.
$EarlierBackupNames = 'claude-backup_*.zip', 'claude-backup_*.zip.partial', 'pre-restore_????-??-??_??????'
$SkipEverywhere = @(
    @{ Name = '__pycache__';             Why = 'Python cache - rebuilt automatically' }
    @{ Like = $EarlierBackupNames;       Why = 'An earlier Claude backup or restore safety copy' }
)

# Already-compressed formats are never deflated again, even with -Compress.
$StoreOnly = '.zip', '.7z', '.gz', '.rar', '.xlsx', '.docx', '.pptx', '.png', '.jpg', '.jpeg', '.gif',
             '.webp', '.mp4', '.webm', '.woff', '.woff2', '.exe'

# Files a backup should warn about, because they usually hold keys or passwords.
$SecretFilePattern = '^\.env(\..+)?$|service-account.*\.json$|^credentials?\.json$|\.pem$|\.pfx$|^id_(rsa|ed25519|ecdsa)$'

# ---- Helpers --------------------------------------------------------------------------------------------
function Format-Size([double]$Bytes) {
    if ($Bytes -ge 1GB) { '{0:N2} GB' -f ($Bytes / 1GB) }
    elseif ($Bytes -ge 1MB) { '{0:N1} MB' -f ($Bytes / 1MB) }
    else { '{0:N0} KB' -f [math]::Ceiling($Bytes / 1KB) }
}

# C:\Users\x\file.txt -> C/Users/x/file.txt
function ConvertTo-ZipPath([string]$FullPath) {
    $FullPath.Substring(0, 1).ToUpper() + '/' + $FullPath.Substring(3).Replace('\', '/')
}

# Files are read through "\\?\C:\..." paths, which lift Windows' 260-character limit (some Claude Desktop
# plugin files are deeper than that); everything shown or stored uses the normal path.
function Get-PlainPath([string]$Path) { if ($Path.StartsWith('\\?\')) { $Path.Substring(4) } else { $Path } }

function Test-UnderPath([string]$Path, [string]$Parent) {
    $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
    $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

function Test-UnderAny([string]$Path, [string[]]$Parents) {
    foreach ($p in $Parents) { if ($p -and (Test-UnderPath $Path $p)) { return $true } }
    $false
}

function Test-NameLike([string]$Name, [string[]]$Patterns) {
    foreach ($p in $Patterns) { if ($Name -like $p) { return $true } }
    $false
}

# "C:/x/" -> "C:\x". $null for anything that is not a local absolute path.
function Get-NormalPath([string]$Path) {
    if (-not $Path) { return $null }
    $p = $Path.Trim().Trim('"').Replace('/', '\')
    if ($p -notmatch '^[A-Za-z]:(\\|$)') { return $null }
    try { $p = [IO.Path]::GetFullPath($p) } catch { return $null }
    if ($p.Length -gt 3) { $p = $p.TrimEnd('\') }
    $p.Substring(0, 1).ToUpper() + $p.Substring(1)
}

function Get-DownloadsFolder {
    try {
        $v = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}'
        if ($v) { $v = [Environment]::ExpandEnvironmentVariables($v); if (Test-Path -LiteralPath $v) { return $v.TrimEnd('\') } }
    } catch { }
    "$UserHome\Downloads"
}

# Folders too broad to back up as one workspace: a whole drive, the user folder, Desktop, Documents, ...
$BroadPaths = @($UserHome, "$UserHome\AppData", [Environment]::GetFolderPath('Desktop'), [Environment]::GetFolderPath('MyDocuments'),
                (Get-DownloadsFolder), $env:OneDrive, $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:ProgramData,
                $env:APPDATA, $env:LOCALAPPDATA) | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') }
function Test-BroadPath([string]$Path) { ($Path -match '^[A-Za-z]:\\?$') -or ($BroadPaths -contains $Path.TrimEnd('\')) }

# Two paths are the same folder when NTFS gives them the same file ID (Windows redirects %APPDATA% for Store apps).
function Test-SameFolder([string]$A, [string]$B) {
    if (-not (Test-Path -LiteralPath $A) -or -not (Test-Path -LiteralPath $B)) { return $false }
    $ids = foreach ($p in $A, $B) {
        try { ((& fsutil file queryFileID $p) -join ' ') -replace '^.*(0x[0-9a-fA-F]+).*$', '$1' } catch { $null }
    }
    if ($ids[0] -like '0x*' -and $ids[1] -like '0x*') { return $ids[0] -eq $ids[1] }
    # fsutil unavailable: the same top-level files with the same sizes and times means the same folder
    $sig = foreach ($p in $A, $B) {
        (Get-ChildItem -LiteralPath $p -Force -File | ForEach-Object { "$($_.Name)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)" }) -join ';'
    }
    $sig[0] -eq $sig[1]
}

# Reads a file another program may be writing to (Claude keeps some of these open).
function Read-SharedText([string]$Path) {
    $fs = [IO.File]::Open("\\?\$Path", 'Open', 'Read', 'ReadWrite, Delete')
    $reader = New-Object IO.StreamReader -ArgumentList $fs
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Read-JsonFile([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Read-SharedText $Path | ConvertFrom-Json } catch { $null }
}

# The working folder recorded in a Claude Code chat transcript (each line is JSON with a "cwd" field).
function Get-TranscriptCwd([string]$File) {
    try {
        $fs = [IO.File]::Open("\\?\$File", 'Open', 'Read', 'ReadWrite, Delete')
        $reader = New-Object IO.StreamReader -ArgumentList $fs
        try {
            for ($i = 0; $i -lt 40 -and -not $reader.EndOfStream; $i++) {
                $m = [regex]::Match($reader.ReadLine(), '"cwd"\s*:\s*"((?:[^"\\]|\\.)*)"')
                if ($m.Success) { return [regex]::Unescape($m.Groups[1].Value) }
            }
        } finally { $reader.Dispose() }
    } catch { }
    $null
}

# The folder a local MCP server lives in: the nearest parent holding package.json, pyproject.toml, .git, ...
# Falls back to the file's own folder, or to just the file when that folder is too broad.
function Find-ProjectRoot([string]$File) {
    $start = Split-Path $File -Parent
    $dir = $start
    while ($dir -and -not (Test-BroadPath $dir)) {
        foreach ($m in 'package.json', 'pyproject.toml', 'requirements.txt', 'setup.py', 'Cargo.toml', 'go.mod', '.git') {
            if (Test-Path -LiteralPath (Join-Path $dir $m)) { return $dir }
        }
        $parent = Split-Path $dir -Parent
        if (-not $parent -or $parent -eq $dir) { break }
        $dir = $parent
    }
    if (Test-BroadPath $start) { $File } else { $start }
}

# Size of a folder, giving up after $Seconds (the size is then a minimum). Skips folders named in $SkipNames.
function Measure-Folder([string]$Path, [string[]]$SkipNames, [double]$Seconds = 8) {
    if (Test-Path -LiteralPath $Path -PathType Leaf) { return [pscustomobject]@{ Files = 1; Bytes = (Get-Item -LiteralPath $Path -Force).Length; Partial = $false } }
    $files = 0; [long]$bytes = 0; $partial = $false
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $stack = New-Object System.Collections.Stack
    $stack.Push([IO.DirectoryInfo]"\\?\$Path")
    while ($stack.Count -gt 0) {
        if ($clock.Elapsed.TotalSeconds -gt $Seconds) { $partial = $true; break }
        $dir = $stack.Pop()
        try { $children = $dir.GetFileSystemInfos() } catch { continue }
        foreach ($c in $children) {
            if (Test-NameLike $c.Name $EarlierBackupNames) { continue }
            if ($c -is [IO.DirectoryInfo]) {
                if (($SkipNames -contains $c.Name) -or ($c.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                if ([IO.File]::Exists("$($c.FullName)\$MarkerName")) { continue }
                $stack.Push($c)
            }
            else { $files++; $bytes += $c.Length }
        }
    }
    [pscustomobject]@{ Files = $files; Bytes = $bytes; Partial = $partial }
}

function Format-Measured($m) { if ($m.Partial) { 'over ' + (Format-Size $m.Bytes) } else { Format-Size $m.Bytes } }

# Hash of the (already encrypted) key in Claude Desktop's "Local State", so a restore can tell whether
# the sign-in tokens in config.json can still be unlocked. The key itself is not stored.
function Get-DesktopKeyHash([string]$LocalStatePath) {
    if (-not $LocalStatePath -or -not (Test-Path -LiteralPath $LocalStatePath)) { return $null }
    try {
        $key = (Read-SharedText $LocalStatePath | ConvertFrom-Json).os_crypt.encrypted_key
        if (-not $key) { return $null }
        $sha = [Security.Cryptography.SHA256]::Create()
        [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '')
    } catch { $null }
}

function Add-SkipStat([string]$Source, [string]$What, [string]$Why, $Item) {
    $key = "$Source|$What"
    if (-not $SkipStats.Contains($key)) {
        $SkipStats[$key] = [pscustomobject]@{ Source = $Source; What = $What; Why = $Why; Files = 0; Bytes = [long]0 }
    }
    $stat = $SkipStats[$key]
    if ($Item -is [IO.DirectoryInfo]) {
        try { foreach ($f in $Item.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)) { $stat.Files++; $stat.Bytes += $f.Length } } catch { }
    }
    else { $stat.Files++; $stat.Bytes += $Item.Length }
}

# Files under $Root, plus empty folders so they get recreated on restore. Links/junctions are not followed.
# $AlsoSkip: other backed-up locations inside this one (they are stored once, under their own entry).
# Returned items carry "\\?\" paths (see Get-PlainPath).
function Get-SourceItems([string]$Root, [object[]]$Rules, [string[]]$AlsoSkip) {
    $stack = New-Object System.Collections.Stack
    $stack.Push([IO.DirectoryInfo]"\\?\$Root")
    while ($stack.Count -gt 0) {
        $dir = $stack.Pop()
        try { $children = $dir.GetFileSystemInfos() }
        catch { $Skipped.Add("$(Get-PlainPath $dir.FullName)  ($($_.Exception.GetBaseException().Message))"); continue }
        if ($children.Count -eq 0) { $dir; continue }
        foreach ($c in $children) {
            $plain = Get-PlainPath $c.FullName
            if ((Test-UnderPath $plain $OutputDir) -or ($AlsoSkip -contains $plain)) { continue }
            $rel = $plain.Substring($Root.Length).TrimStart('\')
            $rule = $null
            foreach ($r in $Rules) {
                if (($r.Rel -and $rel -eq $r.Rel) -or ($r.Name -and $r.Name -contains $c.Name) -or ($r.Like -and (Test-NameLike $c.Name $r.Like))) { $rule = $r; break }
            }
            if ($rule) {
                $what = if ($rule.Rel) { $rule.Rel } elseif ($rule.Like) { $rel } else { "all '$($c.Name)'" }
                Add-SkipStat $Root $what $rule.Why $c
                continue
            }
            if ($c -is [IO.DirectoryInfo]) {
                if ($c.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    $Skipped.Add("$plain  (link/junction - not followed)"); continue
                }
                if ([IO.File]::Exists("$($c.FullName)\$MarkerName")) {
                    Add-SkipStat $Root $rel 'An earlier backup made by this tool' $c
                    continue
                }
                $stack.Push($c)
            }
            else {
                if ($c.Name -match $SecretFilePattern) { [void]$SecretFiles.Add($plain) }
                $c
            }
        }
    }
}

# A complete copy of the file (in memory, or a temp file for big ones), so a read error can't leave a
# half-written entry in the zip.
function Read-SourceFile([string]$Path) {
    $in = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite, Delete')
    $copy = $null
    try {
        $copy = if ($in.Length -le 64MB) { New-Object IO.MemoryStream }
                else { New-Object IO.FileStream -ArgumentList $StagingFile, ([IO.FileMode]::Create), ([IO.FileAccess]::ReadWrite), ([IO.FileShare]::None), 81920, ([IO.FileOptions]::DeleteOnClose) }
        $in.CopyTo($copy)
        $copy.Position = 0
        $copy
    }
    catch { if ($copy) { $copy.Dispose() }; throw }
    finally { $in.Dispose() }
}

function Add-TextEntry($Zip, [string]$Name, [string]$Text) {
    $writer = New-Object IO.StreamWriter -ArgumentList $Zip.CreateEntry($Name).Open(), (New-Object Text.UTF8Encoding $true)
    try { $writer.Write($Text) } finally { $writer.Dispose() }
}

# Byte-for-byte copy (a .bat must not gain a UTF-8 byte-order mark, or cmd.exe can't run it).
function Add-FileEntry($Zip, [string]$Name, [string]$Path) {
    $out = $Zip.CreateEntry($Name).Open()
    try { $bytes = [IO.File]::ReadAllBytes($Path); $out.Write($bytes, 0, $bytes.Length) } finally { $out.Dispose() }
}

# Read-Host that treats end of input (no console attached) as a plain Enter.
function Read-Answer([string]$Prompt) {
    $a = Read-Host $Prompt
    if ($null -eq $a) { '' } else { $a.Trim() }
}

function Write-Title([string]$Text) { Write-Host ''; Write-Host $Text -ForegroundColor Cyan }

# ---- 1. Find Claude on this PC ----------------------------------------------------------------------------
$explicit = [bool]($Workspace -or $AllWorkspaces -or $NoWorkspaces)
$interactive = -not $Yes -and -not $explicit -and -not $ListOnly
$ask = -not $Yes -and -not $ListOnly

Write-Host "Claude backup $ToolVersion" -ForegroundColor Cyan
Write-Host 'Looking for Claude on this PC...'

$ClaudeHome = if ($env:CLAUDE_CONFIG_DIR) { Get-NormalPath $env:CLAUDE_CONFIG_DIR } else { "$UserHome\.claude" }
if (-not (Test-Path -LiteralPath $ClaudeHome -PathType Container)) {
    $ClaudeHome = $null
    if ($ask) {
        Write-Host "Claude Code's folder was not found (it is usually $UserHome\.claude)." -ForegroundColor Yellow
        while ($true) {
            $answer = Read-Answer 'Type its full path, or press Enter if you do not use Claude Code'
            if (-not $answer) { break }
            $p = Get-NormalPath $answer
            if ($p -and (Test-Path -LiteralPath $p -PathType Container)) { $ClaudeHome = $p; break }
            Write-Host "  Not a folder: $answer" -ForegroundColor Yellow
        }
    }
}
$ClaudeJsonMain = @("$UserHome\.claude.json", $(if ($ClaudeHome -and $env:CLAUDE_CONFIG_DIR) { "$ClaudeHome\.claude.json" })) |
    Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -Unique

# Claude Desktop: Store app version 3+ keeps its data in %LOCALAPPDATA%\Claude-Data\<package>; version 2 kept it
# inside the package folder (seen by Claude itself as %APPDATA%\Claude); a classic install uses %APPDATA%\Claude.
$DesktopPackage = try { Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null }
$DesktopPfn = if ($DesktopPackage) { $DesktopPackage.PackageFamilyName } else { 'Claude_pzs8sxrjxfjjc' }
$storeV3 = "$env:LOCALAPPDATA\Claude-Data\$($DesktopPfn.ToLower())"
$storeV2 = "$env:LOCALAPPDATA\Packages\$DesktopPfn\LocalCache\Roaming\Claude"
$classic = "$env:APPDATA\Claude"
$DesktopPlaces = @(@($storeV3, $storeV2) | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
if ((Test-Path -LiteralPath $classic -PathType Container) -and -not (Test-SameFolder $classic $storeV2)) { $DesktopPlaces += $classic }
$DesktopData = $DesktopPlaces | Where-Object { Test-Path -LiteralPath "$_\config.json" } | Select-Object -First 1
if (-not $DesktopData -and $DesktopPlaces) { $DesktopData = $DesktopPlaces[0] }
$DesktopKind = if (-not $DesktopData) { $null } elseif ($DesktopData -eq $classic) { 'classic install' } else { "Store app $(if ($DesktopPackage) { $DesktopPackage.Version } else { '(not installed now)' })" }
$DesktopLogs = "$env:LOCALAPPDATA\Claude"
$ServiceLogs = "$env:ProgramData\Claude"

if (-not $ClaudeHome -and -not $DesktopData -and -not $ClaudeJsonMain) {
    throw 'No Claude Code or Claude Desktop data was found on this PC, so there is nothing to back up.'
}

Write-Title 'Claude found on this PC (always backed up):'
if ($ClaudeHome) { Write-Host "  Claude Code            $ClaudeHome" }
foreach ($f in $ClaudeJsonMain) { Write-Host "  Claude Code settings   $f" }
if ($DesktopData) { Write-Host "  Claude Desktop         $DesktopData  ($DesktopKind)" }
foreach ($p in $DesktopPlaces | Where-Object { $_ -ne $DesktopData }) { Write-Host "  Claude Desktop (older) $p" }
if (Test-Path -LiteralPath $DesktopLogs) { Write-Host "  Claude Desktop logs    $DesktopLogs" }
if (Test-Path -LiteralPath $ServiceLogs) { Write-Host "  Claude service log     $ServiceLogs" }

# ---- 2. Find workspaces and MCP server folders --------------------------------------------------------------
Write-Host ''
Write-Host 'Looking for your workspaces and MCP servers...'
$wsMap = @{}
function Add-WorkspaceHit([string]$RawPath, [string]$Kind, [datetime]$When) {
    $p = Get-NormalPath $RawPath
    if (-not $p) { return }
    $k = $p.ToLower()
    if (-not $wsMap.ContainsKey($k)) { $wsMap[$k] = [pscustomobject]@{ Path = $p; Chats = 0; Cards = 0; Last = [datetime]::MinValue } }
    $w = $wsMap[$k]
    if ($Kind -eq 'chat') { $w.Chats++ } elseif ($Kind -eq 'card') { $w.Cards++ }
    if ($When -gt $w.Last) { $w.Last = $When }
}
if ($ClaudeHome) {
    foreach ($f in @(Get-ChildItem -Path "$ClaudeHome\projects\*\*.jsonl" -File -Force -ErrorAction SilentlyContinue)) {
        $cwd = Get-TranscriptCwd $f.FullName
        if ($cwd) { Add-WorkspaceHit $cwd 'chat' $f.LastWriteTime }
    }
}
foreach ($place in $DesktopPlaces) {
    foreach ($f in @(Get-ChildItem -LiteralPath "$place\claude-code-sessions" -Recurse -File -Force -Filter 'local_*.json' -ErrorAction SilentlyContinue)) {
        $card = Read-JsonFile $f.FullName
        if (-not $card -or -not $card.cwd) { continue }
        $when = try { [DateTimeOffset]::FromUnixTimeMilliseconds([long]$card.lastActivityAt).LocalDateTime } catch { $f.LastWriteTime }
        Add-WorkspaceHit $card.cwd 'card' $when
    }
}
$claudeJsonData = @($ClaudeJsonMain | ForEach-Object { Read-JsonFile $_ } | Where-Object { $_ })
foreach ($j in $claudeJsonData) {
    if ($j.projects) { foreach ($pr in $j.projects.PSObject.Properties) { Add-WorkspaceHit $pr.Name 'project' ([datetime]::MinValue) } }
}

$coreRoots = @(@($ClaudeHome) + $DesktopPlaces + @($DesktopLogs, $ServiceLogs) | Where-Object { $_ })
$notWorkspaces = $coreRoots + @($env:TEMP, "$env:LOCALAPPDATA\Temp", $env:SystemRoot, $env:ProgramFiles, ${env:ProgramFiles(x86)}) | Where-Object { $_ }
$ignored = 0; $missing = 0
$found = foreach ($w in $wsMap.Values) {
    if (Test-UnderAny $w.Path $notWorkspaces) { $ignored++; continue }
    if (-not (Test-Path -LiteralPath $w.Path -PathType Container)) { $missing++; continue }
    $w | Add-Member -NotePropertyName Broad -NotePropertyValue (Test-BroadPath $w.Path) -PassThru
}
# A folder inside another workspace is part of it (very broad folders don't swallow their subfolders).
$workspaces = New-Object 'System.Collections.Generic.List[object]'
foreach ($w in @($found | Sort-Object { $_.Path.Length })) {
    $parent = $workspaces | Where-Object { -not $_.Broad -and (Test-UnderPath $w.Path $_.Path) } | Select-Object -First 1
    if ($parent) {
        $parent.Chats += $w.Chats; $parent.Cards += $w.Cards
        if ($w.Last -gt $parent.Last) { $parent.Last = $w.Last }
        continue
    }
    $workspaces.Add($w)
}

# Local MCP servers: paths in the "command", "args" and "env" of every MCP server Claude is set up with.
$mcpDefs = New-Object 'System.Collections.Generic.List[object]'
function Add-McpDefs($Servers) { if ($Servers) { foreach ($p in $Servers.PSObject.Properties) { $mcpDefs.Add([pscustomobject]@{ Name = $p.Name; Def = $p.Value }) } } }
foreach ($place in $DesktopPlaces) { $j = Read-JsonFile "$place\claude_desktop_config.json"; if ($j) { Add-McpDefs $j.mcpServers } }
foreach ($j in $claudeJsonData) {
    Add-McpDefs $j.mcpServers
    if ($j.projects) { foreach ($pr in $j.projects.PSObject.Properties) { Add-McpDefs $pr.Value.mcpServers } }
}
$notMcp = $notWorkspaces + @("$env:APPDATA\npm") | Where-Object { $_ }
$mcpRoots = @{}
foreach ($d in $mcpDefs) {
    $values = @($d.Def.command) + @($d.Def.args)
    if ($d.Def.env) { $values += @($d.Def.env.PSObject.Properties | ForEach-Object { $_.Value }) }
    foreach ($v in $values) {
        if ($v -isnot [string]) { continue }
        $p = Get-NormalPath $v
        if (-not $p -or (Test-BroadPath $p) -or (Test-UnderAny $p $notMcp)) { continue }
        $root = if (Test-Path -LiteralPath $p -PathType Container) { $p } elseif (Test-Path -LiteralPath $p -PathType Leaf) { Find-ProjectRoot $p } else { $null }
        if (-not $root) { continue }
        $k = $root.ToLower()
        if (-not $mcpRoots.ContainsKey($k)) { $mcpRoots[$k] = [pscustomobject]@{ Path = $root; Names = New-Object 'System.Collections.Generic.List[string]' } }
        if (-not $mcpRoots[$k].Names.Contains($d.Name)) { $mcpRoots[$k].Names.Add($d.Name) }
    }
}
# Servers kept side by side (e.g. ...\mcp-servers\a and ...\mcp-servers\b) are backed up as their shared folder,
# which also catches files they share, such as a key file next to them.
foreach ($g in @($mcpRoots.Values | Where-Object { Test-Path -LiteralPath $_.Path -PathType Container } | Group-Object { (Split-Path $_.Path -Parent).ToLower() })) {
    if ($g.Count -lt 2) { continue }
    $parent = Split-Path $g.Group[0].Path -Parent
    if ((Test-BroadPath $parent) -or (Test-UnderAny $parent $notMcp)) { continue }
    $merged = [pscustomobject]@{ Path = $parent; Names = New-Object 'System.Collections.Generic.List[string]' }
    foreach ($m in $g.Group) { foreach ($n in $m.Names) { if (-not $merged.Names.Contains($n)) { $merged.Names.Add($n) } }; $mcpRoots.Remove($m.Path.ToLower()) }
    $mcpRoots[$parent.ToLower()] = $merged
}
$mcpFolders = @($mcpRoots.Values | Where-Object { $r = $_; -not ($mcpRoots.Values | Where-Object { $_ -ne $r -and (Test-UnderPath $r.Path $_.Path) }) } | Sort-Object Path)

# The list to choose from
$choices = New-Object 'System.Collections.Generic.List[object]'
foreach ($w in @($workspaces | Sort-Object Last -Descending)) {
    $n = [math]::Max($w.Chats, $w.Cards)
    $choices.Add([pscustomobject]@{ Kind = 'Workspace'; Path = $w.Path; Info = $(if ($n) { "$n chats" } else { 'project' }); Last = $w.Last; Broad = $w.Broad; Selected = -not $w.Broad; Size = $null })
}
foreach ($m in $mcpFolders) {
    $choices.Add([pscustomobject]@{ Kind = 'MCP servers'; Path = $m.Path; Info = ($m.Names -join ', '); Last = [datetime]::MinValue; Broad = $false; Selected = $true; Size = $null })
}

if ($choices.Count) {
    Write-Host 'Measuring folder sizes...'
    foreach ($c in $choices) { $c.Size = Measure-Folder $c.Path @('__pycache__') }
}

function Show-Choices {
    Write-Title 'Workspaces and folders you can include:'
    if (-not $choices.Count) { Write-Host '  (none found)'; return }
    $w = [math]::Min(60, [math]::Max(6, ($choices | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum))
    Write-Host ("   #  Pick  {0,-11} {1,-$w} {2,-24} {3,-10} {4,12}" -f 'Type', 'Folder', 'Found from', 'Last used', 'Size')
    for ($i = 0; $i -lt $choices.Count; $i++) {
        $c = $choices[$i]
        $path = if ($c.Path.Length -gt $w) { '...' + $c.Path.Substring($c.Path.Length - $w + 3) } else { $c.Path }
        $info = if ($c.Info.Length -gt 24) { $c.Info.Substring(0, 21) + '...' } else { $c.Info }
        $last = if ($c.Last -gt [datetime]::MinValue) { $c.Last.ToString('yyyy-MM-dd') } else { '' }
        $line = "  {0,2}  [{1}]   {2,-11} {3,-$w} {4,-24} {5,-10} {6,12}" -f ($i + 1), $(if ($c.Selected) { 'x' } else { ' ' }), $c.Kind, $path, $info, $last, (Format-Measured $c.Size)
        if ($c.Broad) { $line += '  (very broad)' }
        Write-Host $line -ForegroundColor $(if ($c.Selected) { 'White' } else { 'DarkGray' })
    }
    $notes = @()
    if ($missing) { $notes += "$missing folder(s) from older chats no longer exist" }
    if ($ignored) { $notes += "$ignored temporary or Claude-internal folder(s) ignored" }
    if ($notes) { Write-Host ('  ' + ($notes -join '; ') + '.') -ForegroundColor DarkGray }
}

function Add-Choice([string]$Raw) {
    $p = Get-NormalPath $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Raw.Trim().Trim('"'))
    if (-not $p -or -not (Test-Path -LiteralPath $p)) { Write-Host "  Not found: $Raw" -ForegroundColor Yellow; return $null }
    $existing = $choices | Where-Object { $_.Path -eq $p } | Select-Object -First 1
    if ($existing) { $existing.Selected = $true; return $existing }
    $c = [pscustomobject]@{ Kind = 'Workspace'; Path = $p; Info = 'added by you'; Last = [datetime]::MinValue; Broad = (Test-BroadPath $p); Selected = $true; Size = (Measure-Folder $p @('__pycache__')) }
    $choices.Add($c)
    $c
}

# ---- 3. Choose ----------------------------------------------------------------------------------------------
if ($ListOnly) { Show-Choices; return }

if ($Workspace) {
    foreach ($c in $choices) { if ($c.Kind -eq 'Workspace') { $c.Selected = $false } }
    foreach ($raw in $Workspace) { if (-not (Add-Choice $raw)) { throw "Workspace not found: $raw" } }
}
elseif ($AllWorkspaces) { foreach ($c in $choices) { if ($c.Kind -eq 'Workspace') { $c.Selected = -not $c.Broad } } }
elseif ($NoWorkspaces) { foreach ($c in $choices) { if ($c.Kind -eq 'Workspace') { $c.Selected = $false } } }

if ($interactive) {
    if (-not ($choices | Where-Object { $_.Kind -eq 'Workspace' })) {
        Write-Host ''
        Write-Host 'No workspaces were found automatically.' -ForegroundColor Yellow
        Write-Host 'Type the folders you work in with Claude, one at a time, so they are backed up too.'
        while ($true) {
            $answer = Read-Answer 'Folder to include (Enter when done)'
            if (-not $answer) { break }
            [void](Add-Choice $answer)
        }
    }
    while ($true) {
        Show-Choices
        Write-Host ''
        Write-Host '  Numbers switch items on/off (e.g. 2   1,3   2-4).  A = all   N = none   + = add a folder' -ForegroundColor Gray
        $answer = Read-Answer '  Press Enter to continue with the ticked items, or Q to quit'
        if (-not $answer) { break }
        switch -Regex ($answer) {
            '^[Qq]$' { Write-Host 'Nothing was backed up.'; return }
            '^[Aa]$' { foreach ($c in $choices) { $c.Selected = -not $c.Broad }; continue }
            '^[Nn]$' { foreach ($c in $choices) { $c.Selected = $false }; continue }
            '^\+' {
                $rest = $answer.Substring(1).Trim()
                if (-not $rest) { $rest = Read-Answer '  Folder to add' }
                if ($rest) { [void](Add-Choice $rest) }
                continue
            }
            default {
                $bad = $false
                foreach ($part in ($answer -split '[,\s]+' | Where-Object { $_ })) {
                    $range = if ($part -match '^(\d+)-(\d+)$') { [int]$Matches[1]..[int]$Matches[2] } elseif ($part -match '^\d+$') { @([int]$part) } else { $bad = $true; @() }
                    foreach ($n in $range) { if ($n -ge 1 -and $n -le $choices.Count) { $choices[$n - 1].Selected = -not $choices[$n - 1].Selected } else { $bad = $true } }
                }
                if ($bad) { Write-Host "  Didn't understand all of '$answer'." -ForegroundColor Yellow }
            }
        }
    }
}

# What will be backed up. Folders inside another chosen folder (or inside Claude's own data) are covered by it.
$picked = @($choices | Where-Object { $_.Selected } | Sort-Object { $_.Path.Length })
$selected = New-Object 'System.Collections.Generic.List[object]'
foreach ($c in $picked) {
    if (Test-UnderAny $c.Path $coreRoots) { continue }
    if ($selected | Where-Object { Test-UnderPath $c.Path $_.Path }) { continue }
    $selected.Add($c)
}

# ---- 4. Plan --------------------------------------------------------------------------------------------------
$Sources = New-Object 'System.Collections.Generic.List[object]'
function Add-Source([string]$Path, [string]$Kind, [string]$Label, $Skip) {
    $Sources.Add([pscustomobject]@{ Path = $Path; Kind = $Kind; Label = $Label; Skip = $Skip })
}
if ($ClaudeHome) { Add-Source $ClaudeHome 'ClaudeCode' 'Claude Code' $ClaudeHomeSkips }
foreach ($f in @(Get-Item -Path "$UserHome\.claude.json*" -Force -ErrorAction SilentlyContinue | Where-Object { -not $_.PSIsContainer })) {
    Add-Source $f.FullName 'ClaudeCodeState' $(if ($f.Name -eq '.claude.json') { 'Claude Code settings' } else { 'Claude Code settings (old copy)' }) $null
}
foreach ($f in $ClaudeJsonMain) { if (-not ($Sources | Where-Object { $_.Path -eq $f }) -and -not ($ClaudeHome -and (Test-UnderPath $f $ClaudeHome))) { Add-Source $f 'ClaudeCodeState' 'Claude Code settings' $null } }
if ($DesktopData) { Add-Source $DesktopData 'ClaudeDesktop' 'Claude Desktop' $DesktopSkips }
foreach ($p in $DesktopPlaces | Where-Object { $_ -ne $DesktopData }) { Add-Source $p 'ClaudeDesktopOld' 'Claude Desktop (old location)' $DesktopSkips }
if (Test-Path -LiteralPath $DesktopLogs -PathType Container) { Add-Source $DesktopLogs 'ClaudeDesktopLogs' 'Claude Desktop logs' $null }
if (Test-Path -LiteralPath $ServiceLogs -PathType Container) { Add-Source $ServiceLogs 'ClaudeService' 'Claude service log' $null }
foreach ($c in $selected) { Add-Source $c.Path $(if ($c.Kind -eq 'MCP servers') { 'McpServer' } else { 'Workspace' }) $(if ($c.Kind -eq 'MCP servers') { 'MCP servers' } else { 'Workspace' }) $null }

$OutputRoot = if ($OutputRoot) { $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputRoot) } else { Get-DownloadsFolder }
$started = Get-Date
$stamp = $started.ToString('yyyy-MM-dd_HHmmss')
$OutputDir = Join-Path $OutputRoot "Claude-Backup_$stamp"

$coreSize = [long]0; $corePartial = $false
foreach ($s in $Sources | Where-Object { $_.Kind -notin 'Workspace', 'McpServer' }) {
    $m = Measure-Folder $s.Path ($DesktopCacheNames + @('Network', '__pycache__')) 6
    $coreSize += $m.Bytes; if ($m.Partial) { $corePartial = $true }
}
$pickedSize = [long]0; foreach ($c in $selected) { $pickedSize += $c.Size.Bytes }

Write-Title 'Ready to back up:'
Write-Host ("  Claude's own data       about {0}" -f (Format-Size $coreSize))
foreach ($c in $selected) { Write-Host ("  {0,-11}             {1}  ({2})" -f $c.Kind, $c.Path, (Format-Measured $c.Size)) }
if (-not $selected.Count) { Write-Host '  (no workspaces or MCP server folders)' -ForegroundColor DarkGray }
Write-Host ("  Total                   about {0}{1}" -f (Format-Size ($coreSize + $pickedSize)), $(if ($corePartial -or ($selected | Where-Object { $_.Size.Partial })) { ' or more' }))
Write-Host "  Saved to                $OutputDir"
if ($ask) {
    $answer = Read-Answer 'Start the backup? [Y/n]'
    if ($answer -and $answer -notmatch '^[Yy]') { Write-Host 'Nothing was backed up.'; return }
}

# ---- 5. Collect -------------------------------------------------------------------------------------------------
$Skipped = New-Object 'System.Collections.Generic.List[string]'
$SkipStats = [ordered]@{}
$SecretFiles = New-Object 'System.Collections.Generic.HashSet[string]' -ArgumentList ([StringComparer]::OrdinalIgnoreCase)
[void][IO.Directory]::CreateDirectory($OutputDir)
$marker = Join-Path $OutputDir $MarkerName
[IO.File]::WriteAllText($marker, "Made by Claude backup $ToolVersion. Later backups skip this folder.")
(Get-Item -LiteralPath $marker -Force).Attributes = 'Hidden'
$StagingFile = Join-Path $OutputDir '.staging.tmp'
$allRoots = @($Sources | ForEach-Object { $_.Path })

Write-Host ''
Write-Host 'Scanning...'
$plan = foreach ($s in $Sources) {
    $isDir = Test-Path -LiteralPath $s.Path -PathType Container
    $rules = @(@($s.Skip) + $SkipEverywhere | Where-Object { $_ })
    $inside = @($allRoots | Where-Object { $_ -ne $s.Path -and (Test-UnderPath $_ $s.Path) })
    $items = if ($isDir) { @(Get-SourceItems $s.Path $rules $inside) } else { @(Get-Item -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue) }
    [pscustomobject]@{ Source = $s; Items = $items }
}
$totalItems = 0; foreach ($p in $plan) { $totalItems += $p.Items.Count }

# ---- 6. Write the zip ----------------------------------------------------------------------------------------
$zipName  = "claude-backup_$stamp.zip"
$zipPath  = Join-Path $OutputDir $zipName
$partial  = "$zipPath.partial"
$manifest = New-Object 'System.Collections.Generic.List[object]'
$summary  = New-Object 'System.Collections.Generic.List[object]'
$restoreScript = Join-Path $PSScriptRoot 'Restore-Claude.ps1'
$restoreBat = Join-Path $PSScriptRoot 'Restore-Claude.bat'
$metaEntries = 0
$done = 0

$zip = New-Object IO.Compression.ZipArchive -ArgumentList ([IO.File]::Open($partial, 'Create', 'ReadWrite', 'None')), ([IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($p in $plan) {
        $src = $p.Source
        Write-Host ('Adding {0,-30} {1}  ({2:N0} items)' -f $src.Label, $src.Path, $p.Items.Count)
        $files = 0; $bytes = 0
        foreach ($item in $p.Items) {
            $done++
            if ($done % 250 -eq 0) {
                Write-Progress -Activity 'Backing up Claude files' -Status $src.Path -PercentComplete ([int]($done * 100 / [math]::Max(1, $totalItems)))
            }
            $plain = Get-PlainPath $item.FullName
            $entryName = ConvertTo-ZipPath $plain

            if ($item -is [IO.DirectoryInfo]) {
                [void]$zip.CreateEntry("$entryName/")
                $manifest.Add([pscustomobject]@{ Source = $src.Path; Type = 'Dir'; ZipPath = "$entryName/"; OriginalPath = $plain; Bytes = 0; LastWriteUtc = '' })
                continue
            }

            try { $data = Read-SourceFile "\\?\$plain" }
            catch { $Skipped.Add("$plain  ($($_.Exception.GetBaseException().Message))"); continue }
            try {
                $level = if ($Compress -and $StoreOnly -notcontains $item.Extension) { 'Optimal' } else { 'NoCompression' }
                $entry = $zip.CreateEntry($entryName, [IO.Compression.CompressionLevel]$level)
                try { $entry.LastWriteTime = [DateTimeOffset]$item.LastWriteTime } catch { }   # zip dates must be 1980-2107
                $out = $entry.Open()
                try { $data.CopyTo($out) } finally { $out.Dispose() }
                $len = $data.Length
            }
            finally { $data.Dispose() }

            $files++; $bytes += $len
            $manifest.Add([pscustomobject]@{ Source = $src.Path; Type = 'File'; ZipPath = $entryName; OriginalPath = $plain; Bytes = $len; LastWriteUtc = $item.LastWriteTimeUtc.ToString('o') })
        }
        $summary.Add([pscustomobject]@{ Path = $src.Path; Kind = $src.Kind; Label = $src.Label; Files = $files; Bytes = $bytes; Found = $true })
    }
    Write-Progress -Activity 'Backing up Claude files' -Completed

    # ---- Instructions -------------------------------------------------------------------------------------
    $totalFiles = [int](($summary | Measure-Object Files -Sum).Sum)
    $totalBytes = [long](($summary | Measure-Object Bytes -Sum).Sum)
    $nodeVersion = try { (& node --version) -join '' } catch { $null }
    $workspaceList = @($summary | Where-Object { $_.Kind -eq 'Workspace' } | ForEach-Object { $_.Path })

    $w = [math]::Max(20, ($summary | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum)
    $rowFormat = "{0,-30} {1,-$w} {2,7} {3,10}"
    $locationRows = foreach ($s in $summary) { '  ' + ($rowFormat -f $s.Label, $s.Path, ('{0:N0}' -f $s.Files), (Format-Size $s.Bytes)) }

    $sessionsText = if ($DesktopData -and $ClaudeHome) {
        @"

HOW CLAUDE DESKTOP SESSIONS COME BACK
  Each Code-tab session has two parts, and both are in this backup:
    - a session card in Claude Desktop's data folder (title, working folder, settings)
    - the conversation itself, in $ClaudeHome\projects
  After a restore, sessions are listed again when you sign in with the same Claude account and their
  working folders are back at the same paths$(if ($workspaceList) { ':' + (($workspaceList | ForEach-Object { "`r`n    $_" }) -join '') } else { '.' })
"@
    }

    $skipRows = foreach ($g in ($SkipStats.Values | Group-Object Source)) {
        "  $($g.Name)"
        foreach ($st in $g.Group) { '      {0,-26} {1,7:N0} files {2,10}   {3}' -f $st.What, $st.Files, (Format-Size $st.Bytes), $st.Why }
    }
    if (-not $skipRows) { $skipRows = '  (nothing)' }

    # What in the zip is sensitive - named, never read into this text.
    $secretRows = New-Object 'System.Collections.Generic.List[string]'
    foreach ($place in $DesktopPlaces) {
        $cfg = Read-JsonFile "$place\claude_desktop_config.json"
        if ($cfg -and $cfg.mcpServers) {
            $n = @($cfg.mcpServers.PSObject.Properties | Where-Object { $_.Value.env -and ($_.Value.env.PSObject.Properties.Name -match 'PASS|KEY|TOKEN|SECRET|AUTH') }).Count
            if ($n) { $secretRows.Add("$place\claude_desktop_config.json - logins/keys for $n MCP server(s), in plain text") }
        }
    }
    foreach ($f in $ClaudeJsonMain) { $secretRows.Add("$f - your Claude account details, and MCP server settings") }
    foreach ($f in @($SecretFiles | Sort-Object | Select-Object -First 15)) { $secretRows.Add("$f - looks like a key or password file") }
    if ($SecretFiles.Count -gt 15) { $secretRows.Add("... and $($SecretFiles.Count - 15) more files like that") }
    $secretText = ($secretRows | ForEach-Object { "      $_" }) -join "`r`n"

    $skippedText = if ($Skipped.Count) {
        (($Skipped | ForEach-Object { "  $_" }) -join "`r`n") + "`r`n  Quit Claude (also from the system tray) and run the backup again to include these."
    } else { '  (none)' }
    $storedAs = if ($Compress) { 'compressed' } else { 'stored uncompressed' }
    $nodeText = if ($nodeVersion) { "Node.js (this backup was made with $nodeVersion)" } else { 'Node.js, if you use local MCP servers' }

    $readme = @"
CLAUDE BACKUP
Created  : $($started.ToString('yyyy-MM-dd HH:mm')) on $env:COMPUTERNAME
User     : $UserHome
Contents : $('{0:N0}' -f $totalFiles) files, $(Format-Size $totalBytes) ($storedAs)
Made with: Claude backup $ToolVersion

FILES IN THIS FOLDER
  $zipName      the backup
  Restore-Claude.bat     double-click to restore: shows a preview first, then asks before writing anything
  Restore-Claude.ps1     the restore program (the .bat runs it)
  README.txt             this file
  If you only have the zip: README and Restore-Claude.ps1 are also inside it (RESTORE-LOCATIONS.txt, _restore\).

WHERE EVERYTHING GOES BACK
  $($rowFormat -f 'What', 'Original location', 'Files', 'Size')
$($locationRows -join "`r`n")

  Inside the zip every file sits under its original path, with the drive letter as the top folder:
  C:\Work\notes.md is stored as C\Work\notes.md. Every file is listed in _restore\manifest.csv in the zip.
$sessionsText
HOW TO RESTORE
  1. On a new PC, first install Claude Desktop (https://claude.ai/download) if you use it, and $nodeText.
     Open Claude Desktop once, then quit it - also from the system tray. Close any 'claude' terminal windows.
  2. Keep the zip, Restore-Claude.bat and Restore-Claude.ps1 together in one folder.
  3. Double-click Restore-Claude.bat. It shows what would be new, replaced or left alone, then asks you to
     type YES before it writes anything.
     Or from PowerShell, in this folder:
       powershell -ExecutionPolicy Bypass -File .\Restore-Claude.ps1 -ZipPath ".\$zipName"
       powershell -ExecutionPolicy Bypass -File .\Restore-Claude.ps1 -ZipPath ".\$zipName" -Apply
     Restore just one location by adding  -Only "<original location from the table above>"
  4. Open Claude Desktop and sign in if it asks, with the same Claude account.

WHAT THE RESTORE TAKES CARE OF
  - It never deletes anything. Files identical to the backup are left alone, and any file it replaces is
    first copied to a pre-restore_<date> folder next to the zip (INDEX.csv there lists where each came from).
  - It stops if Claude is running, because Claude would overwrite the restored files.
  - Different Windows user name: files from $UserHome go into the new user's folder, and paths inside
    Claude's config files (e.g. MCP server paths) are updated to match.
  - Claude Desktop data goes wherever Claude Desktop on that PC keeps it (the Store app moved it from its
    package folder to %LOCALAPPDATA%\Claude-Data in version 3), so a backup restores across app versions.
  - Sign-in: Claude Desktop's saved sign-in only works on the Windows account that created it. On the same
    PC and account it keeps working; anywhere else the restore removes it (keeping a sign-in already on that
    PC), so Claude simply asks you to sign in. If 'claude' in a terminal asks you to log in, log in.
  - Held back with a message and the command to finish later:
      Claude Desktop data, if Claude Desktop is not installed or has never been opened
      $env:ProgramData\Claude, unless PowerShell runs as Administrator
      anything on a drive this PC does not have
  - Warns if Node.js is missing and the backup has local MCP servers.

LEFT OUT ON PURPOSE (rebuilt automatically, or would not work on another PC)
$($skipRows -join "`r`n")

  Also not part of this backup:
      Claude Desktop and Claude Code programs   reinstall them (Store apps can't be copied back)
      npm / npx download cache                  MCP servers started with npx download again on first start
      Windows' own data for the Store app       tied to this Windows account; Windows recreates it

GOOD TO KNOW
  - This backup is NOT encrypted and contains secrets:
$secretText
    Keep it private. To add a password, put the zip inside a 7-Zip archive with AES-256 encryption.
  - Workspaces are restored to the same paths they came from; sessions depend on that.
  - Files are $storedAs. For a smaller zip run the backup with -Compress.
  - Some Claude Desktop files have paths longer than Windows' usual 260-character limit. The restore
    handles them; if you extract by hand, use 7-Zip (Windows' built-in extractor may skip them).

SKIPPED - COULD NOT BE READ
$skippedText
"@

    $info = [ordered]@{
        Tool                     = "Claude backup $ToolVersion"
        Created                  = $started.ToString('o')
        Computer                 = $env:COMPUTERNAME
        UserProfile              = $UserHome
        ClaudeHome               = $ClaudeHome
        Files                    = $totalFiles
        Bytes                    = $totalBytes
        DesktopPackageFamilyName = $(if ($DesktopData -and $DesktopData -ne $classic) { $DesktopPfn })
        DesktopDataPath          = $DesktopData
        DesktopKind              = $DesktopKind
        DesktopKeyHash           = $(if ($DesktopData) { Get-DesktopKeyHash (Join-Path $DesktopData 'Local State') })
        NodeVersion              = $nodeVersion
        Workspaces               = [string[]]$workspaceList
        Sources                  = $summary.ToArray()   # @($list) makes ConvertTo-Json throw on PS 5.1
        LeftOut                  = @($SkipStats.Values)
        Skipped                  = $Skipped.ToArray()
    }
    Add-TextEntry $zip 'RESTORE-LOCATIONS.txt' $readme; $metaEntries++
    Add-TextEntry $zip '_restore/backup-info.json' ($info | ConvertTo-Json -Depth 4); $metaEntries++
    Add-TextEntry $zip '_restore/manifest.csv' (($manifest | ConvertTo-Csv -NoTypeInformation) -join "`r`n"); $metaEntries++
    foreach ($f in $restoreScript, $restoreBat) {
        if (Test-Path -LiteralPath $f) { Add-FileEntry $zip "_restore/$(Split-Path $f -Leaf)" $f; $metaEntries++ }
    }
}
finally {
    $zip.Dispose()
}

# ---- 7. Verify and finish -------------------------------------------------------------------------------------
$check = [IO.Compression.ZipFile]::OpenRead($partial)
try { $entryCount = $check.Entries.Count } finally { $check.Dispose() }
$expected = $manifest.Count + $metaEntries
if ($entryCount -ne $expected) { throw "Zip check failed: expected $expected entries, found $entryCount. Incomplete file left at $partial" }
Move-Item -LiteralPath $partial -Destination $zipPath

[IO.File]::WriteAllText((Join-Path $OutputDir 'README.txt'), $readme, (New-Object Text.UTF8Encoding $true))
foreach ($f in $restoreScript, $restoreBat) {
    if (Test-Path -LiteralPath $f) { Copy-Item -LiteralPath $f -Destination $OutputDir }
    else { Write-Host "Warning: $f is missing - copy it next to the zip before restoring." -ForegroundColor Yellow }
}

$elapsed = (Get-Date) - $started
$leftOutFiles = [int](($SkipStats.Values | Measure-Object Files -Sum).Sum)
$leftOutBytes = [long](($SkipStats.Values | Measure-Object Bytes -Sum).Sum)
Write-Host ''
Write-Host ('Done in {0:%m}m {0:%s}s' -f $elapsed) -ForegroundColor Green
Write-Host "  Folder  : $OutputDir"
Write-Host "  Zip     : $zipName  ($(Format-Size (Get-Item -LiteralPath $zipPath).Length))"
Write-Host ('  Files   : {0:N0}  ({1})' -f $totalFiles, (Format-Size $totalBytes))
Write-Host ('  Left out: {0:N0} cache / this-PC-only files ({1}) - listed in README.txt' -f $leftOutFiles, (Format-Size $leftOutBytes))
Write-Host "  Skipped : $($Skipped.Count) could not be read"
foreach ($s in $Skipped) { Write-Host "    $s" -ForegroundColor Yellow }
Write-Host '  The backup holds passwords and keys in plain text - keep it private.' -ForegroundColor Yellow
if ($OpenFolder) { Invoke-Item -LiteralPath $OutputDir }
