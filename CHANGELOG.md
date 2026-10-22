# Changelog

## 1.0.0 - 2026-10-22

First release.

- Backs up Claude Code (`.claude`, `.claude.json`), Claude Desktop (Store app version 2 and 3, classic install), Claude Desktop logs and the Claude service log.
- Finds workspaces from chat transcripts, Claude Desktop session cards and the `.claude.json` project list, and local MCP server folders from MCP server settings. You choose which to include, or name folders yourself.
- Writes `Downloads\Claude-Backup_<date>_<time>\` with the zip, `Restore-Claude.bat`, `Restore-Claude.ps1` and `README.txt`.
- Leaves out caches, cookies, the Windows-account-bound encryption key, process lists, lock files and earlier backups, and lists each with the reason.
- Restore with a preview, safety copies, user-name changes, cross-version Claude Desktop data placement, sign-in cleanup, long paths, and held-back items with commands to finish.
- Sandboxed tests for six restore scenarios and the sign-in cleanup.
