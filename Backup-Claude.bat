@echo off
rem Claude backup - double-click to back up Claude Code and Claude Desktop, and choose which workspaces to include.
rem The backup is saved to a new folder in your Downloads folder, together with everything needed to restore it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Backup-Claude.ps1" -OpenFolder %*
echo.
pause
