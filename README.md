# winserver-setup

Config-driven PowerShell toolkit for building/managing a Windows Server AD domain and its workstations. Menu-driven via `Domech-Menu.bat`.

## What's in this repo vs. what isn't

`config.json` (site names/IPs/paths/users) and `Assets/` (branding images and
fonts) ARE tracked in this repo — only `Logs/` and `Scratch/` (generated at
runtime) are excluded via `.gitignore`. `config.json` holds no secrets: the
shared temporary password for new-user rollout is typed in interactively
when `Setup-DFLocal-Full.ps1` runs, never stored on disk or in git.

This repo is public - don't add secrets (passwords, API keys) to config.json
or anywhere else in this folder.

## First-time setup on a new server

```powershell
git clone https://github.com/srijitnair-git/winserver-setup.git C:\01_matrix
```

This gives you `Domech-Menu.bat`, `scripts\`, `config.json`, and `Assets\` —
everything needed to run. Review `config.json` for this site (domain name,
workstation IPs, users, etc.) before running anything, then run `Domech-Menu.bat`.

## Getting future script updates

Once set up, either:
- Run `git pull` in `C:\01_matrix`, or
- Use the menu: main menu → **Update scripts from GitHub**

Neither touches `config.json` or `Assets\`.
