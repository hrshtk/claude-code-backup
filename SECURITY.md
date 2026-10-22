# Security policy

## Reporting a problem

If you find a way this tool could leak data, write outside the folders it should, or restore something it shouldn't, report it privately: open the Security tab of this repository and choose "Report a vulnerability". Please don't open a public issue for it.

Describe what you ran, what happened and what you expected. Leave out real backups, passwords, keys and personal paths.

## What a backup contains

A backup holds MCP server passwords and API keys in plain text, your Claude account details, and the contents of the workspaces you chose. The restore needs all of it to bring back working settings, so treat every backup as sensitive. Each backup's `README.txt` names the sensitive files it noticed.

## Supported versions

Fixes go into the latest release only.
