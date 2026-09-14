<#
Domech Fabricators - assign this workstation's static IP + point DNS at the server
Run LOCALLY on the workstation (elevated PowerShell), ideally BEFORE joining
the domain so it can resolve the DC reliably from the first attempt.

Changing IP mid-session can drop an active remote connection - that's why
this is a local-run script, not something pushed via Invoke-Command.

Looks up this machine's own hostname in config.json's Network.WorkstationIPs
- add every workstation there first.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$hostname = $env:COMPUTERNAME
$staticIp = $Config.Network.WorkstationIPs.$hostname

if (-not $staticIp) {
    Write-DomechLog "No IP defined for '$hostname' in config.json's Network.WorkstationIPs - add it there first, then rerun." -Level Error
    exit 1
}

$prefixLength = $Config.Network.SubnetPrefixLength
$gateway      = $Config.Network.Gateway
$dnsServer    = $Config.Network.DnsServer

Write-DomechLog "Assigning $hostname -> $staticIp/$prefixLength, gateway $gateway, DNS $dnsServer ..." -Level Info

$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if (-not $adapter) {
    Write-DomechLog "No active network adapter found." -Level Error
    exit 1
}

# Remove existing IPv4 addresses/routes on this adapter (DHCP-assigned) before
# assigning the static one, so we don't end up with two conflicting addresses.
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne "0.0.0.0" } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $staticIp -PrefixLength $prefixLength -DefaultGateway $gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $dnsServer

Write-DomechLog "Static IP set. Verify with 'ipconfig /all' - IPv4 should show $staticIp and DNS should show $dnsServer only." -Level Success
