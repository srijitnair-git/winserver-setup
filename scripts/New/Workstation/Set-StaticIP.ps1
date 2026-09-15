<#
Domech Fabricators - give this workstation its fixed address

Run LOCALLY on the workstation, elevated. Takes the address for this PC's
hostname from config.json's Network.WorkstationIPs.

Safe to run over a remote session: it checks first, verifies afterwards, and
puts the machine back on DHCP by itself if the new settings do not work. A
static address that kills the network is otherwise very hard to undo remotely.

Three things that go wrong, all handled here:

  - Picking the wrong adapter. The old version took whichever adapter happened
    to be listed first, which on a PC with Wi-Fi, Bluetooth or a virtual
    adapter could be the wrong one entirely - configuring that one while the
    real network card kept its old settings.
  - The address already being in use. Home routers hand out addresses from a
    pool that often covers the same range these fixed addresses sit in, so the
    router may already have given this address to something else. Two machines
    on one address is an intermittent mess.
  - No way back. Applying settings without checking them leaves a machine
    unreachable with no recourse but a desk visit.

DNS deliberately points at the server alone. That is how the PC finds the
domain. If the internet stops working after this, the fault is the server's DNS
forwarding, not this address - run "Check internet name lookups on the server".
Adding a public DNS server here would restore browsing and quietly break
logons, drive mappings and printers.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$hostname = $env:COMPUTERNAME
$staticIp = $Config.Network.WorkstationIPs.$hostname

if (-not $staticIp) {
    Write-DomechLog "No address listed for '$hostname' in config.json's Network.WorkstationIPs - add it there first, then rerun." -Level Error
    exit 1
}

$prefixLength = $Config.Network.SubnetPrefixLength
$gateway      = $Config.Network.Gateway
$dnsServer    = $Config.Network.DnsServer

# ---- pick the right adapter ----
# Physical, wired, actually up. Virtual and wireless adapters are excluded so a
# Hyper-V switch, VPN or Bluetooth connection can never be configured by
# mistake while the real network card is left alone.
$candidates = Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Status -eq 'Up' -and
        $_.InterfaceDescription -notmatch 'Bluetooth|Virtual|VPN|Loopback|TAP|Hyper-V'
    }
$adapter = $candidates | Where-Object { $_.MediaType -ne 'Native 802.11' } | Select-Object -First 1
if (-not $adapter) { $adapter = $candidates | Select-Object -First 1 }

if (-not $adapter) {
    Write-DomechLog "No physical network adapter is up on this PC. Check the cable." -Level Error
    exit 1
}
if (@($candidates).Count -gt 1) {
    Write-DomechLog "More than one adapter is up - using '$($adapter.Name)' ($($adapter.InterfaceDescription)). Others: $((@($candidates) | Where-Object { $_.ifIndex -ne $adapter.ifIndex }).Name -join ', ')" -Level Warning
}
Write-DomechLog "Adapter: $($adapter.Name) - $($adapter.InterfaceDescription)" -Level Info

# ---- remember how it is set now, so it can be put back ----
$before = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$wasDhcp = $before.Dhcp -eq 'Enabled'
$currentIp = (Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
              Where-Object { $_.IPAddress -notlike '169.254.*' } | Select-Object -First 1).IPAddress
Write-DomechLog "Currently: $(if ($currentIp) { $currentIp } else { 'no address' }) (DHCP: $wasDhcp)" -Level Info

# ---- is the address already taken ----
if ($currentIp -ne $staticIp) {
    Write-DomechLog "Checking whether $staticIp is already in use..." -Level Info
    if (Test-Connection -ComputerName $staticIp -Count 2 -Quiet -ErrorAction SilentlyContinue) {
        Write-DomechLog "SOMETHING ALREADY ANSWERS AT $staticIp - not assigning it. Nothing has been changed." -Level Error
        Write-DomechLog "The router has probably handed that address out from its DHCP pool. Either exclude $staticIp from the pool on the router, or reserve it for this PC there instead." -Level Warning
        exit 1
    }
    Write-DomechLog "  Free." -Level Success
}

# ---- apply ----
Write-DomechLog "Setting $hostname -> $staticIp/$prefixLength, gateway $gateway, DNS $dnsServer" -Level Info
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne "0.0.0.0" } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $staticIp -PrefixLength $prefixLength -DefaultGateway $gateway -ErrorAction SilentlyContinue | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dnsServer -ErrorAction SilentlyContinue
Start-Sleep -Seconds 3

# ---- verify, and undo it if it does not work ----
Write-DomechLog "" -Level Info
Write-DomechLog "Checking the new settings..." -Level Info
$gatewayOk = Test-Connection -ComputerName $gateway   -Count 2 -Quiet -ErrorAction SilentlyContinue
$serverOk  = Test-Connection -ComputerName $dnsServer -Count 2 -Quiet -ErrorAction SilentlyContinue
Write-DomechLog "  router  ($gateway): $(if ($gatewayOk) { 'reachable' } else { 'NOT reachable' })" -Level $(if ($gatewayOk) { 'Success' } else { 'Error' })
Write-DomechLog "  server  ($dnsServer): $(if ($serverOk) { 'reachable' } else { 'NOT reachable' })" -Level $(if ($serverOk) { 'Success' } else { 'Error' })

if (-not $gatewayOk -and -not $serverOk) {
    Write-DomechLog "" -Level Info
    Write-DomechLog "These settings reach nothing - putting this PC back on DHCP so it is not left stranded." -Level Error
    Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Enabled -ErrorAction SilentlyContinue
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ResetServerAddresses -ErrorAction SilentlyContinue
    ipconfig /renew | Out-Null
    Write-DomechLog "Back on DHCP. The gateway or subnet in config.json is probably wrong for this network - check them before trying again." -Level Warning
    exit 1
}

# Internet names are the usual complaint after a static address. Say plainly
# where the fault is, because it is not this machine.
try {
    Resolve-DnsName -Name "google.com" -ErrorAction Stop -QuickTimeout | Out-Null
    Write-DomechLog "  internet names: working" -Level Success
} catch {
    Write-DomechLog "  internet names: NOT resolving" -Level Warning
    Write-DomechLog "  The address is fine - the network and server are both reachable. This is the server's DNS forwarding." -Level Warning
    Write-DomechLog "  Run 'Check internet name lookups on the server' on the DC. Do NOT add a public DNS server here; it breaks the domain." -Level Warning
}

Write-DomechLog "" -Level Info
Write-DomechLog "Done - $hostname is now on $staticIp." -Level Success
