<#
Domech Fabricators - find printers on the network

Run on the DC, elevated. Read-only: it changes nothing, it only reports.

Nothing in this toolkit knows what printers exist - the old server's logon
script declared a printer variable but never actually mapped anything, so
there is no inventory to migrate. This finds them so config.json's Printers
list can be filled in.

Reports three things:
  1. Printers already installed on this server, and whether they are shared
  2. Printers installed on each reachable workstation (these are the ones
     people are actually using today)
  3. Devices on the subnet answering on printer ports (9100 raw, 515 LPD,
     631 IPP) - catches network printers nobody has set up on the server yet
#>

Import-Module ActiveDirectory -ErrorAction SilentlyContinue

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

# ---- 1. On this server ----
Write-DomechLog "===== Printers installed on this server =====" -Level Info
$serverPrinters = Get-Printer -ErrorAction SilentlyContinue |
    Select-Object Name, DriverName, PortName, Shared, ShareName
if ($serverPrinters) {
    $serverPrinters | Format-Table -AutoSize | Out-String | Write-DomechLog -Level Info
    $unshared = $serverPrinters | Where-Object { -not $_.Shared }
    if ($unshared) {
        Write-DomechLog "These are installed but NOT shared, so they cannot be deployed to users yet: $($unshared.Name -join ', ')" -Level Warning
    }
} else {
    Write-DomechLog "No printers installed on this server. To deploy printers centrally, install each one here first and tick 'Share this printer'." -Level Warning
}

# ---- 2. On the workstations ----
Write-DomechLog "" -Level Info
Write-DomechLog "===== Printers installed on each workstation =====" -Level Info
Write-DomechLog "(These are what people print to today - the list worth reproducing centrally.)" -Level Info
$found = @()
foreach ($pc in $Config.Workstations) {
    if (-not (Test-Connection -ComputerName $pc -Count 1 -Quiet -ErrorAction SilentlyContinue)) {
        Write-DomechLog "  $pc : offline or unreachable" -Level Warning
        continue
    }
    try {
        $printers = Invoke-Command -ComputerName $pc -ErrorAction Stop -ScriptBlock {
            Get-Printer | Where-Object { $_.Name -notmatch 'OneNote|Microsoft Print to PDF|Microsoft XPS|Fax' } |
                Select-Object Name, DriverName, PortName, Type
        }
        if ($printers) {
            foreach ($p in $printers) {
                Write-DomechLog "  $pc : $($p.Name)  [driver: $($p.DriverName)]  [port: $($p.PortName)]" -Level Success
                $found += [PSCustomObject]@{ Computer = $pc; Name = $p.Name; Driver = $p.DriverName; Port = $p.PortName }
            }
        } else {
            Write-DomechLog "  $pc : no real printers installed" -Level Info
        }
    } catch {
        Write-DomechLog "  $pc : could not query (WinRM down?) - $($_.Exception.Message)" -Level Warning
    }
}

if ($found) {
    $csv = Join-Path $Config.Paths.ScratchRoot "WorkstationPrinters.csv"
    $found | Export-Csv $csv -NoTypeInformation
    Write-DomechLog "" -Level Info
    Write-DomechLog "Saved the full list to $csv" -Level Success

    Write-DomechLog "" -Level Info
    Write-DomechLog "===== Distinct printers across the fleet =====" -Level Info
    $found | Group-Object Name | Sort-Object Count -Descending | ForEach-Object {
        Write-DomechLog "  $($_.Name)  - on $($_.Count) PC(s): $(($_.Group.Computer) -join ', ')" -Level Info
    }
}

# ---- 3. Anything on the subnet answering on a printer port ----
Write-DomechLog "" -Level Info
Write-DomechLog "===== Scanning the subnet for printer devices =====" -Level Info
$gateway = $Config.Network.Gateway
$prefix  = ($gateway -split '\.')[0..2] -join '.'
Write-DomechLog "Scanning $prefix.1-254 on ports 9100, 515, 631 - takes a couple of minutes..." -Level Info

$printerPorts = @(9100, 515, 631)
foreach ($i in 1..254) {
    $ip = "$prefix.$i"
    if (-not (Test-Connection -ComputerName $ip -Count 1 -Quiet -ErrorAction SilentlyContinue)) { continue }
    foreach ($port in $printerPorts) {
        $client = New-Object System.Net.Sockets.TcpClient
        try {
            $async = $client.BeginConnect($ip, $port, $null, $null)
            if ($async.AsyncWaitHandle.WaitOne(400) -and $client.Connected) {
                $name = try { [System.Net.Dns]::GetHostEntry($ip).HostName } catch { "(no DNS name)" }
                Write-DomechLog "  $ip : port $port open - $name" -Level Success
            }
        } catch {
        } finally {
            $client.Close()
        }
    }
}

Write-DomechLog "" -Level Info
Write-DomechLog "Done - nothing was changed." -Level Success
Write-DomechLog "Next: install the printers you want on this server and share them, then add them to config.json's Printers list and run the printer deployment." -Level Info
