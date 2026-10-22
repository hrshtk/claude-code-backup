# Contributing

Bug reports and fixes are welcome, and so is support for Claude setups this tool doesn't handle yet.

## Reporting a bug

Run the backup with `-ListOnly` and paste the output into the issue, after replacing your user name and any private folder names. Don't attach a backup zip, a backup's `README.txt`, `claude_desktop_config.json` or `.claude.json`, because they contain keys and account details.

## Making changes

- The scripts must run on Windows PowerShell 5.1, the version built into Windows. Avoid syntax that only PowerShell 7 understands, such as `??`, `?.` and the ternary operator.
- Keep `.ps1` and `.bat` files plain ASCII with CRLF line endings. Windows PowerShell reads a script that has no byte-order mark using the system code page, so other characters can break it, and `cmd.exe` can misread labels in a `.bat` file with LF endings. `.gitattributes` keeps the line endings right.
- Open files with full read, write and delete sharing, since Claude keeps some of them open.
- Use `\\?\` paths for file access in the backup and restore loops. Some Claude Desktop files have paths close to 300 characters.
- The restore must never delete a file, and must copy a file aside before replacing it.

## Testing

Run the tests before you open a pull request:

```powershell
powershell -ExecutionPolicy Bypass -File .\tests\Run-Tests.ps1
```

They restore fake backups inside `%TEMP%\claude-backup-tests`, with the user folders redirected there. If you change how the restore decides where files go, add a scenario for it.

To try the backup without filling your Downloads folder:

```powershell
powershell -ExecutionPolicy Bypass -File .\Backup-Claude.ps1 -ListOnly
powershell -ExecutionPolicy Bypass -File .\Backup-Claude.ps1 -NoWorkspaces -Yes -OutputRoot "$env:TEMP\claude-backup-try"
```
