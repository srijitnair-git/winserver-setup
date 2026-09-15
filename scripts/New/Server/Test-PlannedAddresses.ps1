<#
Domech Fabricators - are the planned fixed addresses actually free

Run on the DC. Read-only: it reports, it changes nothing.

Pings every address config.json intends to assign and reports which are
already taken. An address handed out by the router's DHCP pool cannot also be
set as a fixed address on a PC - the two machines fight over it and the symptom
is an intermittent loss of network that looks nothing like an address clash.

If anything shows as taken, the fix is on the router, not on the PCs: move the
DHCP pool so it no longer covers the fixed addresses.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$planned = [ordered]@{}
$expectedMac = @{}    # name -> MAC, where config knows it
$planned["SERVER (this machine)"] = $Config.Network.DnsServer
foreach ($p in $Config.Printers | Where-Object { $_.IPAddress }) {
    $planned[$p.Name] = $p.IPAddress
    if ($p.MacAddress) { $expectedMac[$p.Name] = $p.MacAddress }
}
foreach ($name in $Config.Network.WorkstationIPs.PSObject.Properties.Name) {
    $planned[$name] = $Config.Network.WorkstationIPs.$name
}

Write-DomechLog "Checking $($planned.Count) planned addresses..." -Level Info
Write-DomechLog "" -Level Info

$taken = @()
$thisMachine = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                 Select-Object -ExpandProperty IPAddress)

foreach ($name in $planned.Keys) {
    $ip = $planned[$name]
    if (-not $ip) { continue }

    $answers = Test-Connection -ComputerName $ip -Count 2 -Quiet -ErrorAction SilentlyContinue
    $isMine  = $thisMachine -contains $ip

    # Whoever answers, try to name them. A MAC is often the only way to tell
    # which device has squatted on an address.
    $mac = (Get-NetNeighbor -IPAddress $ip -ErrorAction SilentlyContinue |
            Select-Object -First 1 -ExpandProperty LinkLayerAddress)
    $dns = try { [System.Net.Dns]::GetHostEntry($ip).HostName } catch { $null }

    # A MAC match is proof it is the intended device, whatever it calls itself.
    # Network printers in particular answer to a name derived from their MAC
    # rather than their model, so matching on name alone reports the right
    # device sitting on its own address as a conflict.
    $macMatches = $expectedMac.ContainsKey($name) -and $mac -and
                  ($mac -replace '[:-]','') -eq ($expectedMac[$name] -replace '[:-]','')

    if ($isMine) {
        Write-DomechLog "  $($name.PadRight(24)) $ip  - this server, correct" -Level Success
    } elseif (-not $answers) {
        Write-DomechLog "  $($name.PadRight(24)) $ip  - free" -Level Success
    } elseif ($macMatches) {
        Write-DomechLog "  $($name.PadRight(24)) $ip  - already set correctly (MAC matches$(if ($dns) { ", $dns" }))" -Level Success
    } elseif ($dns -and $dns -like "$name*") {
        Write-DomechLog "  $($name.PadRight(24)) $ip  - already set correctly ($dns)" -Level Success
    } else {
        $who = @($dns, $mac) | Where-Object { $_ }
        Write-DomechLog "  $($name.PadRight(24)) $ip  - TAKEN by $(if ($who) { $who -join ' / ' } else { 'an unknown device' })" -Level Error
        $taken += "$name ($ip)"
    }
}

Write-DomechLog "" -Level Info
if (-not $taken) {
    Write-DomechLog "Every planned address is free or already correct - safe to assign." -Level Success
} else {
    Write-DomechLog "$($taken.Count) address(es) are in use by something else:" -Level Error
    $taken | ForEach-Object { Write-DomechLog "   $_" -Level Error }
    Write-DomechLog "" -Level Info
    Write-DomechLog "Fix this on the router, not on the PCs:" -Level Warning
    Write-DomechLog "  1. Move the DHCP pool so it starts ABOVE every fixed address (192.168.0.150 - 192.168.0.199 suits this network)." -Level Warning
    Write-DomechLog "  2. The devices holding those addresses keep them until their lease expires. Reboot them, or wait it out." -Level Warning
    Write-DomechLog "  3. Then set the workstation addresses." -Level Warning
    Write-DomechLog "Assigning a fixed address that something else already holds causes an intermittent loss of network that is very hard to recognise for what it is." -Level Warning
}
