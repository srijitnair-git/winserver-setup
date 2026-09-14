<#
Domech Fabricators - DF.local post-promotion setup (Step 2)
Run AFTER the server reboots from step 1, logged in as DF\Administrator.
Sets DNS, OU structure, security groups, password policy, and basic DC hardening.
No D: drive yet - this only touches what's needed for a working, safe DF.local.
#>

[Net.ServicePointManager]::SecurityProtocol = 'Tls12'
Import-Module ActiveDirectory
$ScriptsRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$RepoRoot    = Split-Path $ScriptsRoot -Parent
. "$ScriptsRoot\DomechCommon.ps1"
$Config = Initialize-DomechContext -ScriptName $MyInvocation.MyCommand.Name -RepoRoot $RepoRoot

Write-Host "Verifying domain health..." -ForegroundColor Cyan
dcdiag /q

# ---- DNS ----
# No Pi-hole/TrueNAS yet, so forward to public resolvers directly for now.
# Revisit with Set-DNSConfiguration once TrueNAS/Pi-hole exists (Module 6).
Write-Host "Configuring DNS forwarders (temporary, until Pi-hole exists)..." -ForegroundColor Cyan
Set-DnsServerForwarder -IPAddress 1.1.1.1,9.9.9.9 -PassThru

# Set this DC's own DNS client to point at itself only
$adapter = Get-DnsClientServerAddress -AddressFamily IPv4 | Where-Object { $_.ServerAddresses -ne $null } | Select-Object -First 1
Set-DnsClientServerAddress -InterfaceIndex $adapter.InterfaceIndex -ServerAddresses "127.0.0.1"

# ---- OU structure ----
Write-Host "Creating OU structure..." -ForegroundColor Cyan
$domainDN = (Get-ADDomain).DistinguishedName
$OUs = @("Domech", "Domech\Users", "Domech\Computers", "Domech\Groups", "Domech\Disabled")
foreach ($ou in $OUs) {
    $parts = $ou -split '\\'
    $name = $parts[-1]
    $parentPath = if ($parts.Count -gt 1) {
        "OU=" + (($parts[0..($parts.Count-2)] | Select-Object -Last 1)) + "," + $domainDN
    } else { $domainDN }
    $path = if ($parts.Count -eq 1) { $domainDN } else { "OU=$($parts[$parts.Count-2]),$domainDN" }
    if (-not (Get-ADOrganizationalUnit -Filter "Name -eq '$name'" -SearchBase $domainDN -ErrorAction SilentlyContinue)) {
        New-ADOrganizationalUnit -Name $name -Path $path -ProtectedFromAccidentalDeletion $true
        Write-Host "  Created OU: $ou"
    }
}

# ---- Security groups ----
Write-Host "Creating security groups..." -ForegroundColor Cyan
$groupsOU = "OU=Groups,OU=Domech,$domainDN"
$Groups = @("GG-AllStaff", "GG-Accounts", "GG-Tally", "GG-Admins", "GG-PrintUsers")
foreach ($g in $Groups) {
    if (-not (Get-ADGroup -Filter "Name -eq '$g'" -ErrorAction SilentlyContinue)) {
        New-ADGroup -Name $g -GroupScope Global -GroupCategory Security -Path $groupsOU
        Write-Host "  Created group: $g"
    }
}

# ---- Password policy ----
Write-Host "Setting default domain password policy..." -ForegroundColor Cyan
Set-ADDefaultDomainPasswordPolicy -Identity $domainDN `
    -MinPasswordLength 12 `
    -PasswordHistoryCount 12 `
    -MaxPasswordAge (New-TimeSpan -Days 90) `
    -LockoutThreshold 5 `
    -LockoutDuration (New-TimeSpan -Minutes 30) `
    -ComplexityEnabled $true

# ---- Basic DC hardening ----
Write-Host "Applying basic DC hardening..." -ForegroundColor Cyan
# Disable SMBv1
Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force
# Require SMB signing
Set-SmbServerConfiguration -RequireSecuritySignature $true -Force
# Restrict RDP to Administrators (default), ensure NLA on
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 1

Write-Host "`nDone. Next: create real user accounts, file shares, and test-join one workstation." -ForegroundColor Green
Write-Host "Run 'dcdiag' and 'Get-ADDomain' to confirm health before proceeding." -ForegroundColor Green
