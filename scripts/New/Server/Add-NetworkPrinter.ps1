<#
Domech Fabricators - install and share a network printer on the server

Run on the DC, elevated. For each network printer in config.json's Printers
list, creates the TCP/IP port, installs the printer and shares it. After this,
'Deploy printers to users' maps it to everyone.

WHY GO THROUGH THE SERVER
The alternative is installing the printer directly on all 11 workstations,
which means putting the driver on all 11 by hand. Sharing it from the server
means the driver is installed once, here, and Windows hands it to each
workstation automatically when they connect (Point and Print). It also gives
one place to see and clear the print queue.

THE ONE MANUAL STEP
Windows needs the printer's driver installed on this server before the printer
can be created. If the driver is missing this script says so and stops, without
changing anything. To install it: download the Brother driver for Windows
Server / Windows 10 x64, run the installer once on this server, then rerun this.

USB printers are not handled here and do not need to be - they are attached to
one PC each and Windows installs them locally when plugged in.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$printers = $Config.Printers | Where-Object { $_.IPAddress }
if (-not $printers) {
    Write-DomechLog "No printers with an IPAddress in config.json - nothing to install." -Level Warning
    exit 0
}

foreach ($p in $printers) {
    Write-DomechLog "===== $($p.Name) at $($p.IPAddress) =====" -Level Info

    # Reachable? A printer that does not answer is almost always powered off or
    # still on its old DHCP address.
    if (Test-Connection -ComputerName $p.IPAddress -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Write-DomechLog "  Responds at $($p.IPAddress)." -Level Success
    } else {
        Write-DomechLog "  NOT reachable at $($p.IPAddress). It is probably powered off, or still on its old DHCP address - the IP plan notes this printer was on 192.168.0.191 before being set static. Fix the address first; nothing has been changed." -Level Error
        continue
    }

    # ---- port ----
    $portName = "IP_$($p.IPAddress)"
    if (Get-PrinterPort -Name $portName -ErrorAction SilentlyContinue) {
        Write-DomechLog "  Port '$portName' already exists." -Level Info
    } else {
        Add-PrinterPort -Name $portName -PrinterHostAddress $p.IPAddress
        Write-DomechLog "  Created port '$portName'." -Level Success
    }

    # ---- driver ----
    # Match loosely: the installed driver name rarely matches the model exactly
    # (e.g. "Brother DCP-B7535DW series"), so match on the first word of the
    # model and let the operator confirm from the list printed on failure.
    $modelWord = ($p.Name -split '\s+')[0]
    $driver = Get-PrinterDriver -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$modelWord*" } |
        Sort-Object Name | Select-Object -First 1

    if (-not $driver) {
        Write-DomechLog "  No driver matching '$modelWord' is installed on this server, so the printer cannot be created yet." -Level Error
        Write-DomechLog "  Install the $($p.Name) driver on this server once, then rerun this option." -Level Warning
        Write-DomechLog "  Drivers currently installed here:" -Level Info
        Get-PrinterDriver | Select-Object -ExpandProperty Name | ForEach-Object { Write-DomechLog "    $_" -Level Info }
        continue
    }
    Write-DomechLog "  Using driver '$($driver.Name)'." -Level Success

    # ---- printer + share ----
    $existing = Get-Printer -Name $p.Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-DomechLog "  Printer '$($p.Name)' already installed." -Level Info
    } else {
        Add-Printer -Name $p.Name -DriverName $driver.Name -PortName $portName
        Write-DomechLog "  Installed printer '$($p.Name)'." -Level Success
    }

    $shareName = if ($p.ShareName) { $p.ShareName } else { ($p.Name -replace '[^A-Za-z0-9]', '') }
    Set-Printer -Name $p.Name -Shared $true -ShareName $shareName -Published $true
    Write-DomechLog "  Shared as '$shareName' - workstations connect to \\$env:COMPUTERNAME\$shareName" -Level Success

    # Confirm rather than assume, since Set-Printer reports nothing on success.
    $check = Get-Printer -Name $p.Name
    if ($check.Shared -and $check.ShareName -eq $shareName) {
        Write-DomechLog "  Verified: shared and ready to deploy." -Level Success
    } else {
        Write-DomechLog "  Sharing did not take - check the printer by hand in Control Panel > Devices and Printers." -Level Error
    }
}

Write-DomechLog "" -Level Info
Write-DomechLog "Next: run 'Deploy printers to users' to map it to everyone." -Level Info
