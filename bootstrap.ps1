<#
Domech Fabricators - one-line bootstrap

Run this in an ELEVATED PowerShell window, on the server or on any workstation:

  [Net.ServicePointManager]::SecurityProtocol='Tls12'; irm https://raw.githubusercontent.com/srijitnair-git/winserver-setup/main/bootstrap.ps1 | iex

It downloads the current toolkit to C:\01_matrix and then offers the handful
of things worth running. No git needed, nothing to unzip by hand. Safe to run
again any time - an existing config.json is always preserved.
#>

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = 'Tls12'

$InstallRoot = 'C:\01_matrix'
$ZipUrl      = 'https://github.com/srijitnair-git/winserver-setup/archive/refs/heads/main.zip'

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

Write-Host ""
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Domech toolkit" -ForegroundColor Cyan
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "  Machine  : $env:COMPUTERNAME"
Write-Host "  Signed in: $env:USERDOMAIN\$env:USERNAME"
Write-Host "  Elevated : $elevated"
Write-Host ""

# ---------- download + install ----------
$tmp = Join-Path $env:TEMP "domech-bootstrap"
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

Write-Host "Downloading the latest toolkit..." -ForegroundColor Cyan
$zip = Join-Path $tmp "repo.zip"
Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $tmp -Force
$inner = Get-ChildItem $tmp -Directory | Select-Object -First 1

# config.json is this site's own settings - never let a download overwrite it.
$liveConfig   = Join-Path $InstallRoot 'config.json'
$configBackup = $null
if (Test-Path $liveConfig) {
    $configBackup = Join-Path $tmp 'config.local.json'
    Copy-Item $liveConfig $configBackup -Force
}

New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
Copy-Item "$($inner.FullName)\*" $InstallRoot -Recurse -Force
if ($configBackup) {
    Copy-Item $configBackup $liveConfig -Force
    Write-Host "Kept the config.json already on this machine." -ForegroundColor Gray
}
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "Toolkit ready at $InstallRoot" -ForegroundColor Green

# ---------- menu ----------
function Invoke-Toolkit($relativePath) {
    $full = Join-Path $InstallRoot $relativePath
    if (-not (Test-Path $full)) {
        Write-Host "Missing file: $full" -ForegroundColor Red
        return
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $full
    Write-Host ""
    Write-Host "--- finished, back at the menu ---" -ForegroundColor Gray
}

while ($true) {
    Write-Host ""
    Write-Host "  What do you want to do?" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  1. Fix THIS SERVER          - run on the domain controller. Admin profile," -ForegroundColor White
    Write-Host "                                GPOs, users, shares, folder permissions, drives."
    Write-Host "  2. Fix THIS WORKSTATION     - run on a staff PC, signed in as that person." -ForegroundColor White
    Write-Host "  3. Repair my profile only   - Explorer / Settings / Control Panel broken," -ForegroundColor White
    Write-Host "                                empty file dialogs, installers failing."
    Write-Host "  4. Diagnose drive mapping   - writes a log to send on, changes nothing." -ForegroundColor White
    Write-Host "  0. Exit" -ForegroundColor White
    Write-Host ""
    $choice = Read-Host "  Type a number and press Enter"

    switch ($choice) {
        '1' {
            if (-not $elevated) {
                Write-Host "This one needs an elevated window. Close this, open PowerShell as Administrator, and run the same command again." -ForegroundColor Red
            } else {
                Invoke-Toolkit 'scripts\New\Server\Repair-DFLocal-Full.ps1'
            }
        }
        '2' { Invoke-Toolkit 'scripts\New\Workstation\Repair-Workstation.ps1' }
        '3' { Invoke-Toolkit 'scripts\Repair-UserProfile.ps1' }
        '4' { Invoke-Toolkit 'scripts\New\Workstation\Diagnose-DriveMapping.ps1' }
        '0' { Write-Host "Bye." -ForegroundColor Gray; return }
        default { Write-Host "  Pick 1, 2, 3, 4 or 0." -ForegroundColor Yellow }
    }
}
