# How it works

Technical notes for anyone who wants to check, extend or debug the backup and restore programs.

## The backup format

A backup is a normal zip. Every file is stored under its full original path, with the drive letter as the top folder, so `D:\Code\app\README.md` is stored as `D/Code/app/README.md`. Files are stored uncompressed unless `-Compress` is used; already-compressed formats (`.zip`, `.png`, `.docx`, `.exe` and similar) are never compressed again.

| In the zip | Purpose |
| --- | --- |
| `C/...`, `D/...` | The backed-up files and empty folders |
| `RESTORE-LOCATIONS.txt` | The same text as the backup folder's `README.txt` |
| `_restore/manifest.csv` | One row per file or empty folder: `Source`, `Type` (`File`/`Dir`), `ZipPath`, `OriginalPath`, `Bytes`, `LastWriteUtc` |
| `_restore/backup-info.json` | Summary the restore reads: tool version, computer, user folder, Claude Code folder, Claude Desktop data folder and package, sign-in key hash, Node.js version, workspaces, every backed-up location with its kind and label, what was left out, what was skipped |
| `_restore/Restore-Claude.ps1`, `_restore/Restore-Claude.bat` | Copies of the restore program, so the zip works on its own |

Every backed-up location has a kind: `ClaudeCode`, `ClaudeCodeState`, `ClaudeDesktop`, `ClaudeDesktopOld`, `ClaudeDesktopLogs`, `ClaudeService`, `Workspace` or `McpServer`. The restore uses it to decide which JSON files are Claude's own config, and so may have user-folder paths updated. Workspace files are never edited, except Claude project settings (`.claude\` folders and `.mcp.json`).

After writing, the backup reopens the zip and checks the number of entries matches the manifest before renaming `.zip.partial` to `.zip`.

## Finding Claude

| What | Where it looks |
| --- | --- |
| Claude Code folder | `CLAUDE_CONFIG_DIR` if set, otherwise `%USERPROFILE%\.claude`. If neither exists, it asks. |
| Claude Code settings | `%USERPROFILE%\.claude.json` and its `.backup` / `.tmp.*` copies, plus `CLAUDE_CONFIG_DIR\.claude.json` when that is set |
| Claude Desktop data | See below |
| Claude Desktop logs | `%LOCALAPPDATA%\Claude` |
| Claude service log | `%ProgramData%\Claude` |

### Claude Desktop data locations

Claude Desktop is usually installed as a Store (MSIX) app, package family `Claude_pzs8sxrjxfjjc`.

- Version 2 wrote to `%APPDATA%\Claude`, but Windows redirects a packaged app's AppData writes into `%LOCALAPPDATA%\Packages\Claude_pzs8sxrjxfjjc\LocalCache\Roaming\Claude`. Processes started by Claude, including a terminal inside Claude Desktop, see the short path; Explorer and normal terminals see only the package path.
- Version 3 moved the data to `%LOCALAPPDATA%\Claude-Data\claude_pzs8sxrjxfjjc` and left a marker file, `.user-data-left.claude_pzs8sxrjxfjjc`, in the old folder.
- A classic install uses `%APPDATA%\Claude` directly.

The backup includes every one of these that exists, and treats the first one holding `config.json` as the live one. `%APPDATA%\Claude` is skipped when NTFS reports the same file ID as the package folder, because then it is the same folder seen through redirection.

The restore picks its target the same way on the destination PC: the first of those locations that holds `config.json` there. That is why Claude Desktop should be opened once before restoring. Data from the backup's live location goes to the destination's live location, whatever the app version or install type on either side.

## Finding workspaces

| Source | How |
| --- | --- |
| Chat transcripts | The first `"cwd"` value in each `.claude\projects\<folder>\*.jsonl` |
| Claude Desktop session cards | `cwd` and `lastActivityAt` in each `claude-code-sessions\**\local_*.json` |
| Claude Code project list | The keys of `projects` in `.claude.json` |

Paths are normalised (`/` to `\`, no trailing `\`) and merged. The list then drops folders that no longer exist, temporary folders, Claude's own folders, Windows and Program Files. It folds folders inside another workspace into that workspace, and leaves very broad folders (a drive root, the user folder, Desktop, Documents, Downloads, OneDrive, AppData) unticked.

### MCP server folders

Every MCP server definition in `claude_desktop_config.json` and `.claude.json` (user and project scope) is read. Each `command`, `args` and `env` value that is an existing local path becomes a candidate:

- a folder is used as it is
- for a file, the program walks up to the nearest folder holding `package.json`, `pyproject.toml`, `requirements.txt`, `setup.py`, `Cargo.toml`, `go.mod` or `.git`; failing that it uses the file's folder, or just the file if that folder is too broad

Paths under Program Files, Windows, `%APPDATA%\npm` (global npm packages), temp folders and Claude's own folders are ignored. When two or more server folders share a parent folder, the parent is used instead, which also captures files the servers share.

## Reading files safely

- Files are opened with full read/write/delete sharing, so files Claude has open can still be copied. Each file is copied completely (in memory, or to a temporary file above 64 MB) before its zip entry is created, so a read error never leaves a half-written entry; the file is listed as skipped instead.
- Paths are accessed with the `\\?\` prefix, which lifts Windows' 260-character limit. Some Claude Desktop plugin files have paths of almost 300 characters.
- Links and junctions are not followed.
- Folders holding the hidden `.claude-backup-folder` marker (every backup folder this tool creates), files named `claude-backup_*.zip`, and `pre-restore_<date>` folders are never included, so backups don't nest.

## Sign-in handling

Claude Desktop keeps its sign-in tokens in `config.json`, encrypted with Electron's `safeStorage`. The values start with `v10`/`v11`, which is `djEw`/`djEx` in base64. The key that decrypts them sits in `Local State`, itself encrypted with Windows DPAPI for the current Windows account, so it is useless on any other PC or account.

- The backup leaves out `Local State` and the `Network` folder (cookies), and records a SHA-256 hash of the encrypted key, never the key itself.
- The restore compares that hash with the destination's `Local State`. If they match (same PC and account), the tokens are restored as they are.
- If they differ, the restore removes the backup's encrypted values from `config.json` and puts back any that were already on the destination PC. Claude then asks for a fresh sign-in, or keeps the one already there. The edit is a text edit, so the rest of the file is unchanged, and the result is checked to be valid JSON before it is saved.

## Moving to a different Windows user name

When the destination user folder differs from the backup's, files from the old user folder go into the new one. In Claude's own JSON config files (by location kind, plus `.claude\` folders and `.mcp.json` anywhere), the old user-folder path is replaced in both JSON forms, `C:\\Users\\old` and `C:/Users/old`. It is only replaced where the next character is `\`, `/` or `"`, so `C:\Users\oldX` is not touched.

## Restore safety

- The preview classifies every file as New, Replace, Replace (disk newer), Same or held back. A file is Same when its size matches and its modified time is within 2 seconds, which is the precision zip timestamps keep.
- Before a file is replaced, it is copied to `pre-restore_<date>\<drive>\<path>` next to the zip. Paths that would be too long for Explorer go to `pre-restore_<date>\long-paths\` under a short name. `INDEX.csv` maps every copy to its original path. If the copy fails, the file is left unchanged.
- The restore never deletes anything, and refuses to run while a `claude` process is running unless `-Force` is given.
- Held back, with a printed command to finish: Claude Desktop data when no Claude Desktop data folder exists on the destination; anything under `%LOCALAPPDATA%\Packages` when the Store app isn't installed; `%ProgramData%` without Administrator rights; any path on a drive the destination doesn't have.
