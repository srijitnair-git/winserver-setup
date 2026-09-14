<#
Domech Fabricators - toolkit launcher

First time on a machine, in an ELEVATED PowerShell window:

  irm https://srijitnair-git.github.io/winserver-setup/fix.ps1 | iex

After that, just type:  domech

Downloads the current toolkit to C:\01_matrix, installs the "domech" shortcut,
then shows one menu option per problem so they can be fixed one at a time.
An existing config.json is always preserved. Safe to run again any time.
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
try {
    $tmp = Join-Path $env:TEMP "domech-bootstrap"
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null

    Write-Host "Downloading the latest toolkit..." -ForegroundColor Cyan
    $zip = Join-Path $tmp "repo.zip"
    Invoke-WebRequest -Uri $ZipUrl -OutFile $zip -UseBasicParsing
    Expand-Archive -Path $zip -DestinationPath $tmp -Force
    $inner = Get-ChildItem $tmp -Directory | Select-Object -First 1

    # config.json is this site's own settings - a download must never replace it.
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
    Write-Host "Toolkit updated at $InstallRoot" -ForegroundColor Green
}
catch {
    Write-Host "Could not download an update: $($_.Exception.Message)" -ForegroundColor Yellow
    if (Test-Path (Join-Path $InstallRoot 'scripts')) {
        Write-Host "Carrying on with the copy already on this machine." -ForegroundColor Yellow
    } else {
        Write-Host "Nothing installed locally either - check the network and try again." -ForegroundColor Red
        return
    }
}

# ---------- install the "domech" shortcut ----------
# C:\Windows is on PATH for every account, so this makes "domech" work from
# any PowerShell or Command Prompt on this machine from now on.
if ($elevated) {
    try {
        @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "$InstallRoot\fix.ps1" %*
"@ | Out-File "$env:WINDIR\domech.cmd" -Encoding ASCII -Force
        Write-Host "Shortcut installed - next time just type: domech" -ForegroundColor Green
    } catch {
        Write-Host "Could not install the 'domech' shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------- menu ----------
function Invoke-Toolkit {
    param([string]$RelativePath, [string[]]$Arguments = @(), [switch]$NeedsElevation)

    if ($NeedsElevation -and -not $elevated) {
        Write-Host ""
        Write-Host "  That one needs an elevated window. Close this, open PowerShell as" -ForegroundColor Red
        Write-Host "  Administrator, and type: domech" -ForegroundColor Red
        return
    }
    $full = Join-Path $InstallRoot $RelativePath
    if (-not (Test-Path $full)) {
        Write-Host "  Missing file: $full" -ForegroundColor Red
        return
    }
    Write-Host ""
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $full @Arguments
    Write-Host ""
    Write-Host "  --- finished - back at the menu ---" -ForegroundColor Gray
}

$setup = 'scripts\New\Server\Setup-DFLocal-Full.ps1'

while ($true) {
    Write-Host ""
    Write-Host "  ON THE SERVER (domain controller)" -ForegroundColor Cyan
    Write-Host "   1. Stop staff policies applying to admin accounts"
    Write-Host "   2. Remove the C: drive restriction everywhere"
    Write-Host "   3. Fix folder permissions and shares"
    Write-Host "   4. Create the missing user accounts"
    Write-Host "   5. Fix drive mappings (and folder redirection)"
    Write-Host "   6. Clear the old Salary / Purchase folders"
    Write-Host "   7. Run all of 1-6 in the correct order"
    Write-Host ""
    Write-Host "  ON THIS PC (server or workstation)" -ForegroundColor Cyan
    Write-Host "   8. Repair my Windows profile (Explorer, Settings, Control Panel)"
    Write-Host "   9. Fix this workstation (profile + refresh policy + check drives)"
    Write-Host "  10. Diagnose drive mapping - writes a log, changes nothing"
    Write-Host ""
    Write-Host "   0. Exit"
    Write-Host ""
    $choice = Read-Host "  Type a number and press Enter"

    switch ($choice) {
        '1'  { Invoke-Toolkit 'scripts\New\Server\Block-StaffGposFromAdmins.ps1'    -NeedsElevation }
        '2'  { Invoke-Toolkit 'scripts\New\Server\Remove-CDriveRestriction.ps1'     -NeedsElevation }
        '3'  { Invoke-Toolkit $setup -Arguments @('-Only','Shares')                 -NeedsElevation }
        '4'  { Invoke-Toolkit $setup -Arguments @('-Only','Users')                  -NeedsElevation }
        '5'  { Invoke-Toolkit $setup -Arguments @('-Only','DriveMaps')              -NeedsElevation }
        '6'  { Invoke-Toolkit 'scripts\New\Server\Remove-OldSalaryPurchaseFolders.ps1' -NeedsElevation }
        '7'  { Invoke-Toolkit 'scripts\New\Server\Repair-DFLocal-Full.ps1'          -NeedsElevation }
        '8'  { Invoke-Toolkit 'scripts\Repair-UserProfile.ps1' }
        '9'  { Invoke-Toolkit 'scripts\New\Workstation\Repair-Workstation.ps1' }
        '10' { Invoke-Toolkit 'scripts\New\Workstation\Diagnose-DriveMapping.ps1' }
        '0'  { return }
        default { Write-Host "  Pick a number from the list." -ForegroundColor Yellow }
    }
}
