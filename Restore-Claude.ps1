<#
.SYNOPSIS
    Restores a backup made by Backup-Claude.ps1 to the original locations.

.DESCRIPTION
    Without -Apply nothing is written: for each backed-up location it shows which files would be new,
    replaced, or left alone because they are already identical, plus anything it can't restore yet and why.
    Restore-Claude.bat runs this preview, then asks before restoring.

    With -Apply it restores, and takes care of what otherwise goes wrong after a restore:
      - never deletes anything; identical files are left untouched; every file it replaces is first copied
        to a pre-restore_<date> folder next to the zip (turn off with -NoSafetyCopy)
      - different Windows user name: files go into the current user's folder and paths inside Claude's
        config files are updated
      - Claude Desktop data goes wherever Claude Desktop on this PC keeps it (Store app version 2 or 3,
        or a classic install), so a backup restores across app versions
      - Claude Desktop sign-in: the saved tokens only work on the Windows account that made them; elsewhere
        they are removed (a sign-in already on this PC is kept) so Claude just asks you to sign in
      - held back, with the command to finish later: Claude Desktop data while Claude Desktop is not
        installed or never opened, %ProgramData% without Administrator, drives this PC doesn't have
      - refuses to run while Claude is open (it would overwrite the restored files)

.PARAMETER ZipPath
    The backup zip.
.PARAMETER Only
    Restore only these locations, as listed in README.txt (e.g. 'C:\Work\my-app').
.PARAMETER Apply
    Actually restore. Without it this is a preview.
.PARAMETER Force
    Restore even while Claude is running.
.PARAMETER NoSafetyCopy
    Don't keep copies of the files that get replaced.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Restore-Claude.ps1 -ZipPath .\claude-backup_2026-10-22_124053.zip
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\Restore-Claude.ps1 -ZipPath .\claude-backup_2026-10-22_124053.zip -Apply

.NOTES
    Claude Backup for Windows, by Harshit Kushwaha (https://www.linkedin.com/in/hrshtk/). MIT license.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ZipPath,
    [string[]]$Only,
    [switch]$Apply,
    [switch]$Force,
    [switch]$NoSafetyCopy
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

# Electron safeStorage values (sign-in tokens etc.): base64 of "v10..."/"v11...", encrypted for one Windows account.
$EncryptedPair = '"(?<key>[^"\\]+)"\s*:\s*"(?<value>djE[wx][A-Za-z0-9+/=]*)"'

function Read-ZipText($Zip, [string]$Name) {
    $entry = $Zip.GetEntry($Name)
    if (-not $entry) { throw "'$Name' is missing - this zip was not made by Backup-Claude.ps1." }
    $reader = New-Object IO.StreamReader -ArgumentList $entry.Open()
    try { $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function Test-UnderPath([string]$Path, [string]$Parent) {
    $Path.Equals($Parent, [StringComparison]::OrdinalIgnoreCase) -or
    $Path.StartsWith($Parent.TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)
}

# File operations go through "\\?\C:\..." paths, which lift Windows' 260-character limit
# (some Claude Desktop plugin files are deeper than that). Everything shown uses the normal path.
function Get-LongPath([string]$Path) { if ($Path.StartsWith('\\?\')) { $Path } else { '\\?\' + $Path } }
function Get-ParentPath([string]$Path) { $Path.Substring(0, $Path.LastIndexOf('\')) }

# Same as in Backup-Claude.ps1: hash of the encrypted key in Claude Desktop's "Local State".
function Get-DesktopKeyHash([string]$LocalStatePath) {
    if (-not [IO.File]::Exists((Get-LongPath $LocalStatePath))) { return $null }
    try {
        $key = ([IO.File]::ReadAllText((Get-LongPath $LocalStatePath)) | ConvertFrom-Json).os_crypt.encrypted_key
        if (-not $key) { return $null }
        $sha = [Security.Cryptography.SHA256]::Create()
        [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($key))).Replace('-', '')
    } catch { $null }
}

function Write-TextFile([string]$Path, [string]$Text) {
    [IO.File]::WriteAllText((Get-LongPath $Path), $Text, (New-Object Text.UTF8Encoding $false))
}

function Test-ValidJson([string]$Text) {
    try { $null = $Text | ConvertFrom-Json; $true } catch { $false }
}

# Encrypted values (name -> value) in a JSON file's text.
function Get-EncryptedValues([string]$Path) {
    $found = @{}
    if ([IO.File]::Exists((Get-LongPath $Path))) {
        foreach ($m in [regex]::Matches([IO.File]::ReadAllText((Get-LongPath $Path)), $EncryptedPair)) { $found[$m.Groups['key'].Value] = $m.Groups['value'].Value }
    }
    $found
}

# Replace the backup's encrypted values (unusable on this Windows account) with the ones that were already on
# this PC, or remove them so Claude asks for a fresh sign-in. Text edits keep the rest of the file untouched.
function Repair-SignIn([string]$ConfigPath, [hashtable]$Keep) {
    $original = [IO.File]::ReadAllText((Get-LongPath $ConfigPath))
    $text = $original
    $found = [regex]::Matches($original, $EncryptedPair)
    # Right to left, so the positions of the matches still to do don't move.
    for ($i = $found.Count - 1; $i -ge 0; $i--) {
        $m = $found[$i]; $key = $m.Groups['key'].Value
        if ($Keep.ContainsKey($key)) {
            $v = $m.Groups['value']
            $text = $text.Remove($v.Index, $v.Length).Insert($v.Index, $Keep[$key])
            continue
        }
        # Remove the pair with the comma after it, or - if it is the last member - the comma before it.
        $start = $m.Index; $end = $m.Index + $m.Length
        $after = $end; while ($after -lt $text.Length -and [char]::IsWhiteSpace($text[$after])) { $after++ }
        if ($after -lt $text.Length -and $text[$after] -eq ',') { $end = $after + 1 }
        else {
            $before = $start - 1; while ($before -ge 0 -and [char]::IsWhiteSpace($text[$before])) { $before-- }
            if ($before -ge 0 -and $text[$before] -eq ',') { $start = $before }
        }
        $text = $text.Remove($start, $end - $start)
    }
    foreach ($key in $Keep.Keys) {
        if ($text -notmatch ('"' + [regex]::Escape($key) + '"\s*:')) {
            $i = $text.IndexOf('{')
            $comma = if ($text.Substring($i + 1).TrimStart().StartsWith('}')) { '' } else { ',' }
            $text = $text.Insert($i + 1, '"' + $key + '":"' + $Keep[$key] + '"' + $comma)
        }
    }
    if ($text -ceq $original) { return 'unchanged' }
    if (-not (Test-ValidJson $text)) { return 'failed' }
    Write-TextFile $ConfigPath $text
    'fixed'
}

# Claude's own config files - their user-folder paths are updated when the Windows user name changes.
# Files in workspaces are left exactly as they were, except Claude's project settings (.claude\, .mcp.json).
function Test-ConfigJson([string]$Path) {
    if ($Path -notlike '*.json' -or $Path -like '*\node_modules\*') { return $false }
    if ($Path -like '*\.claude\*' -or $Path -like '*\.mcp.json') { return $true }
    foreach ($r in $configRoots) { if (Test-UnderPath $Path $r) { return $true } }
    $false
}

$zipFull = (Resolve-Path -LiteralPath $ZipPath).ProviderPath
$zip = [IO.Compression.ZipFile]::OpenRead($zipFull)
try {
    $info = Read-ZipText $zip '_restore/backup-info.json' | ConvertFrom-Json
    $rows = @((Read-ZipText $zip '_restore/manifest.csv') -split "`r?`n" | Where-Object { $_ } | ConvertFrom-Csv)

    # ---- Where things go on this PC -------------------------------------------------------------------
    $fromHome = $info.UserProfile.TrimEnd('\')
    $toHome = $env:USERPROFILE.TrimEnd('\')
    $remapHome = $fromHome -ne $toHome
    $desktopPkg = try { Get-AppxPackage -Name Claude -ErrorAction SilentlyContinue | Select-Object -First 1 } catch { $null }
    $fromPfn = $info.DesktopPackageFamilyName
    $toPfn = if ($desktopPkg) { $desktopPkg.PackageFamilyName } elseif ($fromPfn) { $fromPfn } else { 'Claude_pzs8sxrjxfjjc' }
    # Claude Desktop data goes where Claude Desktop on this PC reads it - whichever of these holds its
    # config.json. $null = not installed, or installed but never opened.
    $desktopData = $info.DesktopDataPath
    $desktopTarget = $null
    if ($desktopData) {
        $candidates = @()
        if ($toPfn) { $candidates += "$env:LOCALAPPDATA\Claude-Data\$($toPfn.ToLower())", "$env:LOCALAPPDATA\Packages\$toPfn\LocalCache\Roaming\Claude" }
        $candidates += "$env:APPDATA\Claude"
        $desktopTarget = $candidates | Where-Object { [IO.File]::Exists((Get-LongPath "$_\config.json")) } | Select-Object -First 1
    }
    $desktopMissing = if ($desktopPkg -or [IO.Directory]::Exists("$env:APPDATA\Claude")) { 'Claude Desktop has not been opened on this PC yet' } else { 'Claude Desktop is not installed on this PC yet' }
    function Get-Target([string]$Original) {
        if ($desktopTarget -and (Test-UnderPath $Original $desktopData)) { return $desktopTarget + $Original.Substring($desktopData.Length) }
        $t = $Original
        if ($remapHome -and $t.StartsWith("$fromHome\", [StringComparison]::OrdinalIgnoreCase)) { $t = $toHome + $t.Substring($fromHome.Length) }
        if ($fromPfn -and $toPfn -and $toPfn -ne $fromPfn) { $t = $t -replace [regex]::Escape("\Packages\$fromPfn\"), "\Packages\$toPfn\" }
        $t
    }

    # What each backed-up location is (backups from older versions don't record it)
    $labels = @{}; $kinds = @{}
    foreach ($s in @($info.Sources)) { if ($s -and $s.Path) { $labels[$s.Path] = $s.Label; $kinds[$s.Path] = $s.Kind } }
    $configRoots = @(foreach ($s in @($info.Sources)) { if ($s -and $s.Kind -in 'ClaudeCode', 'ClaudeCodeState', 'ClaudeDesktop', 'ClaudeDesktopOld', 'McpServer') { Get-Target $s.Path } })
    if (-not $configRoots) { $configRoots = @("$toHome\.claude", "$toHome\.claude.json", "$toHome\mcp-servers") + @($desktopTarget | Where-Object { $_ }) }

    if ($Only) {
        $wanted = $Only | ForEach-Object { $_.TrimEnd('\') }
        $rows = @($rows | Where-Object { $wanted -contains $_.Source -or $wanted -contains (Get-Target $_.Source) })
        if ($rows.Count -eq 0) {
            $available = ($info.Sources | Where-Object { $_.Found } | ForEach-Object { $_.Path }) -join "`n  "
            throw "Nothing in this backup matches -Only. Locations in this backup:`n  $available"
        }
    }

    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $drives = @{}
    function Test-DriveExists([string]$Path) {
        $d = $Path.Substring(0, 2).ToUpper()
        if (-not $drives.ContainsKey($d)) { $drives[$d] = [IO.Directory]::Exists("$d\") }
        $drives[$d]
    }

    # Can Claude Desktop's saved sign-in in config.json be unlocked here? Only with the same "Local State" key.
    $cfgTarget = $null; $keyOk = $true
    if ($desktopTarget -and ($rows | Where-Object { $_.OriginalPath -eq "$desktopData\config.json" })) {
        $cfgTarget = Get-Target "$desktopData\config.json"
        $keyOk = [bool]$info.DesktopKeyHash -and (Get-DesktopKeyHash (Join-Path $desktopTarget 'Local State')) -eq $info.DesktopKeyHash
    }

    # ---- Classify every file --------------------------------------------------------------------------
    $packagesDir = "$env:LOCALAPPDATA\Packages"
    $plan = foreach ($r in $rows) {
        $target = Get-Target $r.OriginalPath
        $blocked = if (-not (Test-DriveExists $target)) { "drive $($target.Substring(0, 2)) does not exist on this PC" }
                   elseif (-not $isAdmin -and (Test-UnderPath $r.OriginalPath $env:ProgramData)) { 'needs PowerShell opened as Administrator' }
                   elseif ($desktopData -and -not $desktopTarget -and (Test-UnderPath $r.OriginalPath $desktopData)) { $desktopMissing }
                   elseif (-not $desktopPkg -and (Test-UnderPath $target $packagesDir)) { 'Claude Desktop is not installed on this PC yet' }
        $state = if ($blocked) { 'Blocked' }
                 elseif ($r.Type -eq 'Dir') { 'Dir' }
                 elseif (-not [IO.File]::Exists((Get-LongPath $target))) { 'New' }
                 else {
                     $disk = New-Object IO.FileInfo -ArgumentList (Get-LongPath $target)
                     $backupTime = [datetime]::Parse($r.LastWriteUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
                     if ($disk.Length -eq [long]$r.Bytes -and [math]::Abs(($disk.LastWriteTimeUtc - $backupTime).TotalSeconds) -le 2) { 'Same' }
                     elseif ($disk.LastWriteTimeUtc -gt $backupTime) { 'Newer' }
                     else { 'Replace' }
                 }
        [pscustomobject]@{ Row = $r; Target = $target; State = $state; Blocked = $blocked }
    }

    # ---- Preview --------------------------------------------------------------------------------------
    Write-Host "Backup from $($info.Computer), $(([datetime]$info.Created).ToString('yyyy-MM-dd HH:mm'))$(if ($info.Tool) { " ($($info.Tool))" })"
    function Get-StateCount($Items, [string]$State) { @($Items | Where-Object { $_.State -eq $State }).Count }
    $report = $plan | Group-Object { $_.Row.Source } | ForEach-Object {
        $g = @($_.Group | Where-Object { $_.Row.Type -eq 'File' })
        [pscustomobject]@{
            What                   = $labels[$_.Name]
            'Restore to'           = Get-Target $_.Name
            New                    = Get-StateCount $g 'New'
            Replace                = Get-StateCount $g 'Replace'
            'Replace (disk newer)' = Get-StateCount $g 'Newer'
            'Same - left alone'    = Get-StateCount $g 'Same'
            "Can't yet"            = Get-StateCount $g 'Blocked'
        }
    }
    $report | Format-Table -AutoSize | Out-String -Width 300 | Write-Host

    $blockedGroups = @($plan | Where-Object { $_.State -eq 'Blocked' } | Group-Object { $_.Row.Source })
    foreach ($b in $blockedGroups) {
        Write-Host ("Held back: {0} - {1}." -f (Get-Target $b.Name), $b.Group[0].Blocked) -ForegroundColor Yellow
    }
    if ($remapHome) { Write-Host "Backup was made for $fromHome - those files go into $toHome, and paths in Claude's config files are updated." -ForegroundColor Yellow }
    if ($desktopTarget -and -not $desktopTarget.Equals($desktopData, [StringComparison]::OrdinalIgnoreCase)) {
        Write-Host "Claude Desktop data was backed up from $desktopData; it goes to $desktopTarget, where Claude Desktop on this PC keeps it." -ForegroundColor Yellow
    }
    if ($cfgTarget) {
        if ($keyOk) { Write-Host 'Claude Desktop sign-in: same Windows account as the backup - it keeps working.' }
        else { Write-Host 'Claude Desktop sign-in: the saved sign-in only works on the PC/account that made the backup, so it is not restored (a sign-in already on this PC is kept). Sign in when Claude asks.' -ForegroundColor Yellow }
    }
    $needsNode = $rows | Where-Object { $kinds[$_.Source] -eq 'McpServer' -or $_.OriginalPath -like '*\mcp-servers\*' } | Select-Object -First 1
    $hasNode = [bool](Get-Command node -ErrorAction SilentlyContinue)
    if ($needsNode -and -not $hasNode) {
        Write-Host ("Node.js is not installed - local MCP servers usually need it{0}. Install it from https://nodejs.org" -f $(if ($info.NodeVersion) { " (backup made with $($info.NodeVersion))" })) -ForegroundColor Yellow
    }

    if (-not $Apply) {
        Write-Host ''
        Write-Host 'Preview only - nothing was written. Run again with -Apply to restore.'
        Write-Host "'Replace' files are copied to a pre-restore folder first; nothing on disk is deleted."
        return
    }

    # ---- Restore --------------------------------------------------------------------------------------
    if (-not $Force -and (Get-Process -Name claude -ErrorAction SilentlyContinue)) {
        throw 'Claude is running. Quit Claude Desktop (also from the system tray) and close any claude terminals, then run again (or add -Force).'
    }
    $safetyDir = Join-Path (Split-Path $zipFull -Parent) ('pre-restore_{0}' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
    $keepTokens = if ($cfgTarget -and -not $keyOk) { Get-EncryptedValues $cfgTarget } else { @{} }

    $counts = @{ New = 0; Replaced = 0; Same = 0; Saved = 0 }
    $failed = New-Object 'System.Collections.Generic.List[string]'
    $writtenJson = New-Object 'System.Collections.Generic.List[string]'
    $safetyIndex = New-Object 'System.Collections.Generic.List[object]'
    $done = 0
    foreach ($p in $plan) {
        $done++
        if ($done % 250 -eq 0) {
            Write-Progress -Activity 'Restoring Claude files' -Status $p.Row.Source -PercentComplete ([int]($done * 100 / $plan.Count))
        }
        if ($p.State -eq 'Blocked') { continue }
        if ($p.State -eq 'Same') { $counts.Same++; continue }
        $step = 'restore'
        try {
            $long = Get-LongPath $p.Target
            if ($p.State -eq 'Dir') { [void][IO.Directory]::CreateDirectory($long); continue }
            [void][IO.Directory]::CreateDirectory((Get-ParentPath $long))
            if ($p.State -ne 'New') {
                if (-not $NoSafetyCopy) {
                    # Mirror the original path (C:\x -> <safetyDir>\C\x); very long ones get a short name so
                    # Explorer can open them.
                    $step = 'safety copy'
                    $copy = $safetyDir + '\' + $p.Target.Substring(0, 1) + $p.Target.Substring(2)
                    if ($copy.Length -ge 240) {
                        $copy = '{0}\long-paths\{1:D5}_{2}' -f $safetyDir, ($counts.Saved + 1), $p.Target.Substring($p.Target.LastIndexOf('\') + 1)
                    }
                    [void][IO.Directory]::CreateDirectory((Get-ParentPath (Get-LongPath $copy)))
                    [IO.File]::Copy($long, (Get-LongPath $copy), $true)
                    $counts.Saved++
                    $safetyIndex.Add([pscustomobject]@{ OriginalPath = $p.Target; SavedAs = $copy.Substring($safetyDir.Length + 1) })
                    $step = 'restore'
                }
                [IO.File]::SetAttributes($long, 'Normal')   # hidden/read-only files can't be overwritten
            }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.GetEntry($p.Row.ZipPath), $long, $true)
            if ($p.State -eq 'New') { $counts.New++ } else { $counts.Replaced++ }
            if (Test-ConfigJson $p.Target) { $writtenJson.Add($p.Target) }
        }
        catch {
            $why = $_.Exception.GetBaseException().Message
            if ($step -eq 'safety copy') { $why = "left unchanged - could not save a safety copy first: $why" }
            $failed.Add("$($p.Target)  ($why)")
        }
    }
    Write-Progress -Activity 'Restoring Claude files' -Completed
    if ($safetyIndex.Count) {
        $safetyIndex | Export-Csv -LiteralPath "$safetyDir\INDEX.csv" -NoTypeInformation -Encoding UTF8
    }

    # Paths inside config files follow the new user folder (JSON writes C:\Users\x as C:\\Users\\x or C:/Users/x).
    $pathsFixed = 0
    if ($remapHome) {
        $swaps = @(
            @(($fromHome.Replace('\', '\\')), ($toHome.Replace('\', '\\'))),
            @(($fromHome.Replace('\', '/')), ($toHome.Replace('\', '/')))
        )
        foreach ($f in $writtenJson) {
            try {
                $text = [IO.File]::ReadAllText((Get-LongPath $f)); $new = $text
                foreach ($s in $swaps) { $new = [regex]::Replace($new, [regex]::Escape($s[0]) + '(?=[\\/"])', $s[1].Replace('$', '$$'), 'IgnoreCase') }
                if ($new -cne $text) { Write-TextFile $f $new; $pathsFixed++ }
            }
            catch { $failed.Add("$f  (could not update paths: $($_.Exception.GetBaseException().Message))") }
        }
    }

    $signIn = $null
    if ($cfgTarget -and -not $keyOk -and ($writtenJson -contains $cfgTarget)) {
        $signIn = Repair-SignIn $cfgTarget $keepTokens
        if ($signIn -eq 'failed') { $failed.Add("$cfgTarget  (could not remove the old sign-in; if Claude Desktop misbehaves, sign out and in again)") }
    }

    # ---- Summary --------------------------------------------------------------------------------------
    Write-Host ''
    Write-Host ('Restored {0:N0} new and {1:N0} replaced files; {2:N0} were already identical and left alone.' -f $counts.New, $counts.Replaced, $counts.Same) -ForegroundColor Green
    if ($counts.Saved) { Write-Host "The $($counts.Saved) files that were replaced are saved in $safetyDir (INDEX.csv lists where each came from)" }
    if ($pathsFixed) { Write-Host "Updated user-folder paths in $pathsFixed config file(s)." }
    if ($signIn -eq 'fixed') { Write-Host 'Removed the old Claude Desktop sign-in (it only works on the original PC).' }

    foreach ($b in $blockedGroups) {
        $where = Get-Target $b.Name
        $why = $b.Group[0].Blocked
        Write-Host ''
        Write-Host ("Not restored yet: {0} ({1} files) - {2}." -f $where, @($b.Group | Where-Object { $_.Row.Type -eq 'File' }).Count, $why) -ForegroundColor Yellow
        $cmd = "powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`" -ZipPath `"$zipFull`" -Only `"$($b.Name)`" -Apply"
        if ($why -like 'drive *') { Write-Host "  Connect that drive and run:`n    $cmd`n  or copy the files out of the zip by hand (7-Zip), to wherever you want them." }
        elseif ($why -like '*Administrator*') { Write-Host "  Open PowerShell as Administrator and run:`n    $cmd" }
        else { Write-Host "  Install Claude Desktop from https://claude.ai/download, open it once, quit it, then run:`n    $cmd" }
    }
    if ($failed.Count) {
        Write-Host ''
        Write-Host "$($failed.Count) could not be written:" -ForegroundColor Yellow
        $failed | Select-Object -First 25 | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
        if ($failed.Count -gt 25) { Write-Host "  ... and $($failed.Count - 25) more" -ForegroundColor Yellow }
    }
    Write-Host ''
    Write-Host 'Next: open Claude Desktop and sign in if it asks, with the same Claude account as before.'
    if (@($info.Workspaces).Count) { Write-Host "Your sessions should be listed again for: $((@($info.Workspaces)) -join ', ')" }
    if ($needsNode -and -not $hasNode) { Write-Host 'Then install Node.js (https://nodejs.org) so local MCP servers can start.' }
}
finally {
    $zip.Dispose()
}
