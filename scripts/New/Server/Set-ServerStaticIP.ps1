<#
Domech Fabricators - assign the server's own static IP
Run LOCALLY on the server (elevated PowerShell), FIRST - before
0-Prepare-DataDrive.ps1 and 1-Install-ADForest.ps1. Everything else in
this toolkit (workstation DNS, AD promotion, drive maps) assumes the
server sits at config.json's Network.DnsServer address.

Changing IP mid-session can drop an active remote/RDP connection - if
you're connected remotely, expect to reconnect at the new address after
this runs.
#>

$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

$staticIp     = $Config.Network.DnsServer
$prefixLength = $Config.Network.SubnetPrefixLength
$gateway      = $Config.Network.Gateway

Write-DomechLog "Assigning server -> $staticIp/$prefixLength, gateway $gateway, DNS $staticIp (self) ..." -Level Info

$adapter = Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1
if (-not $adapter) {
    Write-DomechLog "No active network adapter found." -Level Error
    exit 1
}

# Remove existing IPv4 addresses/routes on this adapter (DHCP-assigned or a
# prior static IP) before assigning the new one, so we don't end up with
# two conflicting addresses on the same adapter.
Get-NetIPAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
Get-NetRoute -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.NextHop -ne "0.0.0.0" } | Remove-NetRoute -Confirm:$false -ErrorAction SilentlyContinue

New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $staticIp -PrefixLength $prefixLength -DefaultGateway $gateway | Out-Null
Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $staticIp

Write-DomechLog "Static IP set. Verify with 'ipconfig /all' - IPv4 should show $staticIp." -Level Success
Write-DomechLog "Next: 0-Prepare-DataDrive.ps1, then 1-Install-ADForest.ps1." -Level Info
