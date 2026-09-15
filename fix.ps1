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
$RawUrl      = 'https://raw.githubusercontent.com/srijitnair-git/winserver-setup/main/fix.ps1'

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

    # If this script is itself about to be replaced, the menu further down is
    # the OLD one - PowerShell parsed this file before the download happened,
    # so new options would be missing until the next run. Notice that and say
    # so, rather than showing a stale menu that silently lacks them.
    $selfPath = $PSCommandPath     # empty when run straight from the URL, which is never stale
    $selfHashBefore = if ($selfPath -and (Test-Path $selfPath)) {
        (Get-FileHash $selfPath -Algorithm SHA256).Hash
    } else { $null }

    New-Item -ItemType Directory -Path $InstallRoot -Force | Out-Null
    Copy-Item "$($inner.FullName)\*" $InstallRoot -Recurse -Force

    if ($configBackup) {
        # Put this machine's own config back, then merge in anything new from
        # the update. Without the merge, settings added upstream (new apps,
        # printers, quotes) never arrive - the scripts update but the settings
        # they read stay frozen at whatever this machine had on day one.
        # Only ever adds: an existing value here always wins.
        Copy-Item $configBackup $liveConfig -Force

        function Merge-DomechConfig {
            param($From, $Into, [string]$Path = "")
            $added = @()
            foreach ($prop in $From.PSObject.Properties) {
                $name = $prop.Name
                $full = if ($Path) { "$Path.$name" } else { $name }

                if (-not $Into.PSObject.Properties[$name]) {
                    $Into | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value
                    $added += $full
                }
                elseif ($prop.Value -is [System.Management.Automation.PSCustomObject] -and
                        $Into.$name -is [System.Management.Automation.PSCustomObject]) {
                    $added += Merge-DomechConfig -From $prop.Value -Into $Into.$name -Path $full
                }
                elseif ($prop.Value -is [Array] -and $Into.$name -is [Array]) {
                    foreach ($item in $prop.Value) {
                        if ($item -is [string] -and $Into.$name -notcontains $item) {
                            $Into.$name += $item
                            $added += "$full -> $item"
                        }
                    }
                }
            }
            return $added
        }

        try {
            $repoCfg  = Get-Content "$($inner.FullName)\config.json" -Raw | ConvertFrom-Json
            $localCfg = Get-Content $liveConfig -Raw | ConvertFrom-Json
            $newBits  = Merge-DomechConfig -From $repoCfg -Into $localCfg

            if ($newBits) {
                Copy-Item $liveConfig "$liveConfig.backup" -Force
                $localCfg | ConvertTo-Json -Depth 20 | Out-File $liveConfig -Encoding UTF8
                Write-Host "Kept your config.json and added $($newBits.Count) new setting(s):" -ForegroundColor Green
                $newBits | ForEach-Object { Write-Host "    + $_" -ForegroundColor Green }
                Write-Host "  (previous version saved as config.json.backup)" -ForegroundColor Gray
            } else {
                Write-Host "Kept the config.json already on this machine - nothing new to add." -ForegroundColor Gray
            }
        } catch {
            Write-Host "Could not merge new settings into config.json: $($_.Exception.Message)" -ForegroundColor Yellow
            Write-Host "Your config.json is untouched." -ForegroundColor Yellow
        }
    }

    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "Toolkit updated at $InstallRoot" -ForegroundColor Green

    if ($selfHashBefore) {
        $selfHashAfter = (Get-FileHash $selfPath -Algorithm SHA256).Hash
        if ($selfHashAfter -ne $selfHashBefore) {
            Write-Host ""
            Write-Host "  =====================================================" -ForegroundColor Yellow
            Write-Host "   This launcher just updated itself." -ForegroundColor Yellow
            Write-Host "   The menu loaded in memory is the previous version," -ForegroundColor Yellow
            Write-Host "   so it may be missing newly added options." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "   Type  domech  again to get the current menu." -ForegroundColor Yellow
            Write-Host "  =====================================================" -ForegroundColor Yellow
            Write-Host ""
            return
        }
    }
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
        # Fetch fresh from the URL rather than running the local copy. Running
        # the local file meant the menu came from the version already on disk,
        # which is by definition the previous one - new options only appeared
        # on the run after. Falls back to the local copy when offline.
        @"
@echo off
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol='Tls12'; try { irm '$RawUrl' | iex } catch { Write-Host 'Offline - using the copy on this machine.' -ForegroundColor Yellow; & '$InstallRoot\fix.ps1' }"
"@ | Out-File "$env:WINDIR\domech.cmd" -Encoding ASCII -Force
        Write-Host "Shortcut installed - next time just type: domech" -ForegroundColor Green
    } catch {
        Write-Host "Could not install the 'domech' shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
    }
}

# ---------- menu ----------
function Invoke-Toolkit {
    param([string]$RelativePath, [string[]]$Arguments = @(), [switch]$NeedsElevation)

    $full = Join-Path $InstallRoot $RelativePath
    if (-not (Test-Path $full)) {
        Write-Host "  Missing file: $full" -ForegroundColor Red
        return
    }

    Write-Host ""
    if ($NeedsElevation -and -not $elevated) {
        # Ask for elevation rather than sending the user away to reopen a
        # window. Only used for the options that genuinely need admin rights -
        # the per-user repairs deliberately stay in the current account, since
        # elevating as somebody else would fix the wrong profile.
        Write-Host "  This needs administrator rights - approve the prompt." -ForegroundColor Yellow
        $argList = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$full`"") + $Arguments
        try {
            Start-Process powershell.exe -Verb RunAs -ArgumentList $argList -Wait
            Write-Host "  (ran in an elevated window)" -ForegroundColor Gray
        } catch {
            Write-Host "  Elevation was refused or failed: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host "  If this PC is not yours to administer, an admin needs to run it." -ForegroundColor Red
        }
    } else {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $full @Arguments
    }

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
    Write-Host "  ROLLOUT (server)" -ForegroundColor Cyan
    Write-Host "  11. Wallpaper, lock screen and login splash"
    Write-Host "  12. Install/update apps on every workstation"
    Write-Host "  20. Who has access to what - reports only, changes nothing"
    Write-Host "  21. Check internet name lookups on the server (fixes DNS forwarding)"
    Write-Host "  13. Find printers on the network - reports only, changes nothing"
    Write-Host "  14. Install and share the network printer on this server"
    Write-Host "  15. Deploy printers to users (run 14 first)"
    Write-Host ""
    Write-Host "  ON THIS PC (server or workstation)" -ForegroundColor Cyan
    Write-Host "   8. Repair my Windows profile (Explorer, Settings, Control Panel)"
    Write-Host "   9. Fix this workstation (profile + refresh policy + check drives)"
    Write-Host "  17. Repair the Start Menu on this PC"
    Write-Host "  18. Install/update the apps on THIS PC right now (no server setup needed)"
    Write-Host "  10. Diagnose drive mapping - writes a log, changes nothing"
    Write-Host "  16. Why haven't the apps installed on this PC? - reports only"
    Write-Host "  22. Check this PC's network - reports only, changes nothing"
    Write-Host "  23. Set this PC's static IP from config.json"
    Write-Host ""
    Write-Host "  PRINTERS ON A WORKSTATION (run from the server)" -ForegroundColor Cyan
    Write-Host "  19. List / share a USB printer on someone's PC"
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
        '8'  { Invoke-Toolkit 'scripts\Repair-UserProfile.ps1' -Arguments @('-Force') }
        '9'  { Invoke-Toolkit 'scripts\New\Workstation\Repair-Workstation.ps1' }
        '10' { Invoke-Toolkit 'scripts\New\Workstation\Diagnose-DriveMapping.ps1' }
        '11' { Invoke-Toolkit $setup -Arguments @('-Only','Branding')               -NeedsElevation }
        '12' { Invoke-Toolkit 'scripts\New\Server\Deploy-AppInstallGPO.ps1'         -NeedsElevation }
        '13' { Invoke-Toolkit 'scripts\New\Server\Find-NetworkPrinters.ps1'         -NeedsElevation }
        '14' { Invoke-Toolkit 'scripts\New\Server\Add-NetworkPrinter.ps1'           -NeedsElevation }
        '15' { Invoke-Toolkit 'scripts\New\Server\Deploy-PrintersGPO.ps1'           -NeedsElevation }
        '16' { Invoke-Toolkit 'scripts\New\Workstation\Diagnose-AppInstall.ps1' }
        '17' { Invoke-Toolkit 'scripts\Repair-StartMenu.ps1' }
        '20' { Invoke-Toolkit 'scripts\New\Server\Show-AccessAudit.ps1'            -NeedsElevation }
        '21' { Invoke-Toolkit 'scripts\New\Server\Repair-DnsForwarding.ps1'        -NeedsElevation }
        '22' { Invoke-Toolkit 'scripts\New\Workstation\Test-NetworkHealth.ps1' }
        '23' { Invoke-Toolkit 'scripts\New\Workstation\Set-StaticIP.ps1'           -NeedsElevation }
        '18' {
            # Runs the copy in this folder with the app list read from the local
            # config.json, so it works whether or not the server deployment has
            # ever succeeded. -Now skips the once-a-day guard, which a manual
            # request should obviously ignore.
            Write-Host "  Installing the standard apps on THIS PC. Microsoft 365 is large - this can take a while." -ForegroundColor Cyan
            Invoke-Toolkit 'scripts\New\Workstation\Install-StandardApps.ps1' -Arguments @('-Now') -NeedsElevation
            Write-Host "  Details logged to C:\ProgramData\Domech\AppInstall.log" -ForegroundColor Gray
        }
        '19' {
            $pc = Read-Host "  Which PC? (e.g. SUPRIYA-DF)"
            if ($pc) {
                $prn = Read-Host "  Printer name to share (press Enter to just list what is on that PC)"
                $shareArgs = @('-ComputerName', $pc)
                if ($prn) {
                    $shr = Read-Host "  Share name (e.g. CanonSupriya - must match config.json)"
                    $shareArgs += @('-PrinterName', $prn)
                    if ($shr) { $shareArgs += @('-ShareName', $shr) }
                }
                Invoke-Toolkit 'scripts\New\Server\Share-WorkstationPrinter.ps1' -Arguments $shareArgs -NeedsElevation
            }
        }
        '0'  { return }
        default { Write-Host "  Pick a number from the list." -ForegroundColor Yellow }
    }
}
