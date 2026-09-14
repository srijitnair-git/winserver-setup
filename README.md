# winserver-setup

Config-driven PowerShell toolkit for building/managing a Windows Server AD domain and its workstations. Menu-driven via `Domech-Menu.bat`.

## What's in this repo vs. what isn't

This repo is the **code only**. Three things are deliberately excluded (see `.gitignore`) because they're site-specific, not portable:

- `config.json` — every name/IP/path/user this toolkit acts on
- `Assets/` — branding images and fonts (wallpaper, lock screen, login splash)
- `Logs/`, `Scratch/` — generated at runtime

## First-time setup on a new server

```powershell
git clone https://github.com/srijitnair-git/winserver-setup.git C:\01_matrix
```

This gives you `Domech-Menu.bat`, `scripts\`, and everything else — **except** `config.json` and `Assets\`, which don't exist in the repo. Copy those in from wherever you keep them (USB, another share) so you end up with:

```
C:\01_matrix\
  Domech-Menu.bat   <- from git clone
  scripts\          <- from git clone
  config.json       <- copy in separately
  Assets\           <- copy in separately
  Logs\             <- created automatically on first run
```

Edit `config.json` for this site (domain name, workstation IPs, users, etc.), then run `Domech-Menu.bat`.

## Getting future script updates

Once set up, either:
- Run `git pull` in `C:\01_matrix`, or
- Use the menu: main menu → **Update scripts from GitHub**

Neither touches `config.json` or `Assets\`.
