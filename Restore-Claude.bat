@echo off
rem Claude backup - restores the backup zip that sits next to this file.
rem Step 1 shows a preview and writes nothing. Step 2 restores, only after you type YES.
setlocal
set "HERE=%~dp0"
set "ZIP="
for %%F in ("%HERE%claude-backup_*.zip") do set "ZIP=%%~fF"
if not defined ZIP goto nozip

echo Backup: %ZIP%
echo.
echo Step 1 of 2 - preview. Nothing is written.
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%Restore-Claude.ps1" -ZipPath "%ZIP%"
if errorlevel 1 goto failed

echo.
echo Step 2 of 2 - restore.
echo Before you continue: quit Claude Desktop (also from the system tray) and close any 'claude' terminals.
set "ANSWER="
set /p "ANSWER=Type YES to restore, or press Enter to stop: "
if /i not "%ANSWER%"=="YES" goto stopped

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%Restore-Claude.ps1" -ZipPath "%ZIP%" -Apply
if errorlevel 1 goto failed
echo.
pause
exit /b 0

:nozip
echo No claude-backup_*.zip file was found next to this file.
echo Keep Restore-Claude.bat, Restore-Claude.ps1 and the backup zip together in one folder.
echo.
pause
exit /b 1

:stopped
echo Nothing was restored.
echo.
pause
exit /b 0

:failed
echo.
echo The restore stopped - see the message above. Nothing after that point was written.
echo.
pause
exit /b 1
